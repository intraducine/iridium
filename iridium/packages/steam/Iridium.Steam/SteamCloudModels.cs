namespace Iridium.Steam;

public sealed record CloudRequest
{
    public string GameId { get; init; } = "";
    public string Mode { get; init; } = "check";
    public CloudChoice? Choice { get; init; }
    public string? BackupId { get; init; }
}
// Choices bind to the exact pair shown by the last comparison, not just a filename.
public sealed record CloudChoice(string Path, string Side, string? LocalSha, string? RemoteSha);
public sealed record CloudFile(string Path, string Sha, long Size, ulong Time)
{
    public uint Platforms { get; init; } = 1; // Windows, unless verified rules declare all platforms.
}
public sealed record CloudEntry(string Path, string Action, CloudFile? Local, CloudFile? Remote);
public sealed record CloudListing(ulong Version, CloudFile[] Files);
public sealed record CloudStatus(string GameId, uint AppId, bool Enabled, string Phase, string Message,
    CloudEntry[] Entries, string[] Backups);
public sealed record CloudRecord
{
    public int Version { get; init; } = 1;
    public string Account { get; init; } = "";
    public uint AppId { get; init; }
    public string GameId { get; init; } = "";
    public bool Enabled { get; set; }
    public Dictionary<string, string> Baseline { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    // A pending write survives cancellation/process loss. It is never treated as success.
    public CloudPending? Pending { get; set; }
}
public sealed record CloudPending(string Path, string Side, string? Before, string After, string BackupId);

public static class CloudPlan
{
    public static string Action(string? local, string? remote, string? baseline)
    {
        if (local == remote) return "same";
        if (local == null) return baseline == "keep-missing:" + remote ? "keptMissing" : "conflict";
        if (remote == null) return "conflict";
        if (baseline == remote) return "upload";
        if (baseline == local) return "download";
        return "conflict";
    }
}

public interface ICloudTransport
{
    string Account { get; }
    Task<SteamKit2.KeyValue> Configuration(uint appId, CancellationToken ct);
    Task<CloudListing> List(uint appId, CancellationToken ct);
    Task<byte[]> Download(uint appId, CloudFile file, CancellationToken ct);
    // Return only after commit AND blocking batch completion are acknowledged.
    Task Upload(uint appId, CloudFile file, byte[] data, CloudFile? expectedRemote, ulong expectedVersion, CancellationToken ct);
}
