using System.Security.Cryptography;
using System.Text;
using SteamKit2;

namespace Iridium.Steam;

// Only Windows Auto-Cloud roots we can map to the actual per-game runtime copy.
// SDK Remote Storage, cross-platform aliases and root overrides need a verified
// runtime contract before they can be added. Never guess a folder from a filename.
public sealed class CloudPaths
{
    readonly string prefix;
    readonly string account;
    readonly Dictionary<string, string> roots = new(StringComparer.OrdinalIgnoreCase);
    readonly List<(string Root, string Folder, string Pattern, bool Recursive, uint Platforms)> rules = [];
    public const int MaximumFiles = 4096;
    public const int MaximumFileBytes = 256 * 1024 * 1024;

    public CloudPaths(string prefix, string account, KeyValue config)
    {
        this.prefix = Path.GetFullPath(prefix);
        this.account = account;
        Safe(this.prefix);
        roots["GameInstall"] = Resolve(this.prefix, "drive_c/IridiumGame");
        var users = Resolve(this.prefix, "drive_c/users");
        var candidates = Directory.Exists(users) ? Directory.GetDirectories(users)
            .Where(p => !new[] { "Public", "Default", "All Users", "Default User" }.Contains(Path.GetFileName(p), StringComparer.OrdinalIgnoreCase)).ToArray() : [];
        // Multiple users are ambiguous. Do not pick the newest or the first.
        if (candidates.Length == 1)
        {
            Safe(candidates[0]);
            foreach (var (name, path) in new[] { ("WinMyDocuments", "Documents"), ("WinSavedGames", "Saved Games"),
                ("WinAppDataLocal", "AppData/Local"), ("WinAppDataLocalLow", "AppData/LocalLow"), ("WinAppDataRoaming", "AppData/Roaming") })
                roots[name] = Resolve(candidates[0], path);
        }
        var ufs = config["ufs"];
        if (ufs["rootoverrides"].Children.Any(r => r["os"].Value?.Equals("Windows", StringComparison.OrdinalIgnoreCase) == true))
            throw new SteamFailure("This game's Windows Cloud root overrides are not supported. Saves were kept.");
        foreach (var rule in ufs["savefiles"].Children)
        {
            var platforms = rule["platforms"].Children.Select(p => p.Value?.ToLowerInvariant()).ToArray();
            if (platforms.Length > 0 && !platforms.Contains("windows") && !platforms.Contains("all")) continue;
            var root = rule["root"].Value ?? "";
            if (!roots.ContainsKey(root)) continue;
            var folder = Expand(rule["path"].Value ?? "").Replace('\\', '/').TrimEnd('/');
            if (folder == ".") folder = ""; // Steam's documented root-directory marker.
            var pattern = rule["pattern"].Value ?? "";
            if (pattern.Length is 0 or > 255 || pattern.IndexOfAny(['/', '\\', ':', '\0']) >= 0 || pattern.Any(char.IsControl))
                throw new SteamFailure("Steam returned an unsupported save pattern.");
            if (folder != "") _ = Resolve(roots[root], folder);
            rules.Add((roots.Keys.Single(k => k.Equals(root, StringComparison.OrdinalIgnoreCase)), folder, pattern,
                rule["recursive"].Value == "1", platforms.Length == 0 || platforms.Contains("all") ? uint.MaxValue : 1));
        }
        if (rules.Count == 0) throw new SteamFailure("No verified Windows Auto-Cloud save mapping is available for this game.");
    }

    string Expand(string value) => value.Replace("{64BitSteamID}", account)
        .Replace("{Steam3AccountID}", ((uint)ulong.Parse(account)).ToString(System.Globalization.CultureInfo.InvariantCulture));

    public static void Safe(string path)
    {
        // Check every ancestor too: checking only the requested root misses a link above it.
        for (var current = Path.GetFullPath(path); current != null; current = Path.GetDirectoryName(current))
            VerifiedFiles.RejectLink(current);
    }

    public static string Resolve(string root, string relative)
    {
        Safe(root);
        _ = VerifiedFiles.SafePath(root, relative);
        var current = Path.GetFullPath(root);
        foreach (var part in relative.Replace('\\', '/').Split('/'))
        {
            var children = Directory.Exists(current) ? Directory.EnumerateFileSystemEntries(current).Take(MaximumFiles + 1).ToArray() : [];
            if (children.Length > MaximumFiles) throw new SteamFailure("Save directory contains too many entries.");
            var matches = children.Where(p => Path.GetFileName(p).Equals(part, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (matches.Length > 1) throw new SteamFailure("Ambiguous save path casing. Saves were kept.");
            current = matches.Length == 1 ? matches[0] : Path.Combine(current, part);
            Safe(current);
        }
        return current;
    }

    public string Local(string cloudPath)
    {
        var end = cloudPath.IndexOf('%', 1);
        if (cloudPath.Length > 4096 || !cloudPath.StartsWith('%') || end < 2)
            throw new SteamFailure("This Cloud path has no verified runtime mapping.");
        var root = cloudPath[1..end];
        var rest = Expand(cloudPath[(end + 1)..]).Replace('\\', '/');
        if (!roots.TryGetValue(root, out var folder)) throw new SteamFailure("Unsupported Cloud root. Saves were kept.");
        var match = rules.Any(r => r.Root.Equals(root, StringComparison.OrdinalIgnoreCase) && MatchesRule(rest, r.Folder, r.Pattern, r.Recursive));
        if (!match) throw new SteamFailure("Cloud path is outside the game's verified save rules. Saves were kept.");
        return Resolve(folder, rest);
    }

    public uint Platforms(string cloudPath)
    {
        var end = cloudPath.IndexOf('%', 1);
        if (end < 2) throw new SteamFailure("Unsupported Cloud path.");
        var root = cloudPath[1..end];
        var rest = Expand(cloudPath[(end + 1)..]).Replace('\\', '/');
        var matches = rules.Where(r => r.Root.Equals(root, StringComparison.OrdinalIgnoreCase) && MatchesRule(rest, r.Folder, r.Pattern, r.Recursive)).ToArray();
        if (matches.Length == 0 || matches.Select(r => r.Platforms).Distinct().Count() != 1)
            throw new SteamFailure("Cloud save platform rules are ambiguous.");
        return matches[0].Platforms;
    }

    static bool MatchesRule(string rest, string folder, string pattern, bool recursive)
    {
        var relative = folder.Length == 0 ? rest : rest.StartsWith(folder + "/", StringComparison.OrdinalIgnoreCase) ? rest[(folder.Length + 1)..] : "";
        return relative.Length > 0 && (recursive || !relative.Contains('/')) &&
            System.IO.Enumeration.FileSystemName.MatchesSimpleExpression(pattern, Path.GetFileName(relative), true);
    }

    public IEnumerable<string> LocalNames()
    {
        var visited = new int[1];
        foreach (var rule in rules)
        {
            var folder = rule.Folder == "" ? roots[rule.Root] : Resolve(roots[rule.Root], rule.Folder);
            if (!Directory.Exists(folder)) continue;
            foreach (var path in Walk(folder, rule.Recursive, 0, visited))
            {
                var relative = Path.GetRelativePath(roots[rule.Root], path).Replace('\\', '/');
                if (MatchesRule(relative, rule.Folder, rule.Pattern, rule.Recursive)) yield return "%" + rule.Root + "%" + relative;
            }
        }
    }

    static IEnumerable<string> Walk(string folder, bool recursive, int depth, int[] visited)
    {
        if (depth > 32) throw new SteamFailure("Save folder nesting is too deep.");
        Safe(folder);
        // Reject directory links before enumeration can follow them.
        foreach (var child in Directory.EnumerateFileSystemEntries(folder))
        {
            if (++visited[0] > MaximumFiles) throw new SteamFailure("Too many save folder entries.");
            Safe(child);
            if (Directory.Exists(child))
            {
                if (recursive) foreach (var path in Walk(child, true, depth + 1, visited)) yield return path;
            }
            else if (File.Exists(child)) yield return child;
        }
    }

    public static async Task<byte[]> Bytes(string path, CancellationToken ct)
    {
        Safe(path);
        if (new FileInfo(path).Length > MaximumFileBytes) throw new SteamFailure("A save exceeds the 256 MiB safety limit.");
        // O_RDWR avoids a blocking open on an attacker-created FIFO. We never
        // write through this handle. Read-only saves fail safely instead of
        // bypassing permissions; non-seekable special files are unsupported.
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read, 131072, true);
        return await ReadOpenedSave(stream, ct);
    }
    public static async Task<byte[]> ReadOpenedSave(Stream stream, CancellationToken ct)
    {
        if (!stream.CanSeek) throw new SteamFailure("A Cloud save is not a regular seekable file. Saves were kept.");
        var length = stream.Length;
        if (length is < 0 or > MaximumFileBytes) throw new SteamFailure("A save exceeds the 256 MiB safety limit.");
        var bytes = new byte[checked((int)length)];
        await stream.ReadExactlyAsync(bytes, ct);
        if (stream.ReadByte() != -1) throw new SteamFailure("A save changed while being read. Retry after the game stops.");
        return bytes;
    }
    public static string Sha(byte[] bytes) => Convert.ToHexString(SHA1.HashData(bytes));
    public static string Key(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    public static void Verify(byte[] bytes, CloudFile file)
    {
        if (bytes.Length != file.Size || Sha(bytes) != file.Sha) throw new SteamFailure("Save verification failed. Existing saves were kept.");
    }
    public static async Task<CloudFile?> Read(string name, string path, CancellationToken ct)
    {
        Safe(path);
        if (!File.Exists(path)) return null;
        var bytes = await Bytes(path, ct);
        return new(name, Sha(bytes), bytes.Length, (ulong)Math.Max(0, new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeSeconds()));
    }
}
