using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;
using SteamKit2;
using SteamKit2.CDN;
using SteamKit2.Internal;

namespace Iridium.Steam;

public sealed class SteamInstaller(SteamConnection connection)
{
    sealed record Depot(uint Id, ulong ManifestId, byte[] Key, DepotManifest Manifest);

    public static bool SelectWindowsDepot(KeyValue depot)
    {
        var config = depot["config"];
        var os = config["oslist"].Value;
        var arch = config["osarch"].Value;
        var language = config["language"].Value;
        return (string.IsNullOrEmpty(os) || os.Split(',').Contains("windows"))
            && (string.IsNullOrEmpty(arch) || arch == "64")
            && (string.IsNullOrEmpty(language) || language == "english")
            && !config["lowviolence"].AsBoolean();
    }

    // SteamKit marks a host HTTPS only when Steam reports "mandatory". Valve's own
    // caches usually report "optional" and still serve TLS on 443, so the earlier
    // Protocol filter left many regions with no server. Accept every TLS-capable
    // Steam cache or CDN host and always connect over HTTPS; plain HTTP is never used.
    public static Server[] SelectContentServers(IEnumerable<CContentServerDirectory_ServerInfo> candidates, uint appId, int limit = 6)
        => candidates
            .Where(s => s.type is "SteamCache" or "CDN"
                && s.https_support is "optional" or "mandatory"
                && !s.use_as_proxy && !s.steam_china_only
                && !string.IsNullOrEmpty(s.host) && Uri.CheckHostName(s.host) == UriHostNameType.Dns
                && (string.IsNullOrEmpty(s.vhost) || s.vhost == s.host)
                && (s.allowed_app_ids.Count == 0 || s.allowed_app_ids.Contains(appId)))
            .OrderBy(s => s.weighted_load)
            .Select(s => (Server)new DnsEndPoint(s.host, 443))
            .Take(limit).ToArray();

    public async Task<InstalledGame> Install(Game game, string root, Action<long, long> progress,
        Action<string> phase, CancellationToken ct)
    {
        var info = await connection.AppInfo(game.AppId, ct);
        var build = info["depots"]["branches"]["public"]["buildid"].Value;
        if (!ulong.TryParse(build, out var buildId)) throw new SteamFailure("The public Windows build is unavailable.");
        var install = VerifiedFiles.SafePath(root, $"{game.AppId}/{buildId}/content");
        var staging = VerifiedFiles.SafePath(root, $"{game.AppId}/{buildId}/partial");
        Directory.CreateDirectory(install);
        var content = connection.Client.GetHandler<SteamContent>()!;
        var apps = connection.Client.GetHandler<SteamApps>()!;
        using var cdn = new Client(connection.Client);
        var directory = connection.Client.GetHandler<SteamUnifiedMessages>()!.CreateService<ContentServerDirectory>();
        async Task<Server[]> ResolveServers(uint cellId, uint maxServers)
        {
            var response = await directory.GetServersForSteamPipe(new() { cell_id = cellId, max_servers = maxServers })
                .ToTask().WaitAsync(TimeSpan.FromSeconds(30), ct);
            if (response.Result != EResult.OK) throw new SteamFailure($"Steam did not provide a download server list ({response.Result}). Try again shortly.");
            return SelectContentServers(response.Body.servers, game.AppId);
        }
        // The client's cell list can be short; ask again without a cell before giving up.
        var servers = await ResolveServers(connection.Client.CellID ?? 0, 20);
        if (servers.Length == 0) servers = await ResolveServers(0, 50);
        if (servers.Length == 0) throw new SteamFailure("Steam has no secure download servers available. Try again shortly.");
        var authTokens = new ConcurrentDictionary<string, string>();

        async Task<T> FromCDN<T>(uint depotId, Func<Server, string?, Task<T>> operation, CancellationToken token)
        {
            for (var attempt = 0; attempt < Math.Min(3, servers.Length); attempt++)
            {
                token.ThrowIfCancellationRequested();
                var server = servers[attempt];
                var tokenKey = $"{depotId}:{server.Host}";
                try
                {
                    authTokens.TryGetValue(tokenKey, out var auth);
                    try { return await operation(server, auth); }
                    catch (SteamKitWebRequestException e) when (e.StatusCode == System.Net.HttpStatusCode.Forbidden)
                    {
                        var granted = await content.GetCDNAuthToken(game.AppId, depotId, server.Host!)
                            .WaitAsync(TimeSpan.FromSeconds(30), token);
                        if (granted.Result != EResult.OK) throw new SteamFailure("Steam denied access to this game's content.");
                        authTokens[tokenKey] = granted.Token;
                        return await operation(server, granted.Token);
                    }
                }
                catch (Exception e) when (attempt < Math.Min(3, servers.Length) - 1
                    && e is HttpRequestException or IOException or TaskCanceledException or SteamKitWebRequestException)
                {
                    await Task.Delay(TimeSpan.FromSeconds(attempt + 1), token);
                }
            }
            throw new SteamFailure("Steam download servers are unavailable. Your partial download is safe to resume.");
        }

        var depots = new List<Depot>();
        foreach (var section in info["depots"].Children)
        {
            ct.ThrowIfCancellationRequested();
            if (!uint.TryParse(section.Name, out var id) || !SelectWindowsDepot(section)) continue;
            var manifestSection = section;
            var sharedApp = section["depotfromapp"].AsUnsignedInteger();
            if (sharedApp != 0)
                manifestSection = (await connection.AppInfo(sharedApp, ct))["depots"][section.Name];
            if (!ulong.TryParse(manifestSection["manifests"]["public"]["gid"].Value, out var manifestId)) continue;
            var key = await apps.GetDepotDecryptionKey(id, game.AppId).ToTask().WaitAsync(TimeSpan.FromSeconds(30), ct);
            if (key.Result != EResult.OK)
            {
                if (section["dlcappid"].AsUnsignedInteger() != 0 && key.Result == EResult.AccessDenied) continue;
                throw new SteamFailure($"Steam denied depot access ({key.Result}). Check that this account owns the game.");
            }
            var code = await content.GetManifestRequestCode(id, game.AppId, manifestId, "public")
                .WaitAsync(TimeSpan.FromSeconds(30), ct);
            if (code == 0) throw new SteamFailure("Steam did not authorize the download manifest.");
            var manifest = await FromCDN(id, (server, auth) =>
                cdn.DownloadManifestAsync(id, manifestId, code, server, key.DepotKey, cdnAuthToken: auth), ct);
            if (manifest.FilenamesEncrypted || manifest.Files == null || manifest.DepotID != id || manifest.ManifestGID != manifestId)
                throw new SteamFailure("Steam returned an invalid or unreadable manifest.");
            depots.Add(new(id, manifestId, key.DepotKey, manifest));
        }
        if (depots.Count == 0) throw new SteamFailure("No supported Windows 64-bit depots are available for this game.");

        // Validate every path before writing any payload. Reject ambiguous case-only collisions on iOS.
        var files = new Dictionary<string, (Depot Depot, DepotManifest.FileData File)>(StringComparer.OrdinalIgnoreCase);
        foreach (var depot in depots)
        foreach (var file in depot.Manifest.Files!)
        {
            VerifiedFiles.Validate(file);
            _ = VerifiedFiles.SafePath(install, file.FileName);
            if (files.TryGetValue(file.FileName.Replace('\\', '/'), out var previous)
                && (previous.File.FileName != file.FileName || !previous.File.FileHash.AsSpan().SequenceEqual(file.FileHash)))
                throw new SteamFailure("This game's depots contain conflicting files and need a game-specific install profile.");
            files[file.FileName.Replace('\\', '/')] = (depot, file);
        }
        var total = files.Values.Sum(f => checked((long)f.File.TotalSize));
        // Staging and completed files share this volume. Existing verified files need no second copy.
        long required = 256 * 1024 * 1024;
        foreach (var (_, file) in files.Values)
            if (!file.Flags.HasFlag(EDepotFileFlag.Directory) && !await VerifiedFiles.Matches(VerifiedFiles.SafePath(install, file.FileName), file, ct))
                required = checked(required + (long)file.TotalSize);
        if (new DriveInfo(install).AvailableFreeSpace < required)
            throw new SteamFailure($"Not enough free storage. Free at least {required / 1_000_000_000.0:F1} GB and resume.");
        phase("downloading");
        long complete = 0;
        progress(0, total);
        foreach (var (depot, file) in files.Values)
            await VerifiedFiles.Download(install, staging, file,
                (chunk, buffer, token) => FromCDN(depot.Id, (server, auth) =>
                    cdn.DownloadDepotChunkAsync(depot.Id, chunk, server, buffer, depot.Key, cdnAuthToken: auth), token),
                bytes => progress(Interlocked.Add(ref complete, bytes), total), ct);

        // Each file has already passed its whole-file hash before atomic promotion.
        // Avoid a second full-library read, which is costly for large games on flash storage.
        phase("finalizing");
        var executables = files.Values.Select(f => f.File.FileName)
            .Where(f => f.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            .OrderBy(f => f.Count(c => c is '/' or '\\')).ThenBy(f => f, StringComparer.OrdinalIgnoreCase).ToArray();
        if (executables.Length == 0) throw new SteamFailure("Downloaded content has no Windows executable.");
        var installed = new InstalledGame(game.AppId, game.Name, install, executables);
        ct.ThrowIfCancellationRequested();
        var receipt = VerifiedFiles.SafePath(root, $"{game.AppId}/{buildId}/installed.json");
        await File.WriteAllTextAsync(receipt + ".tmp", JsonSerializer.Serialize(installed, SteamJson.Default.InstalledGame), ct);
        File.Move(receipt + ".tmp", receipt, true);
        return installed;
    }
}
