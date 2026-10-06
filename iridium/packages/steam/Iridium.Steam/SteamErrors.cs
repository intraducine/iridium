using System.Net.WebSockets;
using System.Reflection;
using SteamKit2.Authentication;

namespace Iridium.Steam;

public static class SteamErrors
{
    static Exception Unwrap(Exception error)
    {
        while (error is TypeInitializationException or TargetInvocationException && error.InnerException != null)
            error = error.InnerException;
        return error;
    }

    // .NET Unix IO exceptions retain errno (ENOSPC = 28); Windows uses HRESULT_FROM_WIN32.
    // Do not infer a full disk from arbitrary IO messages or unrelated error numbers.
    public static bool IsDiskFull(IOException error) => OperatingSystem.IsWindows()
        ? error.HResult is unchecked((int)0x80070070) or unchecked((int)0x80070027)
        : error.HResult == 28;

    public static string Code(Exception error) => Unwrap(error) switch
    {
        SteamStorageFailure storage => storage.Code,
        ChunkTransferFailure transfer => transfer.Code,
        IOException io when IsDiskFull(io) => "disk-full",
        IOException => "io",
        _ => "request-failed",
    };

    public static string Describe(Exception error, string phase)
    {
        // Wrapper messages and arbitrary exception text can include tokens or paths.
        // Use only fixed categories and a whitelisted operation phase in diagnostics.
        error = Unwrap(error);
        var stage = phase switch
        {
            "initializing" or "connecting" or "authenticating" or "syncing" or "resolving"
                or "downloading" or "verifying" or "finalizing" or "guard" or "approval" or "qr" or "cloud" => phase,
            _ => "request",
        };
        var (kind, message) = error switch
        {
            SteamStorageFailure storage => (storage.Code, storage.Message),
            ChunkTransferFailure transfer => (transfer.Code, transfer.Message),
            SteamFailure => ("steam", error.Message),
            PlatformNotSupportedException => ("platform", "The Steam module used a feature unavailable on this device. Install an updated build."),
            DllNotFoundException or EntryPointNotFoundException => ("native-library", "The Steam module is missing a required native component. Install an updated build."),
            NotSupportedException or MissingMethodException or TypeLoadException => ("runtime", "The Steam module could not run this operation. Install an updated build."),
            TimeoutException => ("timeout", "Steam did not respond in time. Please retry."),
            AuthenticationException => ("authentication", "Steam rejected the sign-in. Check your credentials and Steam Guard, then retry."),
            HttpRequestException or WebSocketException or System.Net.Sockets.SocketException
                => ("network", "Could not connect to Steam. Check your connection and retry."),
            IOException io when IsDiskFull(io) => ("disk-full", "The device ran out of storage while saving. Free some space, then resume. Verified partial downloads are kept."),
            IOException => ("io", stage == "cloud"
                ? "Cloud saves could not be read or preserved. Check available storage and file permissions; existing saves and backups are kept."
                : stage is "downloading" or "verifying" or "finalizing"
                ? "The download could not be saved because of a file I/O error. Retry; verified partial downloads are kept."
                : "Steam communication was interrupted. Please retry."),
            _ => ("unexpected", "The Steam module could not complete this operation. Report the error code below."),
        };
        return $"{message} [steam/{stage}/{kind}/{error.HResult:X8}]";
    }
}
