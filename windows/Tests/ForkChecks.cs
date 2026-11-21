using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Axo;
using Microsoft.AspNetCore.Http;

sealed partial class RelayFixture
{
    public const string ForkPeer = "11111111-0000-4000-8000-000000000001";
    public const string ForkGeneration = "11111111-0000-4000-8000-000000000002";
    public const string ForkSource = "11111111-0000-4000-8000-000000000003";
    public const string SourceFolder = "/disposable/mac-source";
    public const string HistoryMarker = "AXO_WINDOWS_FORK_HISTORY";
    public string? ProviderInput { get; private set; }

    async Task ServeForkPeerAsync(HttpContext context, bool hostRoute)
    {
        if (context.Request.RouteValues["account"]?.ToString() != Account
            || (hostRoute && context.Request.RouteValues["target"]?.ToString() != ForkPeer)
            || context.Request.Headers.Authorization != "Bearer " + credential
            || context.Request.Headers["X-Axo-Credential-Id"] != credentialId)
        {
            context.Response.StatusCode = 401;
            return;
        }
        using var socket = await context.WebSockets.AcceptWebSocketAsync();
        var token = context.RequestAborted;
        var buffer = new byte[32768];
        try
        {
            while (socket.State == WebSocketState.Open)
            {
                using var data = new MemoryStream();
                WebSocketReceiveResult frame;
                do
                {
                    frame = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
                    if (frame.MessageType == WebSocketMessageType.Close) return;
                    data.Write(buffer, 0, frame.Count);
                    if (data.Length > buffer.Length) throw new IOException("Oversized peer fixture message");
                } while (!frame.EndOfMessage);
                using var doc = JsonDocument.Parse(data.ToArray());
                var message = doc.RootElement;
                if (!message.TryGetProperty("id", out var id)) continue;
                const string timestamp = "2026-11-21T00:00:00.000Z";
                object result = message.GetProperty("method").GetString() switch
                {
                    "axo.client.hello" when !hostRoute => new { hosts = new[] { new { hostId = ForkPeer, hostGeneration = ForkGeneration, label = "Disposable Mac", online = true } }, sessions = Array.Empty<object>() },
                    "axo.client.hello" => new { online = true, hostGeneration = ForkGeneration, sessions = new[] { new { hostId = ForkPeer, sessionId = ForkSource, epoch = 4, head = 3, status = "working", metadata = new { agent = "pi", name = "Disposable source" } } } },
                    "axo.client.session.open" => new
                    {
                        epoch = 4,
                        header = JsonSerializer.Serialize(new { type = "session", version = 3, id = ForkSource, cwd = SourceFolder, timestamp }),
                        records = new[]
                        {
                            new { cursor = 1, line = JsonSerializer.Serialize(new { type = "message", id = "m1", parentId = (string?)null, timestamp, message = new { role = "user", content = new[] { new { type = "text", text = HistoryMarker } }, timestamp = 1795219200000L } }) },
                            new { cursor = 2, line = JsonSerializer.Serialize(new { type = "message", id = "m2", parentId = "m1", timestamp, message = new { role = "assistant", api = "openai-responses", provider = "openai", model = "fixture", content = new[] { new { type = "text", text = "Previous Pi answer" } }, stopReason = "stop", timestamp = 1795219200123L } }) },
                            new { cursor = 3, line = JsonSerializer.Serialize(new { type = "custom", id = "m3", parentId = "m2", timestamp, customType = "axo.command.queued", data = new { text = "NEVER_REPLAY" } }) },
                        }
                    },
                    _ => new { },
                };
                await SendAsync(socket, new { jsonrpc = "2.0", id, result });
            }
        }
        catch (Exception ex) when (ex is WebSocketException or OperationCanceledException or IOException) { }
    }

    async Task ForkModelAsync(HttpContext context)
    {
        using (var input = new StreamReader(context.Request.Body)) ProviderInput = await input.ReadToEndAsync();
        var responseId = "resp_fork_fixture";
        var output = new { id = "msg_fork_fixture", type = "message", role = "assistant", status = "completed", content = new[] { new { type = "output_text", text = "AXO_FORK_FOLLOWUP_OK", annotations = Array.Empty<object>() } } };
        var response = new { id = responseId, @object = "response", model = "gpt-5.4", status = "completed", output = new[] { output } };
        context.Response.ContentType = "text/event-stream";
        async Task Send(string type, object data) => await context.Response.WriteAsync($"event: {type}\ndata: {JsonSerializer.Serialize(data)}\n\n");
        await Send("response.created", new { type = "response.created", response = new { id = responseId, @object = "response", status = "in_progress", output = Array.Empty<object>() } });
        await Send("response.output_item.added", new { type = "response.output_item.added", output_index = 0, item = new { id = output.id, type = "message", role = "assistant", status = "in_progress", content = Array.Empty<object>() } });
        await Send("response.output_text.delta", new { type = "response.output_text.delta", item_id = output.id, output_index = 0, content_index = 0, delta = "AXO_FORK_FOLLOWUP_OK" });
        await Send("response.output_item.done", new { type = "response.output_item.done", output_index = 0, item = output });
        await Send("response.completed", new { type = "response.completed", response });
    }
}

static class ForkChecks
{
    static void Require(bool value, string description)
    {
        if (!value) throw new IOException(description);
        Console.WriteLine("PASS: " + description);
    }

    public static async Task<int> RunAsync(string daemon, string codex)
    {
        var root = Path.Combine(Path.GetTempPath(), "axo-codex-fork-test-" + Guid.NewGuid());
        var server = Path.Combine(root, "server");
        var folder = Directory.CreateDirectory(Path.Combine(root, "destination ž")).FullName;
        var home = Directory.CreateDirectory(Path.Combine(root, "codex-home")).FullName;
        var pipe = "Axo-Codex-Fork-" + Guid.NewGuid();
        var client = new DaemonClient(pipe);
        await using var relay = await RelayFixture.StartAsync(forkFixture: true);
        File.WriteAllText(Path.Combine(home, "config.toml"), $"""
            model = "gpt-5.4"
            model_provider = "fixture"
            [model_providers.fixture]
            name = "Fixture"
            base_url = "{relay.Origin}/fork-provider"
            env_key = "AXO_FORK_FIXTURE_KEY"
            wire_api = "responses"
            """);
        var start = new ProcessStartInfo(Path.GetFullPath(daemon)) { UseShellExecute = false, CreateNoWindow = true };
        foreach (string arg in new[] { "--server-dir", server, "--pipe", @"\\.\pipe\" + pipe, "--codex", Path.GetFullPath(codex), "--relay-url", relay.Origin }) start.ArgumentList.Add(arg);
        start.Environment["CODEX_HOME"] = home;
        start.Environment["AXO_FORK_FIXTURE_KEY"] = "fixture-only";
        start.Environment.Remove("OPENAI_API_KEY");
        using var process = Process.Start(start)!;
        try
        {
            for (int i = 0;; i++)
            {
                try { await client.CallAsync("axo.daemon.health"); break; }
                catch (IOException) when (i < 30 && !process.HasExited) { await Task.Delay(100); }
            }
            await client.CallAsync("axo.relay.link", new { code = "ABCD-EFGH" });
            await relay.WaitAsync(() => relay.Registration.ValueKind == JsonValueKind.Object, "Daemon not registered");
            var target = new { hostId = relay.Registration.GetProperty("hostId").GetString(), hostGeneration = relay.Registration.GetProperty("hostGeneration").GetString() };
            var snapshot = new { target, sourceHostId = RelayFixture.ForkPeer, sessionId = RelayFixture.ForkSource, epoch = 4, head = 3 };
            JsonElement plan = default;
            for (int i = 0; i < 30; i++)
            {
                plan = await relay.CallAsync("axo.remote.session.fork.plan", snapshot);
                if (plan.TryGetProperty("result", out _)) break;
                await Task.Delay(200);
            }
            var decision = plan.GetProperty("result").GetProperty("decision");
            Require(decision.GetProperty("kind").GetString() == "choose" && decision.GetProperty("agents")[0].GetString() == "codex", "confirmed Pi snapshot offers only explicit Codex import");
            var omitted = await relay.CallAsync("axo.remote.session.fork", new { target, snapshot.sourceHostId, snapshot.sessionId, snapshot.epoch, snapshot.head, folder, requestId = Guid.NewGuid() });
            Require(omitted.GetProperty("error").GetProperty("data").GetProperty("created").GetBoolean() == false, "omitting agent cannot substitute Codex");
            var stale = await relay.CallAsync("axo.remote.session.fork.plan", new { target, snapshot.sourceHostId, snapshot.sessionId, snapshot.epoch, head = 2 });
            Require(!stale.TryGetProperty("result", out _), "stale snapshot is refused");
            Require((await client.CallAsync("axo.session.list")).GetProperty("sessions").GetArrayLength() == 0, "plan and refusal leave no child");
            var request = new { target, snapshot.sourceHostId, snapshot.sessionId, snapshot.epoch, snapshot.head, folder, requestId = Guid.NewGuid(), agent = "codex" };
            var created = await relay.CallAsync("axo.remote.session.fork", request);
            var child = created.GetProperty("result").GetProperty("session");
            var id = child.GetProperty("sessionId").GetString()!;
            Require(id != snapshot.sessionId && child.GetProperty("status").GetString() == "ready", "new Windows child confirmed ready");
            var retried = await relay.CallAsync("axo.remote.session.fork", request);
            Require(retried.GetProperty("result").GetRawText() == created.GetProperty("result").GetRawText() && (await client.CallAsync("axo.session.list")).GetProperty("sessions").GetArrayLength() == 1, "same request returns same child with one catalog row");
            var path = Directory.GetFiles(Path.Combine(server, "imported-codex", id), "rollout-*.jsonl").Single();
            var history = File.ReadAllText(path);
            Require(history.Contains(RelayFixture.SourceFolder) && history.Contains(RelayFixture.ForkPeer) && history.Contains("\"role\":\"developer\"") && !history.Contains("NEVER_REPLAY") && relay.ProviderInput is null, "hidden provenance and history, no prompt replay or provider call");
            var opened = await client.CallAsync("axo.session.open", new { sessionId = id });
            Require(opened.GetProperty("folder").GetString() == folder && opened.GetProperty("threadId").GetString() == id && opened.GetProperty("connected").GetBoolean(), "native client pipe opens the real Codex child in the destination folder");
            await client.CallAsync("axo.session.prompt", new { sessionId = id, text = "AXO_FORK_FOLLOWUP" });
            await relay.WaitAsync(() => relay.ProviderInput is not null, "Real Codex did not issue the follow-up request");
            Require(relay.ProviderInput!.Contains(RelayFixture.HistoryMarker) && relay.ProviderInput.Contains("This conversation was forked from host") && relay.ProviderInput.Contains("AXO_FORK_FOLLOWUP"), "new Codex turn sees imported history and hidden origin");
            Console.WriteLine($"Disposable Windows child {id}; cwd={folder}; rollout={path}");
            return 0;
        }
        finally
        {
            if (!process.HasExited) { process.Kill(); await process.WaitForExitAsync(); }
        }
    }
}
