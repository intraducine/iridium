using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Iridium.Steam;
using SteamKit2;
using SteamKit2.CDN;

internal static class BackgroundChunkTests
{
    public static async Task<int> Run()
    {
        var checks = 0;
        void Check(bool value, string label) { if (!value) throw new Exception(label); checks++; }
        void Reject(Action operation)
        {
            try { operation(); } catch (SteamFailure) { checks++; return; }
            throw new Exception("Accepted invalid background chunk");
        }
        var key = Enumerable.Range(0, 32).Select(n => (byte)n).ToArray();
        var bytes = "deterministic encrypted Steam chunk fixture"u8.ToArray();
        var raw = Encrypt(bytes, key);
        var data = new DepotManifest.ChunkData(SHA1.HashData(bytes), DepotChunk.AdlerHash(bytes), 0, (uint)raw.Length, (uint)bytes.Length);
        var chunk = new SteamBackgroundChunks.Chunk(10, 42, data, key);
        var copies = Enumerable.Range(0, 129).Select(_ => chunk).ToArray();
        Check(SteamBackgroundChunks.Window(copies).Length == 128, "Batch task count is bounded across file boundaries");
        var largeData = new DepotManifest.ChunkData(data.ChunkID!, data.Checksum, 0, 16 * 1024 * 1024, 16 * 1024 * 1024);
        Check(SteamBackgroundChunks.Window(Enumerable.Range(0, 9).Select(_ => chunk with { Data = largeData })).Length == 8,
            "Exact 128 MiB planned raw window");
        var unknownLength = new DepotManifest.ChunkData(data.ChunkID!, data.Checksum, 0, 0, (uint)bytes.Length);
        Reject(() => SteamBackgroundChunks.Window([chunk with { Data = unknownLength }]));
        Reject(() => SteamBackgroundChunks.RawPath("/fixture", "../outside", chunk.Id));

        var handoff = new SteamChunkHandoff();
        handoff.SetRuntimeAllowed(false);
        var permit = handoff.WaitForRuntime(default);
        Check(!permit.IsCompleted, "Suspended runtime cannot verify or plan");
        handoff.SetRuntimeAllowed(true);
        await permit;
        checks++;
        var operation = Guid.NewGuid().ToString("D");
        var batch = new ChunkBatch(operation, Guid.NewGuid().ToString("D"), 4,
            [new(chunk.Id, "https://fixture.invalid/depot/10/chunk/" + Convert.ToHexString(data.ChunkID!).ToLowerInvariant() + "?auth=synthetic-secret", raw.Length)]);
        var batchJson = JsonSerializer.Serialize(batch, SteamJson.Default.ChunkBatch);
        var decodedBatch = JsonSerializer.Deserialize(batchJson, SteamJson.Default.ChunkBatch);
        Check(decodedBatch?.OperationId == operation && decodedBatch.Requests.Length == 1
            && decodedBatch.Requests[0] == batch.Requests[0] && batchJson.Contains("\"expectedBytes\""),
            "Private batch source-generated JSON matches host contract under NativeAOT");
        var acknowledgement = new ChunkBatchResult(operation, batch.BatchId, "ok");
        Check(JsonSerializer.Deserialize(JsonSerializer.Serialize(acknowledgement, SteamJson.Default.ChunkBatchResult),
            SteamJson.Default.ChunkBatchResult) == acknowledgement, "Batch acknowledgement source-generated JSON round trip");
        using (var cancelled = new CancellationTokenSource())
        {
            var exchange = handoff.Exchange(batch, cancelled.Token);
            Check(handoff.Take() == batch && handoff.Take() == null, "Private plan can be taken once");
            Check(!handoff.Complete(new(Guid.NewGuid().ToString(), batch.BatchId, "ok")), "Another account operation cannot acknowledge this plan");
            cancelled.Cancel();
            try { await exchange; throw new Exception("Ignored batch cancellation"); }
            catch (OperationCanceledException) { checks++; }
            Check(!handoff.Complete(new(operation, batch.BatchId, "ok")), "Late completion after cancelled exchange is rejected");
        }
        var nextBatch = batch with { BatchId = Guid.NewGuid().ToString("D") };
        var nextExchange = handoff.Exchange(nextBatch, default);
        Check(handoff.Take() == nextBatch, "New correlated operation handoff");
        Check(!handoff.Complete(new(operation, batch.BatchId, "ok")), "Stale batch cannot complete newer exchange");
        Check(handoff.Complete(new(operation, nextBatch.BatchId, "ok")) && await nextExchange == "ok", "Matching batch completion wakes verifier");

        var root = Path.Combine(Path.GetTempPath(), "iridium-background-chunks-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var source = new SteamBackgroundChunks(root, operation, 4, [chunk, chunk],
                (items, attempt, token) => Task.FromResult(batch.Requests), handoff);
            var destination = new byte[bytes.Length];
            var fetch = source.Fetch(10, data, destination, default);
            ChunkBatch? pending = null;
            for (var n = 0; n < 100 && pending == null; n++) { pending = handoff.Take(); if (pending == null) await Task.Delay(10); }
            Check(pending != null, "Native verifier waits for OS-owned raw transfer");
            var path = SteamBackgroundChunks.RawPath(root, operation, chunk.Id);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            await File.WriteAllBytesAsync(path, raw);
            Check(handoff.Complete(new(operation, pending!.BatchId, "ok")), "Raw completion matches live operation");
            Check(await fetch == bytes.Length && destination.SequenceEqual(bytes), "Public SteamKit decrypt/decompress/Adler and SHA1 verify encrypted fixture");
            await File.WriteAllBytesAsync(path, new byte[raw.Length]);
            try { await source.Fetch(10, data, destination, default); throw new Exception("Accepted corrupt ciphertext"); }
            catch (Exception e) when (e is CryptographicException or SteamFailure or InvalidDataException) { checks++; }
            Check(!File.Exists(path), "Corrupt raw cache is removed for a fresh authenticated retry");
            var file = new DepotManifest.FileData { FileName = "fixture.exe", FileHash = SHA1.HashData(bytes), TotalSize = (ulong)bytes.Length };
            file.Chunks.Add(data);
            var content = Path.Combine(root, "content");
            var partial = Path.Combine(root, "partial");
            Directory.CreateDirectory(partial);
            await File.WriteAllBytesAsync(VerifiedFiles.PartialPath(partial, file), bytes);
            Check((await VerifiedFiles.MissingChunks(content, partial, file, null, default)).Length == 0,
                "Already verified partial chunks do not enter HTTP plans");
            await File.WriteAllBytesAsync(VerifiedFiles.PartialPath(partial, file), new byte[bytes.Length]);
            Check((await VerifiedFiles.MissingChunks(content, partial, file, null, default)).Length == 1,
                "Sparse or corrupt partial data is replanned");
            SteamStorageDiagnostic? capacity = null;
            await SteamStorage.Check(content, partial, [file], _ => new(long.MaxValue, SteamCapacitySource.ImportantUsage), false,
                value => capacity = value, default, SteamBackgroundChunks.MaximumBatchBytes);
            Check(capacity!.RequiredBytes == SteamStorage.SafetyMarginBytes + bytes.Length + SteamBackgroundChunks.MaximumBatchBytes,
                "Raw batch storage is reserved in addition to verified assembly and safety margin");

            // 258 occurrences of A span files/windows, followed by distinct B.
            // Exercise actual verified assembly, rather than a cursor-only helper.
            var otherBytes = "a distinct encrypted Steam chunk fixture"u8.ToArray();
            var otherRaw = Encrypt(otherBytes, key);
            var otherData = new DepotManifest.ChunkData(SHA1.HashData(otherBytes), DepotChunk.AdlerHash(otherBytes), 0,
                (uint)otherRaw.Length, (uint)otherBytes.Length);
            DepotManifest.FileData FixtureFile(string name, byte[] payload, DepotManifest.ChunkData descriptor, int count)
            {
                var expected = Enumerable.Range(0, count).SelectMany(_ => payload).ToArray();
                var fixture = new DepotManifest.FileData { FileName = name, FileHash = SHA1.HashData(expected), TotalSize = (ulong)expected.Length };
                for (var n = 0; n < count; n++) fixture.Chunks.Add(new(descriptor.ChunkID!, descriptor.Checksum,
                    (ulong)(n * payload.Length), descriptor.CompressedLength, descriptor.UncompressedLength));
                return fixture;
            }
            var repeatedFiles = new[] { FixtureFile("first.exe", bytes, data, 129), FixtureFile("second.exe", bytes, data, 129),
                FixtureFile("last.exe", otherBytes, otherData, 1) };
            var repeatedChunks = repeatedFiles.SelectMany(f => f.Chunks.Select(c => new SteamBackgroundChunks.Chunk(10, 42, c, key))).ToArray();
            var repeatedOperation = Guid.NewGuid().ToString("D");
            var repeatedHandoff = new SteamChunkHandoff();
            var repeatedSource = new SteamBackgroundChunks(root, repeatedOperation, 4, repeatedChunks,
                (items, attempt, token) => Task.FromResult(items.Select(c => new ChunkRequest(c.Id,
                    "https://fixture.invalid/depot/10/chunk/" + Convert.ToHexString(c.Data.ChunkID!).ToLowerInvariant(),
                    checked((int)c.Data.CompressedLength))).ToArray()), repeatedHandoff);
            var rawPayloads = new Dictionary<string, byte[]> { [chunk.Id] = raw, [SteamBackgroundChunks.Identity(10, otherData)] = otherRaw };
            var repeatedContent = Path.Combine(root, "repeated-content");
            var repeatedPartial = Path.Combine(root, "repeated-partial");
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var assembly = Task.Run(async () =>
            {
                foreach (var fixture in repeatedFiles)
                    await VerifiedFiles.Download(repeatedContent, repeatedPartial, fixture,
                        (descriptor, buffer, token) => repeatedSource.Fetch(10, descriptor, buffer, token),
                        _ => { }, deadline.Token, maxDownloads: 1);
            });
            var transferred = new List<string>();
            var batches = 0;
            while (!assembly.IsCompleted)
            {
                deadline.Token.ThrowIfCancellationRequested();
                var planned = repeatedHandoff.Take();
                if (planned == null) { await Task.Delay(1, deadline.Token); continue; }
                Check(planned.Requests.Length <= SteamBackgroundChunks.MaximumTasks
                    && planned.Requests.Sum(r => (long)r.ExpectedBytes) <= SteamBackgroundChunks.MaximumBatchBytes,
                    "Repeated-chunk batches preserve task and expected-byte bounds");
                foreach (var request in planned.Requests)
                {
                    var rawPath = SteamBackgroundChunks.RawPath(root, repeatedOperation, request.Id);
                    Directory.CreateDirectory(Path.GetDirectoryName(rawPath)!);
                    await File.WriteAllBytesAsync(rawPath, rawPayloads[request.Id], deadline.Token);
                    transferred.Add(request.Id);
                }
                Check(repeatedHandoff.Complete(new(repeatedOperation, planned.BatchId, "ok")), "Repeated-chunk raw acknowledgement");
                batches++;
            }
            await assembly;
            Check(repeatedChunks.Length == 259 && batches == 2 && transferred.SequenceEqual(new[] { chunk.Id, SteamBackgroundChunks.Identity(10, otherData) }),
                "258 repeated occurrences across files consume in order and then plan B without extra transfers");
            foreach (var fixture in repeatedFiles)
                Check(await VerifiedFiles.Matches(VerifiedFiles.SafePath(repeatedContent, fixture.FileName), fixture, default),
                    "Every repeated chunk and assembled file is verified");
            var snapshot = JsonSerializer.Serialize(new Snapshot { OperationId = operation }, SteamJson.Default.Snapshot);
            Check(!snapshot.Contains("synthetic-secret") && !snapshot.Contains("fixture.invalid"), "Private transfer authorization never enters snapshots");
            Check(SteamErrors.Code(new ChunkTransferFailure("disk-full")) == "disk-full"
                && !SteamErrors.Describe(new ChunkTransferFailure("io"), "downloading").Contains(root), "Fixed transfer failures preserve storage diagnostics without path leaks");
        }
        finally { Directory.Delete(root, recursive: true); }
        return checks;
    }

    static byte[] Encrypt(byte[] bytes, byte[] key)
    {
        byte[] zipped;
        using (var stream = new MemoryStream())
        {
            using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
            {
                var entry = zip.CreateEntry("fixture");
                entry.LastWriteTime = new DateTimeOffset(2000, 1, 1, 0, 0, 0, TimeSpan.Zero);
                using var payload = entry.Open();
                payload.Write(bytes);
            }
            zipped = stream.ToArray();
        }
        using var aes = Aes.Create();
        aes.Key = key;
        var iv = Enumerable.Range(32, 16).Select(n => (byte)n).ToArray();
        return aes.EncryptEcb(iv, PaddingMode.None).Concat(aes.EncryptCbc(zipped, iv, PaddingMode.PKCS7)).ToArray();
    }
}
