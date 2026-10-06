using System.Text.Json;

namespace Iridium.Steam;

// Called only while the existing Steam worker holds its operation gate. The host
// must keep the runtime idle until completion; a launch never races a save write.
public sealed class CloudSync(string steamRoot, ICloudTransport transport)
{
    string recordPath = "";
    string backupRoot = "";
    CloudRecord record = new();

    public async Task<CloudStatus> Run(uint appId, CloudRequest request, CancellationToken ct)
    {
        if (appId == 0 || !Guid.TryParseExact(request.GameId, "D", out var gameID) ||
            request.Mode is not ("check" or "enable" or "disable" or "sync" or "preflight" or "resolve" or "recover" or "restore"))
            throw new SteamFailure("Invalid Cloud request.");
        if (!ulong.TryParse(transport.Account, out var accountID) || accountID == 0) throw new SteamFailure("Sign in to check Cloud saves.");
        var id = gameID.ToString().ToUpperInvariant();
        var sandbox = Path.GetFullPath(Path.Combine(steamRoot, "../../.."));
        var prefix = CloudPaths.Resolve(sandbox, "Documents/MadeiraTestPrefixes/" + id);
        var scope = CloudPaths.Key(transport.Account) + "/" + appId + "/" + id;
        recordPath = CloudPaths.Resolve(steamRoot, ".cloud/" + scope + "/state.json");
        backupRoot = CloudPaths.Resolve(sandbox, "Documents/Steam Cloud Backups/" + scope);
        record = File.Exists(recordPath) ? JsonSerializer.Deserialize(await CloudPaths.Bytes(recordPath, ct), SteamJson.Default.CloudRecord)
            ?? throw new SteamFailure("The Cloud recovery record is unreadable. Existing saves were kept.")
            : new() { Account = transport.Account, AppId = appId, GameId = id };
        if (record.Version != 1 || record.Account != transport.Account || record.AppId != appId || record.GameId != id || record.Baseline.Count > CloudPaths.MaximumFiles)
            throw new SteamFailure("Cloud record identity mismatch. Existing saves were kept.");
        if (request.Mode == "disable")
        {
            record.Enabled = false;
            await Save(ct);
            return Status("disabled", "Steam Cloud is off for this game and account. Saves and backups are kept.", []);
        }
        var paths = new CloudPaths(prefix, transport.Account, await transport.Configuration(appId, ct));
        if (request.Mode == "enable")
        {
            record.Enabled = true;
            await Save(ct);
        }
        if (request.Mode == "recover")
        {
            if (record.Pending is { } pending) record.Baseline.Remove(pending.Path);
            record.Pending = null; // Explicit acknowledgement, followed by a full comparison.
            await Save(ct);
        }
        if (request.Mode == "restore")
        {
            if (record.Pending != null) throw new SteamFailure("Recheck the interrupted sync before restoring a backup.");
            await Restore(paths, request.BackupId, ct);
        }
        var entries = await Audit(paths, appId, ct);
        if (record.Pending != null) return Status("interrupted", "A save transfer was interrupted. Recheck it before choosing or syncing; backups and both save copies are kept.", entries);
        if (request.Mode is "sync" or "preflight" or "resolve")
        {
            if (!record.Enabled) throw new SteamFailure("Enable Steam Cloud for this game and account before transferring saves.");
            // The runtime copies source files before starting. Receiving saves into
            // an unprepared GameInstall would be overwritten or conflict with that
            // first copy. The host prepares through the existing helper first.
            if (!File.Exists(CloudPaths.Resolve(prefix, "drive_c/IridiumGame/.iridium-source-manifest.json")))
                throw new SteamFailure("Prepare this game's isolated runtime copy before syncing saves.");
            IEnumerable<CloudEntry> wanted = entries.Where(e => e.Action is "upload" or "download");
            // A cancelled Play never sends local saves. Pre-Play synchronization
            // only receives safe one-sided changes; uploads happen after a
            // confirmed exit or an explicit Sync/Keep Device action.
            if (request.Mode == "preflight") wanted = wanted.Where(e => e.Action == "download");
            if (request.Mode == "resolve")
            {
                var choice = request.Choice ?? throw new SteamFailure("Choose the save copy to keep.");
                var entry = entries.SingleOrDefault(e => e.Path == choice.Path) ?? throw new SteamFailure("The save list changed. Compare again before choosing.");
                if (entry.Local?.Sha != choice.LocalSha || entry.Remote?.Sha != choice.RemoteSha)
                    throw new SteamFailure("A save changed after the comparison. Compare again before choosing.");
                if (choice.Side == "local" && entry.Local == null)
                {
                    record.Baseline[entry.Path] = "keep-missing:" + entry.Remote?.Sha;
                    await Save(ct);
                    return Status("choice", "Kept this save missing on the device. No Cloud file was deleted.", await Audit(paths, appId, ct));
                }
                if (choice.Side == "remote" && entry.Remote == null)
                    throw new SteamFailure("There is no Cloud copy to download. The local save was kept.");
                if (choice.Side is not ("local" or "remote")) throw new SteamFailure("Invalid save choice.");
                wanted = [entry with { Action = choice.Side == "local" ? "upload" : "download" }];
            }
            foreach (var entry in wanted)
            {
                ct.ThrowIfCancellationRequested();
                await Transfer(paths, appId, entry, ct);
            }
            entries = await Audit(paths, appId, ct);
        }
        foreach (var entry in entries)
        {
            if (entry.Action == "same" && entry.Local != null) record.Baseline[entry.Path] = entry.Local.Sha;
            // Remember missing local files so their reappearance cannot silently replace Cloud.
            if (entry.Local == null && entry.Remote != null && record.Baseline.TryGetValue(entry.Path, out var prior) && !prior.Contains(':'))
                record.Baseline[entry.Path] = "missing:" + prior;
        }
        await Save(ct);
        var unresolved = entries.Any(e => e.Action != "same" && e.Action != "keptMissing");
        return Status(unresolved ? "choice" : "ready", unresolved
            ? "Save changes need syncing or a choice. No conflicting save was replaced."
            : "Mapped saves match. Unsupported games and paths do not sync.", entries);
    }

    CloudStatus Status(string phase, string message, CloudEntry[] entries) => new(record.GameId, record.AppId, record.Enabled,
        phase, message, entries, Directory.Exists(backupRoot) ? Directory.GetDirectories(backupRoot)
            .Select(Path.GetFileName).OfType<string>().Where(n => Guid.TryParseExact(n, "D", out _)).OrderDescending().Take(100).ToArray() : []);

    async Task<CloudEntry[]> Audit(CloudPaths paths, uint appId, CancellationToken ct)
    {
        var remote = (await transport.List(appId, ct)).Files;
        if (remote.Length > CloudPaths.MaximumFiles) throw new SteamFailure("Steam returned too many Cloud saves.");
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var localPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in remote)
        {
            if (!names.TryAdd(file.Path, file.Path)) throw new SteamFailure("Cloud save paths collide. Saves were kept.");
            if (file.Sha.Length != 40 || !file.Sha.All(Uri.IsHexDigit) || file.Size is < 0 or > CloudPaths.MaximumFileBytes || (file.Platforms & 1) == 0)
                throw new SteamFailure("Steam returned invalid Cloud file metadata.");
        }
        foreach (var name in paths.LocalNames()) names.TryAdd(name, name);
        if (names.Count > CloudPaths.MaximumFiles) throw new SteamFailure("Too many mapped saves.");
        var result = new List<CloudEntry>();
        long total = 0;
        foreach (var name in names.Values.Order(StringComparer.Ordinal))
        {
            var path = paths.Local(name);
            if (!localPaths.Add(path)) throw new SteamFailure("Multiple Cloud saves map to one local file. Saves were kept.");
            var local = await CloudPaths.Read(name, path, ct);
            var cloud = remote.SingleOrDefault(f => f.Path.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (local != null) local = local with { Platforms = cloud?.Platforms ?? paths.Platforms(name) };
            if (local?.Sha == cloud?.Sha && local?.Size != cloud?.Size)
                throw new SteamFailure("Cloud hash and size metadata disagree. Saves were kept.");
            total = checked(total + (local?.Size ?? 0) + (cloud?.Size ?? 0));
            if (total > 1024L * 1024 * 1024) throw new SteamFailure("Mapped saves exceed the 1 GiB comparison limit.");
            record.Baseline.TryGetValue(name, out var baseline);
            result.Add(new(name, CloudPlan.Action(local?.Sha, cloud?.Sha, baseline), local, cloud));
        }
        return result.ToArray();
    }

    async Task Transfer(CloudPaths paths, uint appId, CloudEntry entry, CancellationToken ct)
    {
        var localPath = paths.Local(entry.Path);
        await Unchanged(paths, appId, entry, ct);
        var backupID = Guid.NewGuid().ToString();
        var backup = CloudPaths.Resolve(backupRoot, backupID);
        Directory.CreateDirectory(backup);
        var metadata = new CloudRecord { Account = record.Account, AppId = record.AppId, GameId = record.GameId,
            Pending = new(entry.Path, entry.Action, entry.Local?.Sha, entry.Remote?.Sha ?? entry.Local!.Sha, backupID) };
        await Atomic(CloudPaths.Resolve(backup, "backup.json"), JsonSerializer.SerializeToUtf8Bytes(metadata, SteamJson.Default.CloudRecord), ct);
        // Back up BOTH existing copies before the first save write or upload batch.
        byte[]? local = null, remote = null;
        if (entry.Local != null)
        {
            local = await CloudPaths.Bytes(localPath, ct);
            CloudPaths.Verify(local, entry.Local);
            var localBackup = CloudPaths.Resolve(backup, "device.bin");
            await Atomic(localBackup, local, ct);
            CloudPaths.Verify(await CloudPaths.Bytes(localBackup, ct), entry.Local);
        }
        if (entry.Remote != null)
        {
            remote = await transport.Download(appId, entry.Remote, ct);
            CloudPaths.Verify(remote, entry.Remote);
            var remoteBackup = CloudPaths.Resolve(backup, "cloud.bin");
            await Atomic(remoteBackup, remote, ct);
            CloudPaths.Verify(await CloudPaths.Bytes(remoteBackup, ct), entry.Remote);
        }
        var remoteVersion = await Unchanged(paths, appId, entry, ct);
        record.Pending = new(entry.Path, entry.Action, entry.Local?.Sha,
            (entry.Action == "download" ? entry.Remote : entry.Local)!.Sha, backupID);
        await Save(ct); // Durable journal before the irreversible side effect.
        if (entry.Action == "download")
        {
            await Atomic(localPath, remote!, ct, async () => {
                var current = await CloudPaths.Read(entry.Path, paths.Local(entry.Path), ct);
                if (current?.Sha != entry.Local?.Sha) throw new SteamFailure("A local save changed before replacement. Saves were kept.");
            });
        }
        else
        {
            await transport.Upload(appId, entry.Local!, local!, entry.Remote, remoteVersion, ct);
            var confirmed = (await transport.List(appId, ct)).Files.SingleOrDefault(f => f.Path.Equals(entry.Path, StringComparison.OrdinalIgnoreCase));
            if (confirmed?.Sha != entry.Local!.Sha || confirmed.Size != entry.Local.Size)
                throw new SteamFailure("Steam has not confirmed the uploaded save. Recheck the interrupted sync; backups are kept.");
        }
        // Even confirmed transfers can lose their state write. Keep the journal
        // in that case so the next process asks for recovery instead of guessing.
        record.Baseline[entry.Path] = record.Pending.After;
        record.Pending = null;
        await Save(ct);
    }

    async Task<ulong> Unchanged(CloudPaths paths, uint appId, CloudEntry entry, CancellationToken ct)
    {
        var local = await CloudPaths.Read(entry.Path, paths.Local(entry.Path), ct);
        var listing = await transport.List(appId, ct);
        var remote = listing.Files.SingleOrDefault(f => f.Path.Equals(entry.Path, StringComparison.OrdinalIgnoreCase));
        if (local?.Sha != entry.Local?.Sha || remote?.Sha != entry.Remote?.Sha)
            throw new SteamFailure("A save changed during sync. Compare again before replacing it.");
        return listing.Version;
    }

    async Task Restore(CloudPaths paths, string? backupID, CancellationToken ct)
    {
        if (!Guid.TryParseExact(backupID, "D", out _)) throw new SteamFailure("Choose a valid backup.");
        var backup = CloudPaths.Resolve(backupRoot, backupID!);
        var metadata = JsonSerializer.Deserialize(await CloudPaths.Bytes(CloudPaths.Resolve(backup, "backup.json"), ct), SteamJson.Default.CloudRecord);
        if (metadata?.Account != record.Account || metadata.AppId != record.AppId || metadata.GameId != record.GameId || metadata.Pending is not { } saved || saved.Before == null)
            throw new SteamFailure("This backup has no matching local save to restore.");
        var bytes = await CloudPaths.Bytes(CloudPaths.Resolve(backup, "device.bin"), ct);
        if (CloudPaths.Sha(bytes) != saved.Before) throw new SteamFailure("Backup verification failed. Saves were kept.");
        var localPath = paths.Local(saved.Path);
        var current = await CloudPaths.Read(saved.Path, localPath, ct);
        var undoID = Guid.NewGuid().ToString();
        var undo = CloudPaths.Resolve(backupRoot, undoID);
        Directory.CreateDirectory(undo);
        if (current != null) await Atomic(CloudPaths.Resolve(undo, "device.bin"), await CloudPaths.Bytes(localPath, ct), ct);
        var undoMetadata = new CloudRecord { Account = record.Account, AppId = record.AppId, GameId = record.GameId,
            Pending = new(saved.Path, "restore", current?.Sha, saved.Before, undoID) };
        await Atomic(CloudPaths.Resolve(undo, "backup.json"), JsonSerializer.SerializeToUtf8Bytes(undoMetadata, SteamJson.Default.CloudRecord), ct);
        record.Pending = undoMetadata.Pending;
        await Save(ct);
        await Atomic(localPath, bytes, ct, async () => {
            if ((await CloudPaths.Read(saved.Path, paths.Local(saved.Path), ct))?.Sha != current?.Sha)
                throw new SteamFailure("A local save changed before restore. Saves were kept.");
        });
        record.Baseline.Remove(saved.Path); // Restoring a backup never authorizes uploading it.
        record.Pending = null;
        await Save(ct);
    }

    Task Save(CancellationToken ct) => Atomic(recordPath, JsonSerializer.SerializeToUtf8Bytes(record, SteamJson.Default.CloudRecord), ct);

    static async Task Atomic(string path, byte[] bytes, CancellationToken ct, Func<Task>? beforeReplace = null)
    {
        CloudPaths.Safe(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var staging = path + ".tmp-" + Guid.NewGuid();
        try
        {
            await using (var file = new FileStream(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, true))
            {
                await file.WriteAsync(bytes, ct);
                await file.FlushAsync(ct);
                file.Flush(true);
            }
            ct.ThrowIfCancellationRequested();
            CloudPaths.Safe(path);
            if (beforeReplace != null) await beforeReplace();
            CloudPaths.Safe(path);
            File.Move(staging, path, true); // Atomic same-volume replacement; old saves already backed up.
        }
        finally { if (File.Exists(staging)) File.Delete(staging); }
    }
}
