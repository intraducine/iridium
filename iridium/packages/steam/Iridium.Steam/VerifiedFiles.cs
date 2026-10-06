using System.Buffers;
using System.Security.Cryptography;
using SteamKit2;

namespace Iridium.Steam;

public static class VerifiedFiles
{
    public const int MaximumChunkBytes = 16 * 1024 * 1024;

    // Apply Windows and iOS rules, regardless of the platform running the test.
    public static string SafePath(string root, string name)
    {
        var parts = name.Replace('\\', '/').Split('/');
        if (parts.Length == 0 || parts.Any(p => string.IsNullOrWhiteSpace(p) || p is "." or ".."
            || p.EndsWith('.') || p.EndsWith(' ') || p.IndexOfAny([':', '\0', '<', '>', '"', '|', '?', '*']) >= 0
            || p.Any(char.IsControl)))
            throw new SteamFailure("The game contains an unsafe file path.");
        var current = Path.GetFullPath(root);
        RejectLink(current);
        foreach (var part in parts)
        {
            current = Path.Combine(current, part);
            RejectLink(current);
        }
        return current;
    }

    public static void RejectLink(string path)
    {
        var info = new FileInfo(path);
        if (info.LinkTarget != null || (info.Exists && (info.Attributes & FileAttributes.ReparsePoint) != 0))
            throw new SteamFailure("A symbolic link was found in the download folder.");
    }

    public static void Validate(DepotManifest.FileData file)
    {
        if (file.Flags.HasFlag(EDepotFileFlag.Symlink) || !string.IsNullOrEmpty(file.LinkTarget))
            throw new SteamFailure("This game contains links that cannot be safely installed.");
        if (file.Flags.HasFlag(EDepotFileFlag.Directory))
        {
            if (file.TotalSize != 0 || file.Chunks.Count != 0)
                throw new SteamFailure("Steam returned an invalid directory manifest.");
            return;
        }
        if (file.FileHash.Length != 20 || file.TotalSize > long.MaxValue)
            throw new SteamFailure("Steam returned an invalid file manifest.");
        ulong end = 0;
        foreach (var chunk in file.Chunks.OrderBy(c => c.Offset))
        {
            if (chunk.Offset != end || chunk.ChunkID?.Length != 20 || chunk.UncompressedLength == 0
                || chunk.UncompressedLength > MaximumChunkBytes || chunk.CompressedLength > MaximumChunkBytes)
                throw new SteamFailure("Steam returned an invalid chunk layout.");
            end = checked(end + chunk.UncompressedLength);
        }
        if (end != file.TotalSize) throw new SteamFailure("Steam returned an incomplete file manifest.");
    }

    public static async Task<bool> Matches(string path, DepotManifest.FileData file, CancellationToken ct)
    {
        RejectLink(path);
        if (!File.Exists(path) || new FileInfo(path).Length != (long)file.TotalSize) return false;
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 131072, true);
        return CryptographicOperations.FixedTimeEquals(await SHA1.HashDataAsync(stream, ct), file.FileHash);
    }

    public static string PartialPath(string staging, DepotManifest.FileData file) =>
        SafePath(staging, Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(file.FileName))) + ".part");

    // Count only verified partial bytes as available storage. File length is not
    // allocated space: sparse/preallocated partials must not bypass this check.
    public static async Task<long> RequiredStorage(string root, string staging, DepotManifest.FileData file, CancellationToken ct)
    {
        Validate(file);
        if (file.Flags.HasFlag(EDepotFileFlag.Directory) || await Matches(SafePath(root, file.FileName), file, ct)) return 0;
        var partial = PartialPath(staging, file);
        await using var existing = OpenRead(partial);
        long reusable = 0;
        if (existing != null)
        {
            foreach (var chunk in file.Chunks)
            {
                var buffer = ArrayPool<byte>.Shared.Rent((int)chunk.UncompressedLength);
                try { if (await HasChunk(existing, chunk, buffer, ct)) reusable = checked(reusable + chunk.UncompressedLength); }
                finally { ArrayPool<byte>.Shared.Return(buffer); }
            }
        }
        return checked((long)file.TotalSize - reusable);
    }

    static FileStream? OpenRead(string path)
    {
        RejectLink(path);
        try { return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.Asynchronous | FileOptions.RandomAccess); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    static async Task<bool> HasChunk(FileStream source, DepotManifest.ChunkData chunk, byte[] buffer, CancellationToken ct)
    {
        var length = checked((int)chunk.UncompressedLength);
        var read = 0;
        while (read < length)
        {
            var count = await RandomAccess.ReadAsync(source.SafeFileHandle,
                buffer.AsMemory(read, length - read), checked((long)chunk.Offset + read), ct);
            if (count == 0) return false;
            read += count;
        }
        return CryptographicOperations.FixedTimeEquals(SHA1.HashData(buffer.AsSpan(0, length)), chunk.ChunkID);
    }

    public static async Task<DepotManifest.ChunkData[]> MissingChunks(string root, string staging,
        DepotManifest.FileData file, string? reuseFile, CancellationToken ct)
    {
        Validate(file);
        if (file.Flags.HasFlag(EDepotFileFlag.Directory) || await Matches(SafePath(root, file.FileName), file, ct)) return [];
        await using var partial = OpenRead(PartialPath(staging, file));
        await using var source = OpenRead(reuseFile ?? SafePath(root, file.FileName));
        var missing = new List<DepotManifest.ChunkData>();
        foreach (var chunk in file.Chunks)
        {
            ct.ThrowIfCancellationRequested();
            var buffer = ArrayPool<byte>.Shared.Rent(checked((int)chunk.UncompressedLength));
            try
            {
                if ((partial == null || !await HasChunk(partial, chunk, buffer, ct))
                    && (source == null || !await HasChunk(source, chunk, buffer, ct))) missing.Add(chunk);
            }
            finally { ArrayPool<byte>.Shared.Return(buffer); }
        }
        return missing.ToArray();
    }

    public static async Task Download(string root, string staging, DepotManifest.FileData file,
        Func<DepotManifest.ChunkData, byte[], CancellationToken, Task<int>> fetch,
        Action<long> progress, CancellationToken ct, string? reuseFile = null,
        int maxDownloads = 4, Action<long>? networkProgress = null,
        Func<CancellationToken, Task>? waitForRuntime = null)
    {
        if (waitForRuntime != null) await waitForRuntime(ct);
        Validate(file);
        if (maxDownloads is < 1 or > 8) throw new SteamFailure("Choose between one and eight download connections.");
        var final = SafePath(root, file.FileName);
        if (file.Flags.HasFlag(EDepotFileFlag.Directory)) { Directory.CreateDirectory(final); return; }
        if (await Matches(final, file, ct)) { progress((long)file.TotalSize); return; }
        var partial = PartialPath(staging, file);
        Directory.CreateDirectory(staging);
        // Never modify a previous version or use hard links. A game may keep
        // writable configuration or saves beside its executable.
        await using (var source = OpenRead(reuseFile ?? final))
        await using (var stream = new FileStream(partial, FileMode.OpenOrCreate, FileAccess.ReadWrite,
            FileShare.None, 1, FileOptions.Asynchronous | FileOptions.RandomAccess))
        {
            stream.SetLength((long)file.TotalSize);
            await Parallel.ForEachAsync(file.Chunks, new ParallelOptions
            {
                MaxDegreeOfParallelism = maxDownloads, CancellationToken = ct
            }, async (chunk, token) =>
            {
                if (waitForRuntime != null) await waitForRuntime(token);
                var length = checked((int)chunk.UncompressedLength);
                var buffer = ArrayPool<byte>.Shared.Rent(length);
                try
                {
                    if (!await HasChunk(stream, chunk, buffer, token))
                    {
                        if (source == null || !await HasChunk(source, chunk, buffer, token))
                        {
                            var downloaded = await fetch(chunk, buffer, token);
                            token.ThrowIfCancellationRequested();
                            networkProgress?.Invoke(chunk.CompressedLength == 0 ? length : chunk.CompressedLength);
                            if (downloaded != length || !CryptographicOperations.FixedTimeEquals(SHA1.HashData(buffer.AsSpan(0, length)), chunk.ChunkID))
                                throw new SteamFailure("A downloaded chunk failed verification. Resume to retry it.");
                        }
                        token.ThrowIfCancellationRequested();
                        if (waitForRuntime != null) await waitForRuntime(token);
                        await RandomAccess.WriteAsync(stream.SafeFileHandle, buffer.AsMemory(0, length), (long)chunk.Offset, token);
                    }
                    progress(length);
                }
                finally { ArrayPool<byte>.Shared.Return(buffer); }
            });
            stream.Flush(flushToDisk: true);
        }
        ct.ThrowIfCancellationRequested();
        if (waitForRuntime != null) await waitForRuntime(ct);
        if (!await Matches(partial, file, ct))
            throw new SteamFailure("A downloaded file failed verification. Resume to retry it.");
        ct.ThrowIfCancellationRequested();
        Directory.CreateDirectory(Path.GetDirectoryName(final)!);
        _ = SafePath(root, file.FileName);
        _ = PartialPath(staging, file);
        File.Move(partial, final, overwrite: true);
    }
}
