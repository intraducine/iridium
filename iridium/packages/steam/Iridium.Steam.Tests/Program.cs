using System.Security.Cryptography;
using Iridium.Steam;
using SteamKit2;
using SteamKit2.CDN;
using SteamKit2.Internal;
using ProtoBuf;

var checks = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception(name); checks++; }
void Reject(Action action, string name)
{
    try { action(); } catch (SteamFailure) { checks++; return; }
    throw new Exception("Accepted " + name);
}
async Task RejectAsync(Func<Task> action, string name)
{
    try { await action(); } catch (SteamFailure) { checks++; return; }
    throw new Exception("Accepted " + name);
}

// Client construction is shared by password and QR sign-in. On iOS the upstream
// Process.StartTime call throws before any network request; exercise construction.
using (var client = new SteamConnection())
    Check(!client.IsLoggedOn, "Steam client initializes without OS process inspection on iOS");

var privateDetail = "password=secret /private/account refresh_token=secret";
var platformFailure = SteamErrors.Describe(new System.Reflection.TargetInvocationException(
    new PlatformNotSupportedException(privateDetail)), "initializing");
Check(platformFailure.Contains("steam/initializing/platform/"), "nested iOS platform failure has actionable code");
Check(!platformFailure.Contains(privateDetail), "platform error text is redacted");
var unknownFailure = SteamErrors.Describe(new Exception(privateDetail), privateDetail);
Check(unknownFailure.Contains("steam/request/unexpected/") && !unknownFailure.Contains(privateDetail), "unknown failure and stage never leak data");
Check(SteamErrors.Describe(new HttpRequestException(privateDetail), "connecting").Contains("steam/connecting/network/"), "network failure identified");
Check(!SteamErrors.Describe(new IOException(privateDetail), "connecting").Contains("storage"), "connection IO is not misreported as storage");

void Protocol<[System.Diagnostics.CodeAnalysis.DynamicallyAccessedMembers(System.Diagnostics.CodeAnalysis.DynamicallyAccessedMemberTypes.All)] T>() where T : class, IExtensible, new()
{
    using var stream = new MemoryStream();
    Serializer.Serialize(stream, new T());
    stream.Position = 0;
    Check(Serializer.Deserialize<T>(stream) != null, typeof(T).Name);
}
Protocol<CAuthentication_GetPasswordRSAPublicKey_Request>();
Protocol<CAuthentication_GetPasswordRSAPublicKey_Response>();
Protocol<CAuthentication_BeginAuthSessionViaCredentials_Request>();
Protocol<CAuthentication_BeginAuthSessionViaCredentials_Response>();
Protocol<CAuthentication_BeginAuthSessionViaQR_Request>();
Protocol<CAuthentication_BeginAuthSessionViaQR_Response>();
Protocol<CAuthentication_PollAuthSessionStatus_Request>();
Protocol<CAuthentication_PollAuthSessionStatus_Response>();
Protocol<CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request>();
Protocol<CAuthentication_UpdateAuthSessionWithSteamGuardCode_Response>();
Protocol<CContentServerDirectory_GetServersForSteamPipe_Request>();
Protocol<CContentServerDirectory_GetServersForSteamPipe_Response>();
Protocol<CContentServerDirectory_GetManifestRequestCode_Request>();
Protocol<CContentServerDirectory_GetManifestRequestCode_Response>();
Protocol<CContentServerDirectory_GetCDNAuthToken_Request>();
Protocol<CContentServerDirectory_GetCDNAuthToken_Response>();
Protocol<ContentManifestPayload>();
Protocol<ContentManifestMetadata>();
Protocol<ContentManifestSignature>();

// Exercise the same serializers in both managed and NativeAOT runs.
using (var wire = new MemoryStream())
{
    var input = new CPlayer_GetOwnedGames_Response();
    input.games.Add(new() { appid = 42, name = "Fixture game" });
    ProtoBuf.Serializer.Serialize(wire, input);
    wire.Position = 0;
    var output = ProtoBuf.Serializer.Deserialize<CPlayer_GetOwnedGames_Response>(wire);
    Check(output.games.Single().appid == 42, "Steam protobuf repeated message round trip");
}

var root = Path.Combine(Path.GetTempPath(), "iridium-steam-test-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    foreach (var unsafePath in new[] { "../escape", "/absolute", "C:\\escape", "a/../../escape", "a\\..\\b", "a//b", "a/./b", "trailing.", "a/file:stream", "a/\0b" })
        Reject(() => VerifiedFiles.SafePath(root, unsafePath), unsafePath);
    Check(VerifiedFiles.SafePath(root, "game\\data/file.bin") == Path.Combine(root, "game", "data", "file.bin"), "Windows separators");

    var bytes = "first verified chunk;second verified chunk"u8.ToArray();
    var chunks = new[] { bytes[..21], bytes[21..] };
    var file = new DepotManifest.FileData { FileName = "bin/game.exe", TotalSize = (ulong)bytes.Length, FileHash = SHA1.HashData(bytes) };
    ulong offset = 0;
    foreach (var data in chunks)
    {
        file.Chunks.Add(new(SHA1.HashData(data), 0, offset, (uint)data.Length, (uint)data.Length));
        offset += (ulong)data.Length;
    }
    var calls = 0;
    Task<int> Fetch(DepotManifest.ChunkData chunk, byte[] buffer, CancellationToken ct)
    {
        Interlocked.Increment(ref calls);
        bytes.AsSpan((int)chunk.Offset, (int)chunk.UncompressedLength).CopyTo(buffer);
        return Task.FromResult((int)chunk.UncompressedLength);
    }
    var install = Path.Combine(root, "content");
    var stage = Path.Combine(root, "partial");
    Directory.CreateDirectory(install);
    long progress = 0;
    await VerifiedFiles.Download(install, stage, file, Fetch, n => Interlocked.Add(ref progress, n), default);
    Check(calls == 2 && progress == bytes.Length, "actual chunk progress");
    Check(File.ReadAllBytes(Path.Combine(install, "bin", "game.exe")).SequenceEqual(bytes), "verified promotion");
    await VerifiedFiles.Download(install, stage, file, Fetch, _ => { }, default);
    Check(calls == 2, "verified files are reused");

    // Interrupt one chunk. The other verified chunk must survive and be reused.
    file.FileName = "resume.exe";
    await RejectAsync(() => VerifiedFiles.Download(install, stage, file, async (chunk, buffer, ct) =>
    {
        if (chunk.Offset > 0) { await Task.Delay(100, ct); throw new SteamFailure("Injected network failure"); }
        return await Fetch(chunk, buffer, ct);
    }, _ => { }, default), "interrupted download");
    Check(!File.Exists(Path.Combine(install, "resume.exe")), "incomplete file is not promoted");
    calls = 0;
    await VerifiedFiles.Download(install, stage, file, Fetch, _ => { }, default);
    Check(calls == 1, "only missing chunk downloads on resume");

    file.FileName = "corrupt.exe";
    await RejectAsync(() => VerifiedFiles.Download(install, stage, file, (chunk, buffer, ct) =>
    {
        Array.Clear(buffer); return Task.FromResult((int)chunk.UncompressedLength);
    }, _ => { }, default), "corrupt CDN data");
    Check(!File.Exists(Path.Combine(install, "corrupt.exe")), "corrupt file is not promoted");
    var originalOffset = file.Chunks[1].Offset;
    file.Chunks[1].Offset = 0;
    Reject(() => VerifiedFiles.Validate(file), "overlapping chunks");
    file.Chunks[1].Offset = originalOffset;
    file.LinkTarget = "../escape";
    Reject(() => VerifiedFiles.Validate(file), "manifest symlink");
    file.LinkTarget = null;
    file.Chunks[0].UncompressedLength = VerifiedFiles.MaximumChunkBytes + 1;
    Reject(() => VerifiedFiles.Validate(file), "unbounded chunk allocation");

    var depot = new KeyValue("100");
    var config = new KeyValue("config");
    config.Children.Add(new("oslist", "linux")); depot.Children.Add(config);
    Check(!SteamInstaller.SelectWindowsDepot(depot), "Linux depot excluded");
    config["oslist"].Value = "windows,linux";
    Check(SteamInstaller.SelectWindowsDepot(depot), "multi-platform depot selected");
    config.Children.Add(new("language", "german"));
    Check(!SteamInstaller.SelectWindowsDepot(depot), "other language excluded");

    // Steam lists most Valve caches with optional HTTPS; they must still be used over TLS.
    CContentServerDirectory_ServerInfo Listed(string type, string host, string https, float load,
        bool proxy = false, bool china = false, uint app = 0, string? vhost = null)
    {
        var info = new CContentServerDirectory_ServerInfo
        {
            type = type, host = host, vhost = vhost ?? host, https_support = https,
            weighted_load = load, use_as_proxy = proxy, steam_china_only = china,
        };
        if (app != 0) info.allowed_app_ids.Add(app);
        return info;
    }
    var listed = new[]
    {
        Listed("SteamCache", "cache1-fra1.steamcontent.com", "optional", 2),
        Listed("CDN", "steampipe.akamaized.net", "mandatory", 1),
        Listed("CDN", "this-app.example.net", "optional", 3, app: 42),
        Listed("CDN", "plain.example.net", "", 0),
        Listed("SteamCache", "proxy.example.net", "optional", 0, proxy: true),
        Listed("SteamCache", "china.example.net", "optional", 0, china: true),
        Listed("OpenCache", "isp.example.net", "optional", 0),
        Listed("CDN", "other-app.example.net", "mandatory", 0, app: 999),
        Listed("CDN", "aliased.example.net", "mandatory", 0, vhost: "other.example.net"),
        Listed("CDN", "bad host!", "mandatory", 0),
        Listed("CDN", "", "mandatory", 0),
    };
    var chosen = SteamInstaller.SelectContentServers(listed, 42);
    Check(chosen.Select(s => s.Host).SequenceEqual(new[] { "steampipe.akamaized.net", "cache1-fra1.steamcontent.com", "this-app.example.net" }),
        "TLS-capable caches and CDNs are kept in load order");
    Check(chosen.All(s => s.Protocol == Server.ConnectionProtocol.HTTPS && s.Port == 443 && s.VHost == s.Host),
        "optional-HTTPS hosts are used over TLS only");
    Check(SteamInstaller.SelectContentServers(listed, 42, 1).Length == 1, "server limit applies");
    Check(SteamInstaller.SelectContentServers(new[] { listed[3], listed[4] }, 42).Length == 0, "no plain HTTP or proxy fallback");

    var engine = new SteamEngine(root);
    Check(!engine.Submit(new() { Action = "install", AppId = 42 }), "signed-out install rejected");
    Check(!engine.Submit(new() { Action = "guard", Code = "12345" }), "unsolicited guard code rejected");
    Check(engine.TakeSecret() == null, "no fabricated session");
    Check(!engine.Read().SignedIn, "starts signed out");
}
finally { Directory.Delete(root, recursive: true); }

if (args.Contains("--network"))
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
    using var connection = new SteamConnection();
    await connection.Connect(timeout.Token);
    // Public app metadata over a real CM connection; no personal account or game downloads.
    connection.Client.GetHandler<SteamUser>()!.LogOnAnonymous();
    await Task.Delay(3000, timeout.Token);
    var info = await connection.AppInfo(570, timeout.Token);
    Check(info["common"]["name"].Value?.Length > 0, "real Steam CM metadata");
    var qr = new SteamEngine(Path.GetTempPath());
    Check(qr.Submit(new() { Action = "qr" }), "QR login starts");
    while (qr.Read().ChallengeUrl == null && qr.Read().Busy)
        await Task.Delay(200, timeout.Token);
    Check(Uri.TryCreate(qr.Read().ChallengeUrl, UriKind.Absolute, out _),
        "real Steam QR authentication challenge: " + (qr.Read().Error ?? "no challenge received"));
    qr.Submit(new() { Action = "cancel" });
    while (qr.Read().Busy) await Task.Delay(200, timeout.Token);
    Check(!qr.Read().SignedIn && qr.TakeSecret() == null, "cancelled QR login does not create a session");
}
Console.WriteLine($"PASS: {checks} Steam integration checks.");
