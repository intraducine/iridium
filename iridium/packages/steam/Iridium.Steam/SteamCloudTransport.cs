using System.IO.Compression;
using System.Net;
using SteamKit2;
using SteamKit2.Internal;

namespace Iridium.Steam;

public sealed class SteamCloudTransport(SteamConnection connection) : ICloudTransport
{
    readonly Cloud service = connection.Client.GetHandler<SteamUnifiedMessages>()!.CreateService<Cloud>();
    public string Account => connection.Client.SteamID?.ConvertToUInt64().ToString(System.Globalization.CultureInfo.InvariantCulture)
        ?? throw new SteamFailure("Steam disconnected. Sign in to check Cloud saves.");
    public Task<KeyValue> Configuration(uint appId, CancellationToken ct) => connection.AppInfo(appId, ct);

    static async Task<T> Reply<T>(AsyncJob<SteamUnifiedMessages.ServiceMethodResponse<T>> job, CancellationToken ct)
        where T : class, ProtoBuf.IExtensible, new()
    {
        var response = await job.ToTask().WaitAsync(TimeSpan.FromSeconds(45), ct);
        if (response.Result != EResult.OK) throw new SteamFailure("Steam rejected the Cloud request. Retry after checking your connection.");
        return response.Body;
    }
    public async Task<CloudListing> List(uint appId, CancellationToken ct)
    {
        var body = await Reply(service.GetAppFileChangelist(new() { appid = appId, synced_change_number = 0 }), ct);
        if (body.is_only_delta || body.files.Count > CloudPaths.MaximumFiles) throw new SteamFailure("Steam did not return a complete bounded Cloud list.");
        return new(body.current_change_number, body.files.Where(f => (int)f.persist_state == 0).Select(f => {
            if (f.path_prefix_index >= body.path_prefixes.Count || f.sha_file?.Length != 20)
                throw new SteamFailure("Steam returned an invalid Cloud path or hash.");
            return new CloudFile(body.path_prefixes[(int)f.path_prefix_index] + f.file_name,
                Convert.ToHexString(f.sha_file), f.raw_file_size, f.time_stamp) { Platforms = f.platforms_to_sync };
        }).ToArray());
    }

    // Only service-provided HTTPS storage hosts. No redirects, URL userinfo,
    // arbitrary ports, local addresses or host override headers.
    public static Uri Address(string host, string path, bool https)
    {
        if (!https || host.Length > 253 || !Uri.TryCreate("https://" + host + path, UriKind.Absolute, out var uri)
            || uri.Scheme != "https" || uri.Host != host || uri.Port != 443 || uri.UserInfo != "" || uri.Fragment != ""
            || !path.StartsWith('/') || path.StartsWith("//") || path.Any(char.IsControl)
            || Uri.CheckHostName(host) != UriHostNameType.Dns
            || !(host.EndsWith(".steamcontent.com", StringComparison.OrdinalIgnoreCase)
                || host.EndsWith(".steampowered.com", StringComparison.OrdinalIgnoreCase)
                || host.EndsWith(".steamusercontent.com", StringComparison.OrdinalIgnoreCase)
                // Valve's official ICloudService example uses this storage host.
                || (host.StartsWith("steamcloud-", StringComparison.Ordinal) && host.EndsWith(".storage.googleapis.com", StringComparison.Ordinal))))
            throw new SteamFailure("Steam returned an unsupported Cloud storage address. No save was sent.");
        return uri;
    }
    static HttpClient Client() => new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false,
        AutomaticDecompression = DecompressionMethods.None }) { Timeout = TimeSpan.FromSeconds(90) };
    static void Headers(HttpRequestMessage request, IEnumerable<(string name, string value)> headers)
    {
        var list = headers.ToArray();
        if (list.Length > 32) throw new SteamFailure("Steam returned too many Cloud HTTP headers.");
        foreach (var header in list)
        {
            if (header.name.Length == 0 || header.value.Length > 8192 || header.name.Any(char.IsControl) || header.value.Any(char.IsControl)
                || new[] { "Host", "Authorization", "Cookie", "Content-Length", "Transfer-Encoding", "Connection" }.Contains(header.name, StringComparer.OrdinalIgnoreCase))
                throw new SteamFailure("Unsupported Cloud HTTP header. No save was sent.");
            if (!request.Headers.TryAddWithoutValidation(header.name, header.value) &&
                request.Content?.Headers.TryAddWithoutValidation(header.name, header.value) != true)
                throw new SteamFailure("Invalid Cloud HTTP header.");
        }
    }
    public async Task<byte[]> Download(uint appId, CloudFile file, CancellationToken ct)
    {
        var info = await Reply(service.ClientFileDownload(new() { appid = appId, filename = file.Path }), ct);
        if (info.encrypted || info.is_explicit_delete || info.appid != appId || info.raw_file_size != file.Size ||
            info.file_size > CloudPaths.MaximumFileBytes || info.sha_file == null || Convert.ToHexString(info.sha_file) != file.Sha)
            throw new SteamFailure("Unsupported or changed Cloud download metadata. Saves were kept.");
        using var request = new HttpRequestMessage(HttpMethod.Get, Address(info.url_host, info.url_path, info.use_https));
        Headers(request, info.request_headers.Select(h => (h.name, h.value)));
        using var client = Client();
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is { } length && length != info.file_size)
            throw new SteamFailure("Cloud download length does not match its metadata.");
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        var wire = new byte[checked((int)info.file_size)];
        await stream.ReadExactlyAsync(wire, ct);
        var extra = new byte[1];
        if (await stream.ReadAsync(extra, ct) != 0) throw new SteamFailure("Cloud download exceeded its size limit.");
        var bytes = Decode(wire, file);
        CloudPaths.Verify(bytes, file);
        return bytes;
    }
    public static byte[] Decode(byte[] wire, CloudFile expected)
    {
        if (wire.Length == expected.Size && CloudPaths.Sha(wire) == expected.Sha) return wire;
        if (expected.Size is < 0 or > CloudPaths.MaximumFileBytes) throw new SteamFailure("Cloud save exceeds its size limit.");
        using var zip = new ZipArchive(new MemoryStream(wire), ZipArchiveMode.Read);
        if (zip.Entries.Count != 1 || zip.Entries[0].Length != expected.Size)
            throw new SteamFailure("Unsupported compressed Cloud save.");
        // Read bytes only. Archive member paths are never extracted to disk.
        using var stream = zip.Entries[0].Open();
        var result = new byte[checked((int)expected.Size)];
        stream.ReadExactly(result);
        if (stream.ReadByte() != -1) throw new SteamFailure("Cloud save exceeded its declared size.");
        CloudPaths.Verify(result, expected);
        return result;
    }

    public static byte[] BlockBody(ClientCloudFileUploadBlockDetails block, byte[] data)
    {
        if (block.http_method is not (3 or 4) || block.block_offset > (ulong)data.Length || block.block_length > (ulong)data.Length - block.block_offset)
            throw new SteamFailure("Unsupported Cloud upload block.");
        if (block.explicit_body_data is { Length: > 0 })
            throw new SteamFailure("Cloud uploads with explicit request bodies are not supported.");
        return data.AsSpan(checked((int)block.block_offset), checked((int)block.block_length)).ToArray();
    }
    public async Task Upload(uint appId, CloudFile file, byte[] data, CloudFile? expectedRemote, ulong expectedVersion, CancellationToken ct)
    {
        CloudPaths.Verify(data, file);
        var begin = new CCloud_BeginAppUploadBatch_Request { appid = appId, machine_name = "Iridium" };
        begin.files_to_upload.Add(file.Path); // Never populate files_to_delete.
        var batch = await Reply(service.BeginAppUploadBatch(begin), ct);
        if (batch.batch_id == 0) throw new SteamFailure("Steam did not open a Cloud upload batch.");
        var completed = false;
        try
        {
            await GuardRemote(appId, file.Path, expectedRemote, expectedVersion, ct);
            var upload = await Reply(service.ClientBeginFileUpload(new() { appid = appId, file_size = (uint)data.Length,
                raw_file_size = (uint)data.Length, file_sha = Convert.FromHexString(file.Sha), time_stamp = file.Time,
                filename = file.Path, platforms_to_sync = file.Platforms, can_encrypt = false, upload_batch_id = batch.batch_id }), ct);
            if (upload.encrypt_file || upload.block_requests.Count is 0 or > 4096)
                throw new SteamFailure("Steam returned an unsupported Cloud upload layout.");
            // Validate the entire layout before transmitting any local bytes.
            ulong covered = 0;
            foreach (var block in upload.block_requests)
            {
                _ = Address(block.url_host, block.url_path, block.use_https);
                _ = BlockBody(block, data);
                using var validate = new HttpRequestMessage(HttpMethod.Put, "https://store.steampowered.com") { Content = new ByteArrayContent([]) };
                Headers(validate, block.request_headers.Select(h => (h.name, h.value)));
                if (block.block_offset != covered) throw new SteamFailure("Cloud upload blocks overlap or leave gaps.");
                covered += block.block_length;
            }
            if (covered != (ulong)data.Length) throw new SteamFailure("Cloud upload blocks do not cover the save.");
            using var client = Client();
            foreach (var block in upload.block_requests)
            {
                using var request = new HttpRequestMessage(block.http_method == 3 ? HttpMethod.Post : HttpMethod.Put,
                    Address(block.url_host, block.url_path, block.use_https)) { Content = new ByteArrayContent(BlockBody(block, data)) };
                Headers(request, block.request_headers.Select(h => (h.name, h.value)));
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                response.EnsureSuccessStatusCode();
            }
            await GuardRemote(appId, file.Path, expectedRemote, expectedVersion, ct);
            var commit = await Reply(service.ClientCommitFileUpload(new() { appid = appId, filename = file.Path,
                file_sha = Convert.FromHexString(file.Sha), transfer_succeeded = true }), ct);
            if (!commit.file_committed) throw new SteamFailure("Steam did not commit the Cloud save. Recheck before retrying.");
            _ = await Reply(service.CompleteAppUploadBatchBlocking(new() { appid = appId, batch_id = batch.batch_id, batch_eresult = (uint)EResult.OK }), ct);
            completed = true;
        }
        finally
        {
            if (!completed)
            {
                // Best effort abort is bounded and cannot turn an interrupted upload into success.
                using var abort = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                try { _ = await Reply(service.CompleteAppUploadBatchBlocking(new() { appid = appId, batch_id = batch.batch_id, batch_eresult = (uint)EResult.Fail }), abort.Token); }
                catch { /* Durable pending journal requires explicit recheck. */ }
            }
        }
    }

    async Task GuardRemote(uint appId, string path, CloudFile? expected, ulong expectedVersion, CancellationToken ct)
    {
        var listing = await List(appId, ct);
        var current = listing.Files.SingleOrDefault(f => f.Path.Equals(path, StringComparison.OrdinalIgnoreCase));
        if (listing.Version != expectedVersion || current?.Sha != expected?.Sha || current?.Size != expected?.Size)
            throw new SteamFailure("Cloud changed during upload. The batch was stopped; compare saves again.");
        // The pinned API has no expected-hash conditional commit. These checks
        // and Steam's batch serialization reduce races; they are not an atomic CAS.
    }
}
