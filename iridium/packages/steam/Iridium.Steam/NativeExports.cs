using System.Runtime.InteropServices;
using System.Text.Json;

namespace Iridium.Steam;

public static class NativeExports
{
    static SteamEngine? engine;
    static readonly object Sync = new();

    [UnmanagedCallersOnly(EntryPoint = "iridium_steam_initialize")]
    public static int Initialize(nint path)
    {
        try
        {
            lock (Sync)
            {
                if (engine != null) return 1;
                var root = Marshal.PtrToStringUTF8(path);
                if (string.IsNullOrEmpty(root) || !Path.IsPathFullyQualified(root)) return 0;
                VerifiedFiles.RejectLink(root);
                Directory.CreateDirectory(root);
                engine = new(root);
                return 1;
            }
        }
        catch { return 0; } // Exceptions must never cross the C ABI.
    }

    [UnmanagedCallersOnly(EntryPoint = "iridium_steam_submit")]
    public static int Submit(nint json)
    {
        try
        {
            var text = Marshal.PtrToStringUTF8(json);
            if (text == null || text.Length > 32768) return 0;
            var command = JsonSerializer.Deserialize(text, SteamJson.Default.Command);
            return command != null && engine?.Submit(command) == true ? 1 : 0;
        }
        catch { return 0; }
    }

    [UnmanagedCallersOnly(EntryPoint = "iridium_steam_snapshot")]
    public static nint Snapshot()
    {
        try { return Marshal.StringToCoTaskMemUTF8(JsonSerializer.Serialize(engine?.Read() ?? new(), SteamJson.Default.Snapshot)); }
        catch { return 0; }
    }

    // One-time handoff to the native Keychain adapter. Never included in UI snapshots.
    [UnmanagedCallersOnly(EntryPoint = "iridium_steam_take_session")]
    public static nint TakeSession()
    {
        try
        {
            var saved = engine?.TakeSecret();
            return saved == null ? 0 : Marshal.StringToCoTaskMemUTF8(JsonSerializer.Serialize(saved, SteamJson.Default.SavedSession));
        }
        catch { return 0; }
    }

    [UnmanagedCallersOnly(EntryPoint = "iridium_steam_free")]
    public static void Free(nint pointer) { if (pointer != 0) Marshal.ZeroFreeCoTaskMemUTF8(pointer); }
}
