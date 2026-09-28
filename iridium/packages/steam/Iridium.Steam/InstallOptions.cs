using System.Security.Cryptography;
using System.Text;
using SteamKit2;

namespace Iridium.Steam;

public sealed record InstallOptions
{
    public string Branch { get; init; } = "public";
    public string Language { get; init; } = "english";
    public string Architecture { get; init; } = "64";
    public bool IncludeDlc { get; init; } = true;
    // Empty means all authorized DLC. Explicit IDs never grant ownership.
    public uint[] DlcAppIds { get; init; } = [];
    public int MaxDownloads { get; init; } = 4;

    public InstallOptions Validate()
    {
        static bool Identifier(string? value, int max) => !string.IsNullOrWhiteSpace(value)
            && value.Length <= max && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-' or '.');
        if (!Identifier(Branch, 128) || !Identifier(Language, 64) || Architecture is not ("32" or "64")
            || MaxDownloads is < 1 or > 8 || DlcAppIds == null || DlcAppIds.Length > 500 || DlcAppIds.Contains(0u))
            throw new SteamFailure("The download options are invalid. Choose a Windows architecture, language, and available branch.");
        return this with { Language = Language.ToLowerInvariant(), DlcAppIds = DlcAppIds.Distinct().Order().ToArray() };
    }

    public bool IncludesDlc(uint id) => id == 0 || (IncludeDlc && (DlcAppIds.Length == 0 || DlcAppIds.Contains(id)));

    public string StorageSuffix()
    {
        var options = Validate();
        // Preserve PR #40's default folder, so existing partial downloads resume.
        if (options.Branch == "public" && options.Language == "english" && options.Architecture == "64"
            && options.IncludeDlc && options.DlcAppIds.Length == 0) return "";
        var identity = $"{options.Branch}\n{options.Language}\n{options.Architecture}\n{options.IncludeDlc}\n{string.Join(',', options.DlcAppIds)}";
        return "/variants/" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..24];
    }
}

public static class SteamDepotSelection
{
    public static bool IsWindows(KeyValue depot, InstallOptions options)
    {
        var config = depot["config"];
        var os = config["oslist"].Value;
        var architecture = config["osarch"].Value;
        var language = config["language"].Value;
        return (string.IsNullOrEmpty(os) || os.Split(',').Any(s => s.Trim().Equals("windows", StringComparison.OrdinalIgnoreCase)))
            && (string.IsNullOrEmpty(architecture) || architecture == options.Architecture)
            && (string.IsNullOrEmpty(language) || language.Equals(options.Language, StringComparison.OrdinalIgnoreCase))
            && !config["lowviolence"].AsBoolean();
    }

    public static BranchInfo[] Branches(KeyValue info) => info["depots"]["branches"].Children
        .Where(b => !string.IsNullOrWhiteSpace(b.Name))
        .Select(b => new BranchInfo(b.Name!, b["buildid"].Value, b["pwdrequired"].AsBoolean()))
        .OrderByDescending(b => b.Name == "public").ThenBy(b => b.Name, StringComparer.OrdinalIgnoreCase).ToArray();

    public static uint[] DlcIds(KeyValue info) => (info["extended"]["listofdlc"].Value ?? "").Split(',')
        .Select(v => uint.TryParse(v.Trim(), out var id) ? id : 0)
        .Concat(info["depots"].Children.Select(d => d["dlcappid"].AsUnsignedInteger()))
        .Where(id => id != 0).Distinct().Order().ToArray();

    public static GameDetails Details(uint appId, KeyValue info) => new(appId, Branches(info),
        info["depots"].Children.Select(d => d["config"]["language"].Value)
            .Where(s => !string.IsNullOrWhiteSpace(s)).Select(s => s!).Append("english")
            .Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToArray(), DlcIds(info));

    public static (string Branch, ulong Id)? Manifest(KeyValue section, string branch)
    {
        // Unchanged depots are often published only on public even for a beta build.
        foreach (var candidate in new[] { branch, "public" }.Distinct())
            if (ulong.TryParse(section["manifests"][candidate]["gid"].Value, out var id) && id != 0)
                return (candidate, id);
        return null;
    }

    public static string Build(KeyValue info, string branch)
    {
        var selected = Branches(info).FirstOrDefault(b => b.Name.Equals(branch, StringComparison.Ordinal));
        if (selected == null || !ulong.TryParse(selected.BuildId, out var build) || build == 0)
            throw new SteamFailure("The selected Steam branch is unavailable. Refresh its download options.");
        if (selected.PasswordRequired)
            throw new SteamFailure("Password-protected Steam branches are not supported. Choose an available public branch.");
        return build.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    public static uint[] AuthorizationApps(uint gameId, uint sourceId, uint dlcId) =>
        new[] { dlcId, sourceId, gameId }.Where(id => id != 0).Distinct().ToArray();
}


public sealed record SteamInstallLayout(string RelativeRoot, string Content, string Partial, string? ReuseDirectory)
{
    public static SteamInstallLayout Resolve(string root, uint appId, string buildId, InstallOptions options,
        string? operationId, string? reuseDirectory)
    {
        if (appId == 0 || !ulong.TryParse(buildId, out var build) || build == 0)
            throw new SteamFailure("The Steam installation identity is invalid.");
        var relative = $"{appId}/{build}{options.StorageSuffix()}";
        var original = VerifiedFiles.SafePath(root, relative + "/content");
        reuseDirectory = SteamInstaller.ValidateReuseDirectory(root, appId, reuseDirectory);
        // A verified installation can contain saves, mods, or files used by a
        // running game. Repair/update produces a separate install; never edit it.
        if (reuseDirectory != null || File.Exists(VerifiedFiles.SafePath(root, relative + "/installed.json")))
        {
            if (!Guid.TryParse(operationId, out var operation))
                throw new SteamFailure("Start a new queued repair to preserve the existing installation.");
            reuseDirectory ??= original;
            relative += "/checks/" + operation.ToString("N");
        }
        var content = VerifiedFiles.SafePath(root, relative + "/content");
        if (content == reuseDirectory)
            throw new SteamFailure("A repair cannot replace its source installation.");
        return new(relative, content, VerifiedFiles.SafePath(root, relative + "/partial"), reuseDirectory);
    }
}
