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

    public static async Task Download(string root, string staging, DepotManifest.FileData file,
        Func<DepotManifest.ChunkData, byte[], CancellationToken, Task<int>> fetch,
        Action<long> progress, CancellationToken ct)
    {
        Validate(file);
        var final = SafePath(root, file.FileName);
        if (file.Flags.HasFlag(EDepotFileFlag.Directory)) { Directory.CreateDirectory(final); return; }
        if (await Matches(final, file, ct)) { progress((long)file.TotalSize); return; }
        var partial = SafePath(staging, Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(file.FileName))) + ".part");
        Directory.CreateDirectory(staging);
        await using (var stream = new FileStream(partial, FileMode.OpenOrCreate, FileAccess.ReadWrite,
            FileShare.None, 1, FileOptions.Asynchronous | FileOptions.RandomAccess))
        {
            stream.SetLength((long)file.TotalSize);
            await Parallel.ForEachAsync(file.Chunks, new ParallelOptions
            {
                MaxDegreeOfParallelism = 4, CancellationToken = ct
            }, async (chunk, token) =>
            {
                var length = checked((int)chunk.UncompressedLength);
                var buffer = ArrayPool<byte>.Shared.Rent(length);
                try
                {
                    var read = 0;
                    while (read < length)
                    {
                        var count = await RandomAccess.ReadAsync(stream.SafeFileHandle,
                            buffer.AsMemory(read, length - read), checked((long)chunk.Offset + read), token);
                        if (count == 0) break;
                        read += count;
                    }
                    if (read != length || !SHA1.HashData(buffer.AsSpan(0, length)).AsSpan().SequenceEqual(chunk.ChunkID))
                    {
                        var downloaded = await fetch(chunk, buffer, token);
                        token.ThrowIfCancellationRequested();
                        if (downloaded != length || !SHA1.HashData(buffer.AsSpan(0, length)).AsSpan().SequenceEqual(chunk.ChunkID))
                            throw new SteamFailure("A downloaded chunk failed verification. Resume to retry it.");
                        await RandomAccess.WriteAsync(stream.SafeFileHandle, buffer.AsMemory(0, length), (long)chunk.Offset, token);
                    }
                    progress(length);
                }
                finally { ArrayPool<byte>.Shared.Return(buffer); }
            });
            stream.Flush(flushToDisk: true);
        }
        ct.ThrowIfCancellationRequested();
        if (!await Matches(partial, file, ct))
            throw new SteamFailure("A downloaded file failed verification. Resume to retry it.");
        Directory.CreateDirectory(Path.GetDirectoryName(final)!);
        _ = SafePath(root, file.FileName); // Recheck after awaits and before promotion.
        File.Move(partial, final, overwrite: true);
    }
}
