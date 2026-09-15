using System.Text.Json.Serialization;

namespace Iridium.Steam;

public sealed record Game(uint AppId, string Name);
public sealed record SavedSession(string AccountName, string RefreshToken);
public sealed record InstalledGame(uint AppId, string Name, string Directory, string[] Executables);
public sealed record Snapshot
{
    public string Phase { get; init; } = "signedOut";
    public string Message { get; init; } = "Sign in to download your Steam games.";
    public bool Busy { get; init; }
    public bool SignedIn { get; init; }
    public string? AccountName { get; init; }
    public string? Error { get; init; }
    public string? ChallengeUrl { get; init; }
    public Game[] Games { get; init; } = [];
    public uint? AppId { get; init; }
    public long CompletedBytes { get; init; }
    public long TotalBytes { get; init; }
    public InstalledGame? Installed { get; init; }
}
public sealed record Command
{
    public string Action { get; init; } = "";
    public string? AccountName { get; init; }
    public string? Password { get; init; }
    public string? RefreshToken { get; init; }
    public string? Code { get; init; }
    public uint AppId { get; init; }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(Snapshot))]
[JsonSerializable(typeof(Command))]
[JsonSerializable(typeof(SavedSession))]
[JsonSerializable(typeof(InstalledGame))]
public partial class SteamJson : JsonSerializerContext;

public sealed class SteamFailure(string message) : Exception(message);
