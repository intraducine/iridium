using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.Internal;

namespace Iridium.Steam;

// One CM connection per account. No credentials, protocol payloads or token logs.
public sealed class SteamConnection : IDisposable
{
    public SteamClient Client { get; } = new(SteamConfiguration.Create(b =>
        b.WithProtocolTypes(ProtocolTypes.WebSocket).WithMachineInfoProvider(new AppMachineInfo())));
    readonly CallbackManager callbacks;
    readonly CancellationTokenSource lifetime = new();
    readonly Task pump;
    readonly TaskCompletionSource connected = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly TaskCompletionSource<SteamUser.LoggedOnCallback> loggedOn = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public bool IsLoggedOn { get; private set; }

    // No hardware serial numbers, MAC addresses, or device identifiers leave the app.
    sealed class AppMachineInfo : IMachineInfoProvider
    {
        static readonly byte[] identity = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        public byte[] GetMachineGuid() => identity;
        public byte[] GetMacAddress() => identity;
        public byte[] GetDiskId() => identity;
    }

    public SteamConnection()
    {
        callbacks = new(Client);
        callbacks.Subscribe<SteamClient.ConnectedCallback>(_ => connected.TrySetResult());
        callbacks.Subscribe<SteamClient.DisconnectedCallback>(_ =>
        {
            IsLoggedOn = false;
            connected.TrySetException(new SteamFailure("Steam disconnected. Please sign in again."));
        });
        callbacks.Subscribe<SteamUser.LoggedOffCallback>(_ => IsLoggedOn = false);
        callbacks.Subscribe<SteamUser.LoggedOnCallback>(result => loggedOn.TrySetResult(result));
        pump = Task.Run(() =>
        {
            while (!lifetime.IsCancellationRequested)
                callbacks.RunWaitCallbacks(TimeSpan.FromMilliseconds(100));
        });
    }

    public async Task Connect(CancellationToken ct)
    {
        Client.Connect();
        await connected.Task.WaitAsync(TimeSpan.FromSeconds(30), ct);
    }

    public async Task<SavedSession> SignIn(Command command, IAuthenticator authenticator,
        Action<string> challenge, CancellationToken ct)
    {
        SavedSession saved;
        if (command.Action == "restore")
        {
            saved = new(command.AccountName ?? "", command.RefreshToken ?? "");
        }
        else
        {
            var details = new AuthSessionDetails
            {
                Username = command.AccountName,
                Password = command.Password,
                DeviceFriendlyName = "Iridium on iOS",
                IsPersistentSession = true,
                Authenticator = authenticator,
                ClientOSType = EOSType.Win11,
            };
            AuthSession session;
            if (command.Action == "qr")
            {
                var qr = await Client.Authentication.BeginAuthSessionViaQRAsync(details).WaitAsync(ct);
                qr.ChallengeURLChanged = () => challenge(qr.ChallengeURL);
                challenge(qr.ChallengeURL);
                session = qr;
            }
            else
                session = await Client.Authentication.BeginAuthSessionViaCredentialsAsync(details).WaitAsync(ct);
            details.Password = null;
            var result = await session.PollingWaitForResultAsync(ct);
            saved = new(result.AccountName, result.RefreshToken);
        }
        Client.GetHandler<SteamUser>()!.LogOn(new SteamUser.LogOnDetails
        {
            Username = saved.AccountName,
            AccessToken = saved.RefreshToken,
            ShouldRememberPassword = true,
            ClientOSType = EOSType.Win11,
        });
        var login = await loggedOn.Task.WaitAsync(TimeSpan.FromSeconds(30), ct);
        if (login.Result != EResult.OK)
            throw new SteamFailure($"Steam sign-in failed ({login.Result}). Please sign in again.");
        IsLoggedOn = true;
        return saved;
    }

    public async Task<Game[]> Library(CancellationToken ct)
    {
        var player = Client.GetHandler<SteamUnifiedMessages>()!.CreateService<Player>();
        var response = await player.GetOwnedGames(new CPlayer_GetOwnedGames_Request
        {
            steamid = Client.SteamID!.ConvertToUInt64(),
            include_appinfo = true,
            include_played_free_games = true,
            include_free_sub = true,
        }).ToTask().WaitAsync(TimeSpan.FromSeconds(45), ct);
        if (response.Result != EResult.OK)
            throw new SteamFailure($"Steam could not load your library ({response.Result}). Try refreshing.");
        return response.Body.games.Where(g => g.appid > 0)
            .Select(g => new Game((uint)g.appid, g.name))
            .DistinctBy(g => g.AppId).OrderBy(g => g.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public async Task<KeyValue> AppInfo(uint appId, CancellationToken ct)
    {
        var apps = Client.GetHandler<SteamApps>()!;
        var tokens = await apps.PICSGetAccessTokens([appId], []).ToTask().WaitAsync(TimeSpan.FromSeconds(30), ct);
        var request = new SteamApps.PICSRequest(appId);
        if (tokens.AppTokens.TryGetValue(appId, out var token)) request.AccessToken = token;
        var result = await apps.PICSGetProductInfo([request], []).ToTask().WaitAsync(TimeSpan.FromSeconds(45), ct);
        return result.Results?.SelectMany(r => r.Apps).FirstOrDefault(p => p.Key == appId).Value?.KeyValues
            ?? throw new SteamFailure("Steam did not return installation information for this game.");
    }

    public void Dispose()
    {
        IsLoggedOn = false;
        Client.Disconnect();
        lifetime.Cancel();
        // Callback pump observes cancellation in at most 100 ms; do not block the UI.
        _ = pump.ContinueWith(_ => lifetime.Dispose(), TaskScheduler.Default);
    }
}
