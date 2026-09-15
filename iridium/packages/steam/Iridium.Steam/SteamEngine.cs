using SteamKit2.Authentication;

namespace Iridium.Steam;

public sealed class SteamEngine(string root) : IAuthenticator
{
    readonly object sync = new();
    Snapshot state = new();
    SteamConnection? connection;
    CancellationTokenSource? operation;
    TaskCompletionSource<string>? guardCode;
    SavedSession? pendingSecret;

    public Snapshot Read()
    {
        lock (sync)
        {
            if (state.SignedIn && connection?.IsLoggedOn != true)
                state = state with { SignedIn = false, Message = "Steam disconnected. Sign in again to continue." };
            return state;
        }
    }
    void Update(Func<Snapshot, Snapshot> update) { lock (sync) state = update(state); }
    public SavedSession? TakeSecret() { lock (sync) { var value = pendingSecret; pendingSecret = null; return value; } }

    // Returns false for rejected/busy commands. No competing login or install tasks.
    public bool Submit(Command command)
    {
        lock (sync)
        {
            if (command.Action == "cancel")
            {
                operation?.Cancel();
                if (state.Busy) state = state with { Phase = "pausing", Message = "Stopping the current request. Partial downloads are kept." };
                return true;
            }
            if (command.Action == "guard")
                return !string.IsNullOrWhiteSpace(command.Code) && guardCode?.TrySetResult(command.Code.Trim()) == true;
            if (state.Busy) return false;
            if (command.Action == "signOut")
            {
                connection?.Dispose(); connection = null; pendingSecret = null;
                state = new();
                return true;
            }
            if (command.Action is not ("signIn" or "qr" or "restore" or "library" or "install")) return false;
            if (command.Action is "library" or "install" && connection?.IsLoggedOn != true) return false;
            if (command.Action == "signIn" && (string.IsNullOrWhiteSpace(command.AccountName) || string.IsNullOrEmpty(command.Password))) return false;
            operation?.Dispose();
            operation = new();
            if (command.Action is "signIn" or "qr" or "restore") operation.CancelAfter(TimeSpan.FromMinutes(5));
            state = state with { Busy = true, Error = null, ChallengeUrl = null, Installed = null,
                Phase = command.Action == "install" ? "resolving" : "connecting",
                Message = command.Action == "install" ? "Checking Windows game files…" : "Connecting to Steam…",
                AppId = command.Action == "install" ? command.AppId : null, CompletedBytes = 0, TotalBytes = 0 };
            _ = Task.Run(() => Run(command, operation.Token));
            return true;
        }
    }

    async Task Run(Command command, CancellationToken ct)
    {
        var authenticating = command.Action is "signIn" or "qr" or "restore";
        try
        {
            if (authenticating)
            {
                connection?.Dispose();
                connection = new();
                Update(s => s with { SignedIn = false, Games = [], AccountName = null });
                await connection.Connect(ct);
                var saved = await connection.SignIn(command, this,
                    url => Update(s => s with { Phase = "qr", ChallengeUrl = url, Message = "Scan with Steam Mobile to approve sign-in." }), ct);
                lock (sync) pendingSecret = saved;
                Update(s => s with { SignedIn = true, AccountName = saved.AccountName, ChallengeUrl = null });
            }
            if (authenticating || command.Action == "library")
            {
                Update(s => s with { Phase = "syncing", Message = "Loading your games…" });
                var games = await connection!.Library(ct);
                Update(s => s with { Phase = "ready", Games = games, Message = "Choose a game to download." });
            }
            if (command.Action == "install")
            {
                var game = Read().Games.FirstOrDefault(g => g.AppId == command.AppId)
                    ?? throw new SteamFailure("Refresh your Steam library before downloading this game.");
                var installed = await new SteamInstaller(connection!).Install(game, root,
                    (done, total) => Update(s => s with { CompletedBytes = Math.Max(s.CompletedBytes, done), TotalBytes = total }),
                    phase => Update(s => s with { Phase = phase,
                        Message = phase == "finalizing" ? "Finishing installation…" : "Downloading and verifying on this device…" }), ct);
                Update(s => s with { Phase = "installed", Installed = installed, Message = "Verified. Choose the game's executable to add it to your library." });
            }
        }
        catch (OperationCanceledException)
        {
            Update(s => s with { Phase = authenticating ? "signedOut" : "paused",
                Message = authenticating ? "Sign-in cancelled or expired." : "Paused. Choose Download / resume to continue." });
        }
        catch (Exception e)
        {
            // Never surface arbitrary network/IO exception text; it may contain tokens or private paths.
            var message = e is SteamFailure ? e.Message
                : e is TimeoutException ? "Steam did not respond in time. Please retry."
                : e is AuthenticationException ? "Steam rejected the sign-in. Check your credentials and Steam Guard, then retry."
                : e is IOException ? "The download could not be saved. Check free storage and resume."
                : "Steam could not complete this request. Check your connection and retry.";
            Update(s => s with { Phase = "failed", Error = message, Message = message });
        }
        finally
        {
            if (authenticating && connection?.IsLoggedOn != true)
            {
                connection?.Dispose(); connection = null;
                lock (sync) pendingSecret = null;
            }
            lock (sync)
            {
                guardCode = null;
                state = state with { Busy = false, ChallengeUrl = null, SignedIn = connection?.IsLoggedOn == true };
            }
        }
    }

    Task<string> AskCode(string message)
    {
        lock (sync)
        {
            guardCode = new(TaskCreationOptions.RunContinuationsAsynchronously);
            state = state with { Phase = "guard", Message = message };
            return guardCode.Task.WaitAsync(operation!.Token);
        }
    }
    public Task<string> GetDeviceCodeAsync(bool previousCodeWasIncorrect) => AskCode(previousCodeWasIncorrect
        ? "That code was incorrect. Enter a new Steam Guard code." : "Enter the code from Steam Guard.");
    public Task<string> GetEmailCodeAsync(string email, bool previousCodeWasIncorrect) => AskCode(previousCodeWasIncorrect
        ? "That code was incorrect. Enter the new email code." : "Enter the Steam Guard code sent to your email.");
    public Task<bool> AcceptDeviceConfirmationAsync()
    {
        Update(s => s with { Phase = "approval", Message = "Approve this sign-in in Steam Mobile." });
        return Task.FromResult(true);
    }
}
