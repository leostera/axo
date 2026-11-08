using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace Axo;

/// <summary>One request per pipe connection. No shell interpolation, TCP listener or token file.</summary>
public sealed class DaemonClient
{
    readonly string pipeName;
    long nextId;
    public DaemonClient(string? pipe = null)
    {
        pipeName = pipe ?? Environment.GetEnvironmentVariable("AXO_PIPE") ?? $"Axo-{WindowsIdentity.GetCurrent().User?.Value ?? throw new InvalidOperationException("Windows user SID unavailable")}";
    }

    public async Task<JsonElement> CallAsync(string method, object? parameters = null, CancellationToken cancellation = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(75));
        await using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(3000, deadline.Token);
        var id = Interlocked.Increment(ref nextId);
        var request = JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method, @params = parameters ?? new { } });
        var bytes = Encoding.UTF8.GetBytes(request + "\n");
        await pipe.WriteAsync(bytes, deadline.Token);
        await pipe.FlushAsync(deadline.Token);
        using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, leaveOpen: true);
        var response = await reader.ReadLineAsync(deadline.Token) ?? throw new IOException("The daemon closed the connection.");
        using var document = JsonDocument.Parse(response);
        var root = document.RootElement;
        if (root.TryGetProperty("error", out var error))
            throw new IOException(error.GetProperty("message").GetString() ?? "Daemon request failed");
        if (!root.TryGetProperty("id", out var responseId) || responseId.GetInt64() != id)
            throw new IOException("The daemon returned an unexpected response ID.");
        return root.GetProperty("result").Clone();
    }

    public async Task EnsureStartedAsync()
    {
        try { await CallAsync("axo.daemon.health"); return; }
        catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException) { }
        var executable = Environment.GetEnvironmentVariable("AXO_DAEMON") ?? Path.Combine(AppContext.BaseDirectory, "axod.exe");
        if (!File.Exists(executable)) throw new FileNotFoundException("axod.exe is missing. Run windows/build.ps1 or place axod.exe beside Axo.exe.", executable);
        var codex = FindCodex();
        var server = Environment.GetEnvironmentVariable("AXO_SERVER_DIR") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Axo", "server");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--codex"); start.ArgumentList.Add(codex);
        start.ArgumentList.Add("--server-dir"); start.ArgumentList.Add(server);
        start.ArgumentList.Add("--pipe"); start.ArgumentList.Add(@"\\.\pipe\" + pipeName);
        var process = Process.Start(start) ?? throw new IOException("Could not start axod.");
        for (var attempt = 0; attempt < 20; attempt++)
        {
            await Task.Delay(300);
            try { await CallAsync("axo.daemon.health"); return; }
            catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException) { }
            if (process.HasExited) throw new IOException($"axod exited with code {process.ExitCode}. Run it from PowerShell to see its diagnostic.");
        }
        throw new IOException("axod did not become ready. Run axod.exe from PowerShell for diagnostics.");
    }

    public static string FindCodex()
    {
        var configured = Environment.GetEnvironmentVariable("AXO_CODEX");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            if (!File.Exists(configured)) throw new FileNotFoundException("AXO_CODEX must point to codex.exe.", configured);
            return configured;
        }
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            var candidate = Path.Combine(directory.Trim('"'), "codex.exe");
            if (File.Exists(candidate)) return candidate;
        }
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var bundled = Path.Combine(local, "OpenAI", "Codex", "bin");
        if (Directory.Exists(bundled))
        {
            var candidate = Directory.GetDirectories(bundled).OrderByDescending(Directory.GetLastWriteTimeUtc)
                .Select(d => Path.Combine(d, "codex.exe")).FirstOrDefault(File.Exists);
            if (candidate is not null) return candidate;
        }
        var cargo = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cargo", "bin", "codex.exe");
        if (File.Exists(cargo)) return cargo;
        throw new FileNotFoundException("Codex CLI was not found. Install it and sign in with 'codex login', or set AXO_CODEX to codex.exe.");
    }
}
