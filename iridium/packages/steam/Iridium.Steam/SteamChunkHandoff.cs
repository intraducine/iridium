using System.Security.Cryptography;
using SteamKit2;
using SteamKit2.CDN;

namespace Iridium.Steam;

// URLs can contain short-lived CDN authorization. This is a one-time, private
// host handoff, never a Snapshot, queue document, receipt, or diagnostic.
public sealed record ChunkRequest(string Id, string Url, int ExpectedBytes);
public sealed record ChunkBatch(string OperationId, string BatchId, int Connections, ChunkRequest[] Requests);
public sealed record ChunkBatchResult(string OperationId, string BatchId, string Code);

public sealed class SteamChunkHandoff
{
    readonly object sync = new();
    ChunkBatch? pending;
    TaskCompletionSource<string>? completion;
    bool taken;
    bool runtimeAllowed = true;
    TaskCompletionSource<bool> runtime = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public void SetRuntimeAllowed(bool allowed)
    {
        lock (sync)
        {
            if (runtimeAllowed == allowed) return;
            runtimeAllowed = allowed;
            if (allowed) runtime.TrySetResult(true);
            else runtime = new(TaskCreationOptions.RunContinuationsAsynchronously);
        }
    }

    public Task WaitForRuntime(CancellationToken ct)
    {
        lock (sync) return runtimeAllowed ? Task.CompletedTask : runtime.Task.WaitAsync(ct);
    }

    public ChunkBatch? Take()
    {
        lock (sync)
        {
            if (pending == null || taken) return null;
            taken = true;
            return pending;
        }
    }

    public bool Complete(ChunkBatchResult result)
    {
        lock (sync)
        {
            if (pending == null || !taken || pending.OperationId != result.OperationId || pending.BatchId != result.BatchId
                || result.Code is not ("ok" or "forbidden" or "network" or "invalid" or "io" or "disk-full" or "cancelled")) return false;
            return completion!.TrySetResult(result.Code);
        }
    }

    public async Task<string> Exchange(ChunkBatch batch, CancellationToken ct)
    {
        TaskCompletionSource<string> signal;
        lock (sync)
        {
            if (pending != null) throw new SteamFailure("A chunk batch is already pending.");
            pending = batch;
            taken = false;
            completion = signal = new(TaskCreationOptions.RunContinuationsAsynchronously);
        }
        try { return await signal.Task.WaitAsync(ct); }
        finally
        {
            lock (sync) { pending = null; completion = null; taken = false; }
        }
    }
}

public sealed class ChunkTransferFailure(string code) : Exception("The background transfer stopped. Resume to retry; verified files are kept.")
{
    public string Code { get; } = code is "io" or "disk-full" ? code : "request-failed";
}

// Single-consumer processing keeps the raw spool bounded. HTTP concurrency is
// owned by URLSession; the existing verified assembler still checks every byte.
public sealed class SteamBackgroundChunks(string root, string operationId, int connections,
    IReadOnlyList<SteamBackgroundChunks.Chunk> chunks,
    Func<SteamBackgroundChunks.Chunk[], int, CancellationToken, Task<ChunkRequest[]>> plan,
    SteamChunkHandoff handoff)
{
    public const int MaximumTasks = 128;
    public const long MaximumBatchBytes = 128L * 1024 * 1024;
    public sealed record Chunk(uint DepotId, uint AuthorizationAppId, DepotManifest.ChunkData Data, byte[] Key)
    {
        public string Id => Identity(DepotId, Data);
    }
    int cursor;
    HashSet<string> window = [];
    readonly Dictionary<string, Chunk> metadataById = chunks.DistinctBy(c => c.Id).ToDictionary(c => c.Id, StringComparer.Ordinal);

    public static string Identity(uint depotId, DepotManifest.ChunkData chunk)
    {
        if (depotId == 0 || chunk.ChunkID?.Length != 20) throw new SteamFailure("Invalid background chunk identity.");
        return depotId.ToString(System.Globalization.CultureInfo.InvariantCulture) + "-" + Convert.ToHexString(chunk.ChunkID).ToLowerInvariant();
    }

    public static string RawPath(string root, string operationId, string id)
    {
        if (!Guid.TryParseExact(operationId, "D", out var operation)) throw new SteamFailure("Invalid download operation identity.");
        var parts = id.Split('-');
        if (parts.Length != 2 || !uint.TryParse(parts[0], out var depot) || depot == 0
            || parts[0] != depot.ToString(System.Globalization.CultureInfo.InvariantCulture)
            || parts[1].Length != 40 || parts[1].Any(c => !"0123456789abcdef".Contains(c)))
            throw new SteamFailure("Invalid download chunk identity.");
        return VerifiedFiles.SafePath(root, ".background-chunks/" + operation.ToString("D") + "/" + id + ".raw");
    }

    public static Chunk[] Window(IEnumerable<Chunk> candidates)
    {
        var result = new List<Chunk>();
        long bytes = 0;
        foreach (var chunk in candidates)
        {
            if (chunk.Data.CompressedLength is 0 or > VerifiedFiles.MaximumChunkBytes)
                throw new SteamFailure("This manifest lacks a bounded encrypted chunk length. Background transfer cannot safely plan it.");
            if (result.Count >= MaximumTasks || bytes + chunk.Data.CompressedLength > MaximumBatchBytes) break;
            result.Add(chunk);
            bytes += chunk.Data.CompressedLength;
        }
        return result.ToArray();
    }

    public async Task<int> Fetch(uint depotId, DepotManifest.ChunkData data, byte[] destination, CancellationToken ct)
    {
        await handoff.WaitForRuntime(ct);
        var id = Identity(depotId, data);
        if (cursor >= chunks.Count || chunks[cursor].Id != id)
            throw new SteamFailure("Saved file state changed after planning. Resume to verify and replan this download.");
        if (!window.Contains(id))
        {
            // Unconsumed prefetched duplicates/reused chunks never accumulate
            // across windows. Only this operation's generated raw files are removed.
            foreach (var previous in window) File.Delete(RawPath(root, operationId, previous));
            var batchChunks = Window(chunks.Skip(cursor));
            if (batchChunks.Length == 0 || !batchChunks.Any(c => c.Id == id))
                throw new SteamFailure("Saved file state changed after planning. Resume to verify and replan this download.");
            window = batchChunks.Select(c => c.Id).ToHashSet(StringComparer.Ordinal);
            for (var attempt = 0; ; attempt++)
            {
                await handoff.WaitForRuntime(ct);
                ct.ThrowIfCancellationRequested();
                if (attempt > 0) await Task.Delay(TimeSpan.FromMilliseconds(Math.Min(4000, 300 << (attempt - 1))), ct);
                var requests = await plan(batchChunks.DistinctBy(c => c.Id).ToArray(), attempt, ct);
                var code = await handoff.Exchange(new(operationId, Guid.NewGuid().ToString("D"), connections, requests), ct);
                if (code == "ok") break;
                if (code == "cancelled") throw new OperationCanceledException(ct);
                if (code is "io" or "disk-full" or "invalid" || attempt == 5) throw new ChunkTransferFailure(code);
            }
        }
        if (!metadataById.TryGetValue(id, out var metadata)) throw new SteamFailure("Unknown planned chunk.");
        await handoff.WaitForRuntime(ct);
        var path = RawPath(root, operationId, id);
        ct.ThrowIfCancellationRequested();
        if (new FileInfo(path).Length != data.CompressedLength) throw new SteamFailure("A raw chunk has an invalid length. Resume to retry.");
        var raw = await File.ReadAllBytesAsync(path, ct);
        try
        {
            var length = DepotChunk.Process(data, raw, destination, metadata.Key);
            if (length != data.UncompressedLength || !CryptographicOperations.FixedTimeEquals(SHA1.HashData(destination.AsSpan(0, length)), data.ChunkID))
                throw new SteamFailure("A background chunk failed verification. Resume to retry.");
            ct.ThrowIfCancellationRequested();
            cursor++; // Every verified occurrence is consumed, including cached repeats across files.
            // Do not delete yet: the same chunk may be referenced by another file.
            return length;
        }
        catch
        {
            File.Delete(RawPath(root, operationId, id));
            throw;
        }
        finally { CryptographicOperations.ZeroMemory(raw); }
    }
}
