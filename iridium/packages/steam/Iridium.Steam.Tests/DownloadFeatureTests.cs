using System.Security.Cryptography;
using System.Text.Json;
using Iridium.Steam;
using SteamKit2;

internal static class DownloadFeatureTests
{
    public static async Task<int> Run()
    {
        var count = 0;
        void Check(bool condition, string name) { if (!condition) throw new Exception(name); count++; }
        void Reject(Action action, string name)
        {
            try { action(); } catch (SteamFailure) { count++; return; }
            throw new Exception("Accepted " + name);
        }
        var options = new InstallOptions();
        Check(options.StorageSuffix() == "", "legacy default installation path preserved");
        Check((options with { MaxDownloads = 8 }).StorageSuffix() == "", "connection count does not split resume identity");
        Check((options with { Language = "german" }).StorageSuffix() != "", "language variants are isolated");
        Check((options with { Branch = "beta" }).StorageSuffix() != (options with { Architecture = "32" }).StorageSuffix(), "branch and architecture variants differ");
        Check((options with { DlcAppIds = [3, 2, 3] }).StorageSuffix() == (options with { DlcAppIds = [2, 3] }).StorageSuffix(), "DLC ordering does not split resume identity");
        Reject(() => (options with { Branch = "../escape" }).Validate(), "branch path injection");
        Reject(() => (options with { Language = "a/b" }).Validate(), "language path injection");
        Reject(() => (options with { Architecture = "arm64" }).Validate(), "unsupported guest architecture");
        Reject(() => (options with { MaxDownloads = 99 }).Validate(), "unbounded download concurrency");
        Reject(() => (options with { DlcAppIds = [0] }).Validate(), "invalid DLC identity");
        Check(!(options with { IncludeDlc = false }).IncludesDlc(3), "DLC exclusion");
        Check((options with { IncludeDlc = false }).IncludesDlc(0), "base content retained without DLC");
        Check(!(options with { DlcAppIds = [2] }).IncludesDlc(3), "explicit DLC selection");
        var info = KeyValue.LoadFromString("\"appinfo\" { \"extended\" { \"listofdlc\" \"3,2,3,bad\" } \"depots\" { \"branches\" { \"public\" { \"buildid\" \"99\" } \"beta\" { \"buildid\" \"100\" } \"locked\" { \"buildid\" \"101\" \"pwdrequired\" \"1\" } } \"10\" { \"dlcappid\" \"4\" \"config\" { \"oslist\" \"windows\" \"osarch\" \"32\" \"language\" \"german\" } \"manifests\" { \"public\" { \"gid\" \"18446744073709551615\" } } } } }")!;
        Check(SteamDepotSelection.Build(info, "beta") == "100", "selected branch build ID");
        Reject(() => SteamDepotSelection.Build(info, "locked"), "password-protected branch");
        Reject(() => SteamDepotSelection.Build(info, "missing"), "missing branch does not silently use public");
        Check(SteamDepotSelection.Manifest(info["depots"]["10"], "beta") == ("public", ulong.MaxValue), "unchanged beta depot uses public manifest without ID precision loss");
        Check(SteamDepotSelection.DlcIds(info).SequenceEqual(new uint[] { 2, 3, 4 }), "separate and inline DLC declarations");
        Check(SteamDepotSelection.IsWindows(info["depots"]["10"], options with { Architecture = "32", Language = "german" }), "32-bit language selection");
        Check(!SteamDepotSelection.IsWindows(info["depots"]["10"], options), "wrong architecture excluded");
        Check(SteamDepotSelection.AuthorizationApps(1, 2, 3).SequenceEqual(new uint[] { 3, 2, 1 }), "DLC and shared owner authorization precedes base game");
        Check(SteamDepotSelection.AuthorizationApps(1, 1, 0).SequenceEqual(new uint[] { 1 }), "duplicate authorization requests removed");

        var root = Path.Combine(Path.GetTempPath(), "iridium-download-features-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var operation = Guid.NewGuid().ToString();
            var original = SteamInstallLayout.Resolve(root, 42, "99", options, operation, null);
            Check(original.RelativeRoot == "42/99", "legacy partial folder remains resumable");
            Directory.CreateDirectory(original.Content);
            File.WriteAllText(Path.Combine(root, "42/99/installed.json"), "{}");
            var repair = SteamInstallLayout.Resolve(root, 42, "99", options, operation, original.Content);
            Check(!repair.Content.StartsWith(Path.GetDirectoryName(original.Content)! + Path.DirectorySeparatorChar, StringComparison.Ordinal), "repair is outside original deletion boundary");
            var legacyOperation = Guid.NewGuid();
            var legacyRoot = Path.Combine(root, "42/99/checks", legacyOperation.ToString("N"));
            Directory.CreateDirectory(Path.Combine(legacyRoot, "partial"));
            Check(SteamInstallLayout.Resolve(root, 42, "99", options, legacyOperation.ToString(), original.Content).Partial == Path.Combine(legacyRoot, "partial"), "existing legacy repair partial remains resumable");
            Check(repair.Content != original.Content && repair.ReuseDirectory == original.Content, "repair preserves the committed source folder");
            Check(repair == SteamInstallLayout.Resolve(root, 42, "99", options, operation, original.Content), "same queued repair resumes same partial folder");
            Check(repair.Content != SteamInstallLayout.Resolve(root, 42, "99", options, Guid.NewGuid().ToString(), original.Content).Content, "different repair does not overwrite another installation");
            Check(SteamInstallLayout.Resolve(root, 42, "99", options, operation, null).Content != original.Content, "ordinary redownload cannot overwrite an installed game");
            Reject(() => SteamInstallLayout.Resolve(root, 42, "99", options, "../../bad", original.Content), "invalid repair operation identity");
            Reject(() => SteamInstaller.ValidateReuseDirectory(root, 99, original.Content), "another game's reuse directory");
            Reject(() => SteamInstaller.ValidateReuseDirectory(root, 42, root), "outside-app reuse directory");
            var link = Path.Combine(root, "42", "linked");
            Directory.CreateSymbolicLink(link, Path.GetTempPath());
            Reject(() => SteamInstaller.ValidateReuseDirectory(root, 42, Path.Combine(link, "content")), "symlinked update source");
            Directory.Delete(link);

            byte[] bytes = "abcdefghABCDEFGH"u8.ToArray();
            var file = new DepotManifest.FileData { FileName = "game.exe", FileHash = SHA1.HashData(bytes), TotalSize = (ulong)bytes.Length };
            file.Chunks.Add(new(SHA1.HashData(bytes[..8]), 0, 0, 6, 8));
            file.Chunks.Add(new(SHA1.HashData(bytes[8..]), 0, 8, 7, 8));
            var calls = 0;
            Task<int> Fetch(DepotManifest.ChunkData chunk, byte[] buffer, CancellationToken token)
            {
                token.ThrowIfCancellationRequested();
                Interlocked.Increment(ref calls);
                bytes.AsSpan((int)chunk.Offset, (int)chunk.UncompressedLength).CopyTo(buffer);
                return Task.FromResult((int)chunk.UncompressedLength);
            }
            var sourceFile = Path.Combine(original.Content, file.FileName);
            File.WriteAllBytes(sourceFile, bytes);
            File.WriteAllText(Path.Combine(original.Content, "save.dat"), "user progress");
            long network = 0, verified = 0;
            await VerifiedFiles.Download(repair.Content, repair.Partial, file, Fetch, n => Interlocked.Add(ref verified, n), default,
                sourceFile, 2, n => Interlocked.Add(ref network, n));
            Check(calls == 0 && network == 0 && verified == bytes.Length, "verified chunk reuse is not counted as network transfer");
            Check(File.ReadAllText(Path.Combine(original.Content, "save.dat")) == "user progress", "repair never removes saves");
            Check(File.ReadAllBytes(sourceFile).SequenceEqual(bytes), "repair source remains unchanged");
            File.WriteAllText(Path.Combine(repair.Content, file.FileName), "modified copy");
            Check(File.ReadAllBytes(sourceFile).SequenceEqual(bytes), "repair output is not hard-linked to source");

            Directory.Delete(Path.GetDirectoryName(original.Content)!, recursive: true);
            Check(File.ReadAllText(Path.Combine(repair.Content, file.FileName)) == "modified copy", "original removal preserves completed repair");

            var partialRoot = Path.Combine(root, "partial-test");
            var newRoot = Path.Combine(root, "new-test");
            Directory.CreateDirectory(partialRoot);
            var partial = VerifiedFiles.PartialPath(partialRoot, file);
            File.WriteAllBytes(partial, new byte[bytes.Length]);
            Check(await VerifiedFiles.RequiredStorage(newRoot, partialRoot, file, default) == bytes.Length, "preallocated zero partial cannot bypass storage check");
            await using (var stream = new FileStream(partial, FileMode.Open)) { await stream.WriteAsync(bytes.AsMemory(0, 8)); }
            Check(await VerifiedFiles.RequiredStorage(newRoot, partialRoot, file, default) == 8, "only hash-verified partial chunks reduce storage reservation");
            calls = 0; network = 0;
            await VerifiedFiles.Download(newRoot, partialRoot, file, Fetch, _ => { }, default, maxDownloads: 1,
                networkProgress: n => network += n);
            Check(calls == 1 && network == 7, "resume downloads only the missing compressed chunk");
            Check(await VerifiedFiles.RequiredStorage(newRoot, partialRoot, file, default) == 0, "verified completed file needs no second copy");

            var cancelRoot = Path.Combine(root, "cancel-test");
            var cancelStage = Path.Combine(root, "cancel-partial");
            using var cancelled = new CancellationTokenSource();
            try
            {
                await VerifiedFiles.Download(cancelRoot, cancelStage, file, Fetch, _ => cancelled.Cancel(), cancelled.Token,
                    maxDownloads: 1);
                throw new Exception("Cancellation ignored");
            }
            catch (OperationCanceledException) { count++; }
            Check(!File.Exists(Path.Combine(cancelRoot, "game.exe")), "cancelled installation is not promoted");
            calls = 0;
            await VerifiedFiles.Download(cancelRoot, cancelStage, file, Fetch, _ => { }, default, maxDownloads: 1);
            Check(calls == 1, "cancelled verified chunk remains resumable");

            var receipt = new InstalledGame(42, "Fixture", repair.Content, ["game.exe"])
            { BuildId = "99", OperationId = operation, Options = options, Depots = [new(10, ulong.MaxValue.ToString(), 3)] };
            var snapshot = new Snapshot { OperationId = operation, NetworkBytes = 13, Installed = receipt, Details = SteamDepotSelection.Details(42, info) };
            var serialized = JsonSerializer.Serialize(snapshot, SteamJson.Default.Snapshot);
            var decoded = JsonSerializer.Deserialize(serialized, SteamJson.Default.Snapshot)!;
            Check(decoded.Installed!.Depots[0].ManifestId == "18446744073709551615", "AOT receipt preserves unsigned Steam IDs as strings");
            Check(decoded.OperationId == operation && decoded.Installed.OperationId == operation, "request correlation survives native JSON");
            Check(decoded.Details!.Branches.Length == 3 && decoded.NetworkBytes == 13, "metadata and transfer counters survive native JSON");
            var command = JsonSerializer.Deserialize("{\"action\":\"install\",\"appId\":42,\"operationId\":\"" + operation + "\",\"options\":{\"branch\":\"beta\",\"language\":\"german\",\"architecture\":\"32\",\"includeDlc\":true,\"dlcAppIds\":[2],\"maxDownloads\":8}}", SteamJson.Default.Command)!;
            Check(command.Options.Validate().DlcAppIds.SequenceEqual(new uint[] { 2 }) && command.Options.MaxDownloads == 8, "AOT install options deserialize through actual command contract");
        }
        finally { Directory.Delete(root, recursive: true); }
        return count;
    }
}
