using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Text.Json;
using SteamKit2;
using SteamKit2.CDN;
using SteamKit2.Internal;

namespace Iridium.Steam;

public sealed class SteamInstaller(SteamConnection connection)
{
    sealed record Depot(uint Id, ulong ManifestId, uint AuthorizationAppId, byte[] Key, DepotManifest Manifest);
    sealed record Candidate(uint Id, uint SourceAppId, uint DlcId, KeyValue Section);

    public static bool SelectWindowsDepot(KeyValue depot) => SteamDepotSelection.IsWindows(depot, new());

    // SteamKit marks HTTPS only when Steam reports "mandatory". Valve's own
    // caches usually report "optional" and still serve TLS on 443.
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

    public static string? ValidateReuseDirectory(string root, uint appId, string? directory)
    {
        if (string.IsNullOrEmpty(directory)) return null;
        var appRoot = VerifiedFiles.SafePath(root, appId.ToString(CultureInfo.InvariantCulture));
        var full = Path.GetFullPath(directory);
        if (!full.StartsWith(appRoot + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || Path.GetFileName(full) != "content")
            throw new SteamFailure("Only an existing download of this game can be used for repair or update.");
        var relative = Path.GetRelativePath(root, full);
        return VerifiedFiles.SafePath(root, relative);
    }

    public async Task<InstalledGame> Install(Game game, string root, Action<long, long> progress,
        Action<string> phase, CancellationToken ct, InstallOptions? requestedOptions = null,
        string? reuseDirectory = null, Action<long>? networkProgress = null, string? operationId = null,
        Func<string, SteamCapacity>? measureCapacity = null, bool overrideStoragePreflight = false,
        Action<SteamStorageDiagnostic>? storageReport = null)
    {
        var options = (requestedOptions ?? new()).Validate();
        reuseDirectory = ValidateReuseDirectory(root, game.AppId, reuseDirectory);
        var cache = new Dictionary<uint, KeyValue>();
        async Task<KeyValue> Info(uint id)
        {
            if (cache.TryGetValue(id, out var stored)) return stored;
            var value = await connection.AppInfo(id, ct);
            cache[id] = value;
            return value;
        }
        var info = await Info(game.AppId);
        var buildId = SteamDepotSelection.Build(info, options.Branch);
        var layout = SteamInstallLayout.Resolve(root, game.AppId, buildId, options, operationId, reuseDirectory);
        var relativeRoot = layout.RelativeRoot;
        var install = layout.Content;
        var staging = layout.Partial;
        reuseDirectory = layout.ReuseDirectory;
        Directory.CreateDirectory(install);
        var content = connection.Client.GetHandler<SteamContent>()!;
        var apps = connection.Client.GetHandler<SteamApps>()!;
        using var cdn = new Client(connection.Client);
        var directory = connection.Client.GetHandler<SteamUnifiedMessages>()!.CreateService<ContentServerDirectory>();
        async Task<CContentServerDirectory_ServerInfo[]> ResolveServers(uint cellId, uint maxServers)
        {
            var response = await directory.GetServersForSteamPipe(new() { cell_id = cellId, max_servers = maxServers })
                .ToTask().WaitAsync(TimeSpan.FromSeconds(30), ct);
            if (response.Result != EResult.OK) throw new SteamFailure($"Steam did not provide a download server list ({response.Result}). Try again shortly.");
            return response.Body.servers.ToArray();
        }
        var serverDirectory = await ResolveServers(connection.Client.CellID ?? 0, 30);
        if (SelectContentServers(serverDirectory, game.AppId).Length == 0)
            serverDirectory = await ResolveServers(0, 50);
        var authTokens = new ConcurrentDictionary<string, string>();

        async Task<T> FromCDN<T>(uint depotId, uint appId, Func<Server, string?, Task<T>> operation, CancellationToken token)
        {
            var servers = SelectContentServers(serverDirectory, appId);
            if (servers.Length == 0) throw new SteamFailure("Steam has no secure download servers available. Try again shortly.");
            // Retry even if Steam returns only one server. Rotation and backoff
            // are bounded; cancellation never starts another attempt.
            for (var attempt = 0; attempt < 6; attempt++)
            {
                token.ThrowIfCancellationRequested();
                if (attempt > 0) await Task.Delay(TimeSpan.FromMilliseconds(Math.Min(4000, 300 << (attempt - 1))), token);
                var server = servers[attempt % servers.Length];
                var tokenKey = $"{appId}:{depotId}:{server.Host}";
                try
                {
                    authTokens.TryGetValue(tokenKey, out var auth);
                    try { return await operation(server, auth); }
                    catch (SteamKitWebRequestException e) when (e.StatusCode == HttpStatusCode.Forbidden)
                    {
                        var granted = await content.GetCDNAuthToken(appId, depotId, server.Host!)
                            .WaitAsync(TimeSpan.FromSeconds(30), token);
                        if (granted.Result != EResult.OK) throw new SteamFailure("Steam denied access to this game's content.");
                        authTokens[tokenKey] = granted.Token;
                        return await operation(server, granted.Token);
                    }
                }
                catch (Exception e) when (!token.IsCancellationRequested
                    && e is HttpRequestException or IOException or TaskCanceledException or SteamKitWebRequestException)
                {
                    if (attempt == 5) break;
                }
            }
            token.ThrowIfCancellationRequested();
            throw new SteamFailure("Steam download servers are unavailable. Your partial download is safe to resume.");
        }

        var candidates = new List<Candidate>();
        void AddCandidates(uint owner, uint dlcId, KeyValue app)
        {
            foreach (var section in app["depots"].Children)
            {
                var declaredDlc = section["dlcappid"].AsUnsignedInteger();
                var effectiveDlc = declaredDlc != 0 ? declaredDlc : dlcId;
                if (uint.TryParse(section.Name, out var id) && id != 0
                    && SteamDepotSelection.IsWindows(section, options) && options.IncludesDlc(effectiveDlc))
                    candidates.Add(new(id, owner, effectiveDlc, section));
            }
        }
        AddCandidates(game.AppId, 0, info);
        // Some DLC publishes its files in its own app rather than in the base
        // game's depot list. These requests still need Steam's authorization.
        var declaredDlcIds = SteamDepotSelection.DlcIds(info);
        if (options.DlcAppIds.Any(id => !declaredDlcIds.Contains(id)))
            throw new SteamFailure("A selected DLC is not declared by this game. Refresh its download options.");
        if (options.IncludeDlc)
        {
            if (declaredDlcIds.Count(options.IncludesDlc) > 500) throw new SteamFailure("This game's DLC catalog is too large. Select specific DLC to continue.");
            foreach (var id in declaredDlcIds.Where(options.IncludesDlc))
            {
                ct.ThrowIfCancellationRequested();
                try { AddCandidates(id, id, await Info(id)); }
                catch (SteamFailure) when (!options.DlcAppIds.Contains(id)) { /* Optional inaccessible DLC metadata. */ }
            }
        }

        var depots = new List<Depot>();
        foreach (var candidate in candidates.DistinctBy(c => c.Id))
        {
            ct.ThrowIfCancellationRequested();
            var section = candidate.Section;
            var sourceApp = candidate.SourceAppId;
            var visited = new HashSet<uint> { sourceApp };
            var manifestInfo = SteamDepotSelection.Manifest(section, options.Branch);
            while (manifestInfo == null && section["depotfromapp"].AsUnsignedInteger() is var sharedApp && sharedApp != 0)
            {
                if (visited.Count >= 8 || !visited.Add(sharedApp))
                    throw new SteamFailure("Steam returned a cyclic shared-depot reference.");
                sourceApp = sharedApp;
                section = (await Info(sharedApp))["depots"][candidate.Id.ToString(CultureInfo.InvariantCulture)];
                manifestInfo = SteamDepotSelection.Manifest(section, options.Branch);
            }
            if (manifestInfo == null) continue; // Metadata-only depot or entitlement-only DLC.
            var (manifestBranch, manifestId) = manifestInfo.Value;
            byte[]? depotKey = null;
            uint authorizationApp = 0;
            ulong code = 0;
            foreach (var appId in SteamDepotSelection.AuthorizationApps(game.AppId, sourceApp, candidate.DlcId))
            {
                var key = await apps.GetDepotDecryptionKey(candidate.Id, appId).ToTask().WaitAsync(TimeSpan.FromSeconds(30), ct);
                if (key.Result == EResult.AccessDenied) continue;
                if (key.Result != EResult.OK) throw new SteamFailure($"Steam could not authorize a content depot ({key.Result}). Retry shortly.");
                code = await content.GetManifestRequestCode(candidate.Id, appId, manifestId, manifestBranch)
                    .WaitAsync(TimeSpan.FromSeconds(30), ct);
                if (code == 0) continue;
                authorizationApp = appId;
                depotKey = key.DepotKey;
                break;
            }
            if (depotKey == null)
            {
                if (candidate.DlcId != 0 && !options.DlcAppIds.Contains(candidate.DlcId)) continue;
                throw new SteamFailure("Steam denied depot access. Check ownership of the game and any selected DLC.");
            }
            var manifest = await FromCDN(candidate.Id, authorizationApp, (server, auth) =>
                cdn.DownloadManifestAsync(candidate.Id, manifestId, code, server, depotKey, cdnAuthToken: auth), ct);
            if (manifest.FilenamesEncrypted || manifest.Files == null || manifest.DepotID != candidate.Id || manifest.ManifestGID != manifestId)
                throw new SteamFailure("Steam returned an invalid or unreadable manifest.");
            depots.Add(new(candidate.Id, manifestId, authorizationApp, depotKey, manifest));
        }
        if (depots.Count == 0) throw new SteamFailure("No authorized Windows depots match these download options.");

        // Steam applies later depots over earlier ones. Exact-path overrides are
        // valid; ambiguous case-only names and file/directory collisions are not.
        var files = new Dictionary<string, (Depot Depot, DepotManifest.FileData File)>(StringComparer.OrdinalIgnoreCase);
        foreach (var depot in depots)
        foreach (var file in depot.Manifest.Files!)
        {
            VerifiedFiles.Validate(file);
            _ = VerifiedFiles.SafePath(install, file.FileName);
            var name = file.FileName.Replace('\\', '/');
            if (files.TryGetValue(name, out var previous)
                && (previous.File.FileName.Replace('\\', '/') != name
                    || previous.File.Flags.HasFlag(EDepotFileFlag.Directory) != file.Flags.HasFlag(EDepotFileFlag.Directory)))
                throw new SteamFailure("This game's depots contain ambiguous file names that cannot be installed safely on iOS.");
            files[name] = (depot, file);
        }
        foreach (var name in files.Keys)
        {
            var slash = name.LastIndexOf('/');
            while (slash >= 0)
            {
                if (files.TryGetValue(name[..slash], out var parent) && !parent.File.Flags.HasFlag(EDepotFileFlag.Directory))
                    throw new SteamFailure("Steam returned a file where an installation directory is required.");
                slash = name.LastIndexOf('/', slash - 1);
            }
        }
        var total = files.Values.Sum(f => checked((long)f.File.TotalSize));
        phase("verifying");
        progress(0, total);
        await SteamStorage.Check(install, staging, files.Values.Select(value => value.File),
            measureCapacity ?? SteamCapacity.FromDrive, overrideStoragePreflight, storageReport, ct);
        long complete = 0;
        foreach (var (depot, file) in files.Values)
        {
            phase("verifying");
            await VerifiedFiles.Download(install, staging, file,
                (chunk, buffer, token) =>
                {
                    phase("downloading");
                    return FromCDN(depot.Id, depot.AuthorizationAppId, (server, auth) =>
                        cdn.DownloadDepotChunkAsync(depot.Id, chunk, server, buffer, depot.Key, cdnAuthToken: auth), token);
                }, bytes => progress(Interlocked.Add(ref complete, bytes), total), ct,
                reuseDirectory == null ? null : VerifiedFiles.SafePath(reuseDirectory, file.FileName), options.MaxDownloads, networkProgress);
        }

        phase("finalizing");
        var executables = files.Values.Where(f => !f.File.Flags.HasFlag(EDepotFileFlag.Directory)).Select(f => f.File.FileName)
            .Where(f => f.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            .OrderBy(f => f.Count(c => c is '/' or '\\')).ThenBy(f => f, StringComparer.OrdinalIgnoreCase).ToArray();
        if (executables.Length == 0) throw new SteamFailure("Downloaded content has no Windows executable.");
        var installed = new InstalledGame(game.AppId, game.Name, install, executables)
        {
            BuildId = buildId, Options = options, OperationId = operationId,
            Depots = depots.Select(d => new InstalledDepot(d.Id, d.ManifestId.ToString(CultureInfo.InvariantCulture), d.AuthorizationAppId)).ToArray()
        };
        ct.ThrowIfCancellationRequested();
        var receipt = VerifiedFiles.SafePath(root, relativeRoot + "/installed.json");
        var temporaryReceipt = VerifiedFiles.SafePath(root, relativeRoot + "/installed.json.tmp");
        await File.WriteAllTextAsync(temporaryReceipt, JsonSerializer.Serialize(installed, SteamJson.Default.InstalledGame), ct);
        ct.ThrowIfCancellationRequested();
        File.Move(temporaryReceipt, receipt, true);
        return installed;
    }
}
