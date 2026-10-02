using System.Text.Json.Serialization;

namespace Iridium.Steam;

public sealed record Game(uint AppId, string Name);
public sealed record SavedSession(string AccountName, string RefreshToken);
public sealed record InstalledGame(uint AppId, string Name, string Directory, string[] Executables)
{
    // Decimal strings preserve Steam's unsigned 64-bit IDs across Swift/JSON.
    public string? BuildId { get; init; }
    public string? OperationId { get; init; }
    public InstallOptions? Options { get; init; }
    public InstalledDepot[] Depots { get; init; } = [];
}
public sealed record InstalledDepot(uint DepotId, string ManifestId, uint AuthorizationAppId);
public sealed record BranchInfo(string Name, string? BuildId, bool PasswordRequired);
public sealed record GameDetails(uint AppId, BranchInfo[] Branches, string[] Languages, uint[] DlcAppIds);
public sealed record Snapshot
{
    public string Phase { get; init; } = "signedOut";
    public string Message { get; init; } = "Sign in to download your Steam games.";
    public bool Busy { get; init; }
    public bool SignedIn { get; init; }
    public string? AccountName { get; init; }
    public string? Error { get; init; }
    public string? FailureCode { get; init; }
    public SteamStorageDiagnostic? Storage { get; init; }
    public string? ChallengeUrl { get; init; }
    public Game[] Games { get; init; } = [];
    public uint? AppId { get; init; }
    public long CompletedBytes { get; init; }
    public long TotalBytes { get; init; }
    public InstalledGame? Installed { get; init; }
    public string? OperationId { get; init; }
    public long NetworkBytes { get; init; }
    public GameDetails? Details { get; init; }
}
public sealed record Command
{
    public string Action { get; init; } = "";
    public string? AccountName { get; init; }
    public string? Password { get; init; }
    public string? RefreshToken { get; init; }
    public string? Code { get; init; }
    public uint AppId { get; init; }
    public string? OperationId { get; init; }
    public InstallOptions Options { get; init; } = new();
    public string? ReuseDirectory { get; init; }
    // This command only. Never part of InstallOptions or an installation receipt.
    public bool OverrideStoragePreflight { get; init; }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(Snapshot))]
[JsonSerializable(typeof(Command))]
[JsonSerializable(typeof(SavedSession))]
[JsonSerializable(typeof(InstalledGame))]
[JsonSerializable(typeof(InstallOptions))]
public partial class SteamJson : JsonSerializerContext;

public sealed class SteamFailure(string message) : Exception(message);
