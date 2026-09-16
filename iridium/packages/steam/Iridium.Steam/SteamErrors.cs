using System.Net.WebSockets;
using System.Reflection;
using SteamKit2.Authentication;

namespace Iridium.Steam;

public static class SteamErrors
{
    public static string Describe(Exception error, string phase)
    {
        // Wrapper messages and arbitrary exception text can include tokens or paths.
        // Use only fixed categories and a whitelisted operation phase in diagnostics.
        while (error is TypeInitializationException or TargetInvocationException && error.InnerException != null)
            error = error.InnerException;
        var stage = phase switch
        {
            "initializing" or "connecting" or "authenticating" or "syncing" or "resolving"
                or "downloading" or "finalizing" or "guard" or "approval" or "qr" => phase,
            _ => "request",
        };
        var (kind, message) = error switch
        {
            SteamFailure => ("steam", error.Message),
            PlatformNotSupportedException => ("platform", "The Steam module used a feature unavailable on this device. Install an updated build."),
            DllNotFoundException or EntryPointNotFoundException => ("native-library", "The Steam module is missing a required native component. Install an updated build."),
            NotSupportedException or MissingMethodException or TypeLoadException => ("runtime", "The Steam module could not run this operation. Install an updated build."),
            TimeoutException => ("timeout", "Steam did not respond in time. Please retry."),
            AuthenticationException => ("authentication", "Steam rejected the sign-in. Check your credentials and Steam Guard, then retry."),
            HttpRequestException or WebSocketException or System.Net.Sockets.SocketException
                => ("network", "Could not connect to Steam. Check your connection and retry."),
            IOException => ("io", stage is "downloading" or "finalizing"
                ? "The download could not be saved. Check free storage and resume."
                : "Steam communication was interrupted. Please retry."),
            _ => ("unexpected", "The Steam module could not complete this operation. Report the error code below."),
        };
        return $"{message} [steam/{stage}/{kind}/{error.HResult:X8}]";
    }
}
