using System.Runtime.InteropServices;
using SteamKit2;

namespace Iridium.Steam;

public enum SteamCapacitySource { Unknown, ImportantUsage, VolumeAvailable, DriveAvailable }

public readonly record struct SteamCapacity(long? AvailableBytes, SteamCapacitySource Source)
{
    public SteamCapacity Validated() => AvailableBytes is >= 0 && Enum.IsDefined(Source) && Source != SteamCapacitySource.Unknown
        ? this : new(null, SteamCapacitySource.Unknown);

    public static unsafe SteamCapacity FromHost(nint callback, string directory)
    {
        if (callback == 0) return new(null, SteamCapacitySource.Unknown);
        var pointer = Marshal.StringToCoTaskMemUTF8(directory);
        try
        {
            int source = 0;
            var bytes = ((delegate* unmanaged[Cdecl]<nint, int*, long>)callback)(pointer, &source);
            return new SteamCapacity(bytes, source switch
            {
                1 => SteamCapacitySource.ImportantUsage,
                2 => SteamCapacitySource.VolumeAvailable,
                _ => SteamCapacitySource.Unknown,
            }).Validated();
        }
        finally { Marshal.FreeCoTaskMem(pointer); }
    }

    public static SteamCapacity FromDrive(string directory)
    {
        try { return new SteamCapacity(new DriveInfo(directory).AvailableFreeSpace, SteamCapacitySource.DriveAvailable).Validated(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        { return new(null, SteamCapacitySource.Unknown); }
    }
}

// Safe to persist/export: only byte counts, fixed categories, and this attempt's choice.
public sealed record SteamStorageDiagnostic(long RequiredBytes, long? AvailableBytes, long SafetyMarginBytes,
    string CapacitySource, bool Overridden);

public sealed class SteamStorageFailure(SteamStorageDiagnostic diagnostic) : Exception(
    diagnostic.AvailableBytes is long available
        ? FormattableString.Invariant($"Not enough free storage. This attempt needs {diagnostic.RequiredBytes / 1_000_000_000.0:F2} GB; the system reports {available / 1_000_000_000.0:F2} GB available. This includes a 256 MiB safety margin. Partial downloads are kept.")
        : "Available storage could not be measured. Retry to check again, or choose Download Anyway for this attempt. Partial downloads are kept.")
{
    public SteamStorageDiagnostic Diagnostic { get; } = diagnostic;
    public string Code => Diagnostic.AvailableBytes.HasValue ? "storage-insufficient" : "storage-unavailable";
}

public static class SteamStorage
{
    public const long SafetyMarginBytes = 256L * 1024 * 1024;

    public static SteamStorageDiagnostic Evaluate(long required, SteamCapacity capacity, bool overridePreflight)
    {
        if (required < SafetyMarginBytes) throw new ArgumentOutOfRangeException(nameof(required));
        capacity = capacity.Validated();
        return new(required, capacity.AvailableBytes, SafetyMarginBytes, capacity.Source switch
        {
            SteamCapacitySource.ImportantUsage => "important-usage",
            SteamCapacitySource.VolumeAvailable => "volume-available",
            SteamCapacitySource.DriveAvailable => "drive-available",
            _ => "unknown",
        }, overridePreflight);
    }

    public static void RequireCapacity(SteamStorageDiagnostic diagnostic)
    {
        if (!diagnostic.Overridden && (diagnostic.AvailableBytes == null || diagnostic.AvailableBytes < diagnostic.RequiredBytes))
            throw new SteamStorageFailure(diagnostic);
    }

    public static async Task Check(string install, string staging, IEnumerable<DepotManifest.FileData> files,
        Func<string, SteamCapacity> measure, bool overridePreflight, Action<SteamStorageDiagnostic>? report, CancellationToken ct)
    {
        long required = SafetyMarginBytes;
        foreach (var file in files)
            required = checked(required + await VerifiedFiles.RequiredStorage(install, staging, file, ct));
        ct.ThrowIfCancellationRequested();
        // Measure the actual destination only AFTER manifests and partial hashes are checked.
        // A previous install's reusable files still need a separate copy in this destination.
        var diagnostic = Evaluate(required, measure(install), overridePreflight);
        ct.ThrowIfCancellationRequested();
        report?.Invoke(diagnostic);
        RequireCapacity(diagnostic);
    }
}
