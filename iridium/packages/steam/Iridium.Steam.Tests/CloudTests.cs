using System.IO.Compression;
using System.Text.Json;
using Iridium.Steam;
using SteamKit2;
using SteamKit2.Internal;

static class CloudTests
{
    public static async Task<int> Run(string root)
    {
        var checks = 0;
        void Check(bool ok, string name) { if (!ok) throw new Exception("Cloud: " + name); checks++; }
        async Task Reject(Func<Task> action, string name)
        {
            try { await action(); } catch (Exception e) when (e is SteamFailure or IOException or OperationCanceledException or InvalidDataException or JsonException) { checks++; return; }
            throw new Exception("Cloud accepted: " + name);
        }
        var game = Guid.NewGuid().ToString().ToUpperInvariant();
        var steam = Path.Combine(root, "sandbox", "Library", "Application Support", "SteamGames");
        var prefix = Path.Combine(root, "sandbox", "Documents", "MadeiraTestPrefixes", game);
        var saves = Path.Combine(prefix, "drive_c", "IridiumGame", "saves");
        Directory.CreateDirectory(steam); Directory.CreateDirectory(saves);
        File.WriteAllText(Path.Combine(prefix, "drive_c", "IridiumGame", ".iridium-source-manifest.json"), "{\"version\":1,\"files\":{}}");
        var fake = new Fixture();
        CloudSync Sync() => new(steam, fake);
        Task<CloudStatus> Run(string mode, CloudChoice? choice = null, string? backup = null) => Sync().Run(42,
            new() { GameId = game, Mode = mode, Choice = choice, BackupId = backup }, default);
        var path = "%GameInstall%saves/one.sav";
        await File.WriteAllTextAsync(Path.Combine(saves, "one.sav"), "device");
        fake.Put(path, "cloud");
        var status = await Run("check");
        Check(!status.Enabled && status.Entries.Single().Action == "conflict" && fake.Uploads == 0, "comparison is opt-in and non-mutating");
        await Reject(async () => _ = await Run("sync"), "no upload without consent");
        status = await Run("enable");
        Check(status.Enabled && fake.Uploads == 0, "enable records consent without transfer");
        var first = status.Entries.Single();
        fake.Put(path, "changed remotely");
        await Reject(async () => _ = await Run("resolve", new(path, "local", first.Local?.Sha, first.Remote?.Sha)), "stale conflict choice");
        status = await Run("check");
        first = status.Entries.Single();
        fake.FailDownload = true;
        await Reject(async () => _ = await Run("resolve", new(path, "local", first.Local?.Sha, first.Remote?.Sha)), "backup failure blocks upload");
        Check(fake.Uploads == 0, "no batch before remote backup");
        fake.FailDownload = false;
        status = await Run("resolve", new(path, "remote", first.Local?.Sha, first.Remote?.Sha));
        Check(status.Phase == "ready" && await File.ReadAllTextAsync(Path.Combine(saves, "one.sav")) == "changed remotely", "verified atomic download");
        var successfulBackup = status.Backups.First(b => File.Exists(Backup(steam, fake.Account, game, b, "device.bin")));
        Check(await File.ReadAllTextAsync(Backup(steam, fake.Account, game, successfulBackup, "device.bin")) == "device", "replaced local backup retained");
        await File.WriteAllTextAsync(Path.Combine(saves, "one.sav"), "new local");
        var uploadsBeforePlay = fake.Uploads;
        status = await Run("preflight");
        Check(fake.Uploads == uploadsBeforePlay && status.Phase == "choice", "pre-Play never uploads even a one-sided local change");
        status = await Run("sync");
        Check(fake.Uploads == 1 && status.Phase == "ready", "one-sided change uploads after consent");
        Check(status.Backups.Any(b => File.Exists(Backup(steam, fake.Account, game, b, "cloud.bin")) &&
            File.ReadAllText(Backup(steam, fake.Account, game, b, "cloud.bin")) == "changed remotely"), "replaced Cloud backup retained");
        File.Delete(Path.Combine(saves, "one.sav"));
        status = await Run("check");
        Check(status.Entries.Single().Action == "conflict", "reset prefix needs choice");
        await File.WriteAllTextAsync(Path.Combine(saves, "one.sav"), "fresh save after reset");
        status = await Run("sync");
        Check(fake.Uploads == 1 && status.Entries.Single().Action == "conflict", "reappearing missing save cannot auto-overwrite Cloud");
        File.Delete(Path.Combine(saves, "one.sav"));
        status = await Run("check");
        first = status.Entries.Single();
        status = await Run("resolve", new(path, "local", null, first.Remote?.Sha));
        Check(status.Entries.Single().Action == "keptMissing" && fake.Uploads == 1, "keep missing does not delete Cloud");
        fake.Put(path, "remote after reset");
        status = await Run("check"); first = status.Entries.Single();
        Check(first.Action == "conflict", "remote change after keep-missing requires new choice");
        status = await Run("resolve", new(path, "remote", null, first.Remote?.Sha));
        fake.Files.Remove(path);
        status = await Run("sync");
        Check(fake.Uploads == 1 && status.Entries.Single().Action == "conflict", "remote deletion cannot silently resurrect");
        fake.Put(path, "remote after reset");
        await File.WriteAllTextAsync(Path.Combine(saves, "one.sav"), "interrupted upload");
        fake.FailUploadAfterCommit = true;
        await Reject(async () => _ = await Run("sync"), "lost batch acknowledgement");
        status = await Run("check");
        Check(status.Phase == "interrupted" && File.ReadAllText(Path.Combine(saves, "one.sav")) == "interrupted upload", "journal survives interrupted upload and new sync object");
        fake.FailUploadAfterCommit = false;
        var count = fake.Uploads;
        status = await Run("recover");
        Check(status.Phase == "ready" && fake.Uploads == count, "recovery reconciles confirmed bytes without re-upload");
        await File.WriteAllTextAsync(Path.Combine(saves, "one.sav"), "local before race");
        fake.BeforeUpload = () => fake.Put(path, "racing remote writer");
        count = fake.Uploads;
        await Reject(async () => _ = await Run("sync"), "remote change after backup before upload");
        Check(fake.Uploads == count && System.Text.Encoding.UTF8.GetString(fake.Files[path]) == "racing remote writer", "version guard keeps concurrent remote save");
        fake.BeforeUpload = null;
        status = await Run("recover");
        Check(status.Phase == "choice", "remote race recovery does not adopt an unverified baseline");
        status = await Run("restore", backup: successfulBackup);
        Check(File.ReadAllText(Path.Combine(saves, "one.sav")) == "device" && status.Phase == "choice" && fake.Uploads == count, "rollback keeps undo copy and does not upload restored save");
        fake.Account = "76561198000000002";
        status = await Run("check");
        Check(!status.Enabled && status.Backups.Length == 0, "account switch isolates consent/baseline/backups");
        await Reject(async () => _ = await Run("restore", backup: successfulBackup), "cross-account backup restore");
        fake.Account = "76561198000000001";
        await Run("disable");
        await Reject(async () => _ = await Run("sync"), "disable prevents later uploads");
        var before = File.ReadAllText(Path.Combine(saves, "one.sav"));
        fake.Files.Clear();
        fake.Put("%GameInstall%../escape", "bad");
        await Reject(async () => _ = await Run("check"), "remote traversal");
        Check(File.ReadAllText(Path.Combine(saves, "one.sav")) == before, "invalid map leaves saves intact");
        fake.Files.Clear(); fake.Put(path, "remote");
        fake.Put("%GameInstall%saves/ONE.sav", "duplicate");
        await Reject(async () => _ = await Run("check"), "case-only Cloud collision");
        fake.Files.Clear(); fake.Put(path, "remote");
        var outside = Path.Combine(root, "outside"); Directory.CreateDirectory(outside);
        Directory.CreateSymbolicLink(Path.Combine(saves, "linked"), outside);
        await Reject(async () => _ = await Run("check"), "directory symlink escape");
        Directory.Delete(Path.Combine(saves, "linked"));
        var ancestorLink = Path.Combine(root, "linked-sandbox");
        Directory.CreateSymbolicLink(ancestorLink, Path.Combine(root, "sandbox"));
        await Reject(() =>
        {
            CloudPaths.Safe(Path.Combine(ancestorLink, "Documents", "MadeiraTestPrefixes", game));
            return Task.CompletedTask;
        }, "symlink above the requested save root");
        Directory.Delete(ancestorLink);
        if (OperatingSystem.IsLinux())
        {
            var fifo = Path.Combine(saves, "special.sav");
            Check(MakeFifo(fifo, 384) == 0, "synthetic FIFO created");
            await Reject(async () => _ = await CloudPaths.Bytes(fifo, default), "FIFO save rejected without blocking read-only open");
            File.Delete(fifo);
        }
        // Model a regular file growing after FileInfo's pre-open stat. Exercise
        // the actual opened-stream reader and prove rejection precedes any read.
        using (var grown = new GrownSave(CloudPaths.MaximumFileBytes + 1L))
        {
            try { _ = await CloudPaths.ReadOpenedSave(grown, default); throw new Exception("Growing save accepted"); }
            catch (SteamFailure) { Check(grown.Reads == 0, "opened oversized save rejected before allocation/read"); }
        }
        using (var invalid = new GrownSave(long.MaxValue))
            await Reject(async () => _ = await CloudPaths.ReadOpenedSave(invalid, default), "opened length overflow rejected");
        var map = new CloudPaths(prefix, fake.Account, fake.Config);
        foreach (var name in new[] { "%GameInstall%/absolute", "%GameInstall%saves/../../escape", "%GameInstall%saves/a:ads", "saves/one.sav", "%Unknown%saves/a", "%GameInstall%saves//one.sav" })
            await Reject(() => { _ = map.Local(name); return Task.CompletedTask; }, "unsafe path " + name);
        var bad = Fixture.Configured();
        var overrides = new KeyValue("rootoverrides"); var item = new KeyValue("0"); item.Children.Add(new("os", "Windows")); overrides.Children.Add(item); bad["ufs"].Children.Add(overrides);
        await Reject(() => { _ = new CloudPaths(prefix, fake.Account, bad); return Task.CompletedTask; }, "unverified root override");
        var idConfig = Fixture.Configured("saves/{64BitSteamID}/{Steam3AccountID}");
        var idFolder = Path.Combine(saves, fake.Account, ((uint)ulong.Parse(fake.Account)).ToString()); Directory.CreateDirectory(idFolder);
        File.WriteAllText(Path.Combine(idFolder, "id.sav"), "ids");
        var idNames = new CloudPaths(prefix, fake.Account, idConfig).LocalNames().ToArray();
        Check(idNames.Single().Contains(fake.Account) && !idNames.Single().Contains('{'), "new upload cloud name expands account IDs");
        var bytes = "compressed fixture"u8.ToArray(); var expected = new CloudFile(path, CloudPaths.Sha(bytes), bytes.Length, 1);
        using var archive = new MemoryStream();
        using (var zip = new ZipArchive(archive, ZipArchiveMode.Create, true))
        { using var output = zip.CreateEntry("../../never-extracted").Open(); output.Write(bytes); }
        Check(SteamCloudTransport.Decode(archive.ToArray(), expected).SequenceEqual(bytes), "bounded compressed bytes, never extract member names");
        await Reject(() => { _ = SteamCloudTransport.Decode(archive.ToArray(), expected with { Sha = new string('0', 40) }); return Task.CompletedTask; }, "compressed save hash mismatch");
        foreach (var (host, url, https) in new[] { ("127.0.0.1", "/save", true), ("evil.example", "/save", true), ("store.steampowered.com", "//evil", true), ("store.steampowered.com", "/save", false), ("store.steampowered.com:443", "/save", true) })
            await Reject(() => { _ = SteamCloudTransport.Address(host, url, https); return Task.CompletedTask; }, "unsafe HTTP endpoint");
        Check(SteamCloudTransport.Address("cloud.steamcontent.com", "/fixture?signature=synthetic", true).Scheme == "https", "service Cloud host TLS");
        await Reject(() => { _ = SteamCloudTransport.BlockBody(new() { http_method = 4, block_offset = ulong.MaxValue, block_length = 1 }, bytes); return Task.CompletedTask; }, "upload block overflow");
        Check(SteamCloudTransport.BlockBody(new() { http_method = 4, block_offset = 0, block_length = (uint)bytes.Length }, bytes).SequenceEqual(bytes), "bounded upload block bytes");
        Check(CloudPlan.Action("local", "remote", null) == "conflict" && CloudPlan.Action(null, "remote", null) == "conflict", "first differing or missing copy always requires choice");
        var otherApp = await Sync().Run(99, new() { GameId = game, Mode = "check" }, default);
        Check(!otherApp.Enabled && otherApp.Backups.Length == 0, "app isolation");
        var unpreparedGame = Guid.NewGuid().ToString().ToUpperInvariant();
        var unpreparedPrefix = Path.Combine(root, "sandbox", "Documents", "MadeiraTestPrefixes", unpreparedGame, "drive_c", "IridiumGame", "saves");
        Directory.CreateDirectory(unpreparedPrefix); File.WriteAllText(Path.Combine(unpreparedPrefix, "one.sav"), "unprepared local");
        fake.Config = Fixture.Configured(); fake.Files.Clear(); fake.Put(path, "first Cloud save");
        var unprepared = await Sync().Run(42, new() { GameId = unpreparedGame, Mode = "enable" }, default);
        var pair = unprepared.Entries.Single();
        await Reject(async () => _ = await Sync().Run(42, new() { GameId = unpreparedGame, Mode = "resolve", Choice = new(path, "remote", pair.Local?.Sha, pair.Remote?.Sha) }, default), "first unprepared game copy cannot receive saves");
        Check(File.ReadAllText(Path.Combine(unpreparedPrefix, "one.sav")) == "unprepared local", "unprepared source copy is untouched");
        var cancelled = new CancellationToken(true);
        await Reject(async () => _ = await Sync().Run(42, new() { GameId = game, Mode = "sync" }, cancelled), "cancellation");
        Console.WriteLine($"Steam Cloud: {checks} deterministic checks passed (no login or Cloud traffic).");
        return checks;
    }
    [System.Runtime.InteropServices.DllImport("libc", EntryPoint = "mkfifo", SetLastError = true)]
    static extern int MakeFifo([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPUTF8Str)] string path, uint mode);

    static string Backup(string steam, string account, string game, string id, string name) =>
        Path.GetFullPath(Path.Combine(steam, "../../../Documents/Steam Cloud Backups", CloudPaths.Key(account), "42", game, id, name));

    sealed class GrownSave(long length) : MemoryStream
    {
        public int Reads;
        public override long Length => length;
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        { Reads++; return base.ReadAsync(buffer, ct); }
    }

    sealed class Fixture : ICloudTransport
    {
        public string Account { get; set; } = "76561198000000001";
        public KeyValue Config { get; set; } = Configured();
        public readonly Dictionary<string, byte[]> Files = new(StringComparer.Ordinal);
        public bool FailDownload, FailUploadAfterCommit;
        public int Uploads;
        public ulong Version = 1;
        public Action? BeforeUpload;
        public void Put(string name, string text) { Files[name] = System.Text.Encoding.UTF8.GetBytes(text); Version++; }
        public Task<KeyValue> Configuration(uint appId, CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.FromResult(Config); }
        public Task<CloudListing> List(uint appId, CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.FromResult(new CloudListing(Version, Files.Select(f => new CloudFile(f.Key, CloudPaths.Sha(f.Value), f.Value.Length, 1)).ToArray())); }
        public Task<byte[]> Download(uint appId, CloudFile file, CancellationToken ct)
        { ct.ThrowIfCancellationRequested(); if (FailDownload) throw new IOException("Synthetic network loss"); return Task.FromResult(Files[file.Path]); }
        public Task Upload(uint appId, CloudFile file, byte[] data, CloudFile? expectedRemote, ulong expectedVersion, CancellationToken ct)
        { ct.ThrowIfCancellationRequested(); BeforeUpload?.Invoke(); if (Version != expectedVersion || (Files.TryGetValue(file.Path, out var old) ? CloudPaths.Sha(old) : null) != expectedRemote?.Sha) throw new SteamFailure("Synthetic remote changed"); Uploads++; Files[file.Path] = data; Version++; if (FailUploadAfterCommit) throw new IOException("Synthetic acknowledgement loss"); return Task.CompletedTask; }
        public static KeyValue Configured(string folder = "saves")
        {
            var app = new KeyValue("appinfo"); var ufs = new KeyValue("ufs"); app.Children.Add(ufs);
            var saves = new KeyValue("savefiles"); ufs.Children.Add(saves); var rule = new KeyValue("0"); saves.Children.Add(rule);
            rule.Children.Add(new("root", "GameInstall")); rule.Children.Add(new("path", folder)); rule.Children.Add(new("pattern", "*.sav")); rule.Children.Add(new("recursive", "1"));
            var platforms = new KeyValue("platforms"); platforms.Children.Add(new("0", "Windows")); rule.Children.Add(platforms);
            return app;
        }
    }
}
