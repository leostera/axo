using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Axo;

/// <summary>Owns every window/process it drives; never touches a user application.</summary>
static class ComputerChecks
{
    public static int RunFixture(string ready)
    {
        var thread = new Thread(() =>
        {
            var app = new Application();
            var panel = new StackPanel { Margin = new Thickness(24) };
            var input = new TextBox { Text = "initial fixture value", Margin = new Thickness(0, 8, 0, 8) };
            System.Windows.Automation.AutomationProperties.SetName(input, "Fixture input");
            var output = new TextBlock { Text = "Fixture count: 0", Margin = new Thickness(0, 8, 0, 8) };
            int count = 0;
            foreach (var title in new[] { "Increment fixture", "Send fixture" })
            {
                var button = new Button { Content = title, Margin = new Thickness(0, 8, 0, 8) };
                button.Click += (_, _) => output.Text = "Fixture count: " + ++count;
                panel.Children.Add(button);
            }
            panel.Children.Add(input); panel.Children.Add(output);
            var window = new Window { Title = "Axo computer-use test fixture", Content = panel, Width = 600, Height = 320, ShowActivated = false };
            window.Loaded += (_, _) => File.WriteAllText(ready, JsonSerializer.Serialize(new { pid = Environment.ProcessId, window_id = new WindowInteropHelper(window).Handle.ToInt64() }));
            app.Run(window);
        });
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join(); return 0;
    }

    public static async Task RunAsync(DaemonClient client, string daemonPath, string pipe, string session, RelayFixture relay, object target, Action<bool, string> assert)
    {
        var defaults = await client.CallAsync("axo.windows.settings");
        assert(!defaults.GetProperty("computerUseEnabled").GetBoolean() && !defaults.GetProperty("codexFullAccess").GetBoolean(), "computer use and unattended commands require explicit local opt-in");
        await using var mcp = new Mcp(daemonPath, pipe, session);
        var initialized = await mcp.Request("initialize", new { protocolVersion = "2025-06-18", capabilities = new { }, clientInfo = new { name = "Axo isolated test", version = "1" } });
        assert(initialized.GetProperty("serverInfo").GetProperty("name").GetString() == "axo", "Windows axod mcp speaks the same Axo MCP server identity");
        var tools = await mcp.Request("tools/list", new { });
        assert(tools.GetProperty("tools").EnumerateArray().Select(t => t.GetProperty("name").GetString()).SequenceEqual(new[] { "computer_tools", "computer" }), "Codex gets the computer and computer_tools wrappers");
        var disabled = await mcp.Tool("computer", new { tool = "get_screen_size", args = new { } });
        assert(IsError(disabled), "a configured MCP server cannot operate the PC while computer use is disabled");

        // This runner is copied as Axo.exe beside its private axod: it represents
        // the trusted desktop. Its Tests.exe copy represents an untrusted tool.
        var forbidden = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Tests.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "--untrusted-permissions", pipe }) forbidden.ArgumentList.Add(a);
        using (var child = Process.Start(forbidden)!)
        {
            var stdout = child.StandardOutput.ReadToEndAsync(); var stderr = child.StandardError.ReadToEndAsync();
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
            assert(child.ExitCode == 0, "a tool process cannot enable computer use or approve its own request: " + await stdout + await stderr);
        }
        await client.CallAsync("axo.windows.settings.save", new { computerUseEnabled = true, codexFullAccess = true });
        assert((await client.CallAsync("axo.computer.status")).GetProperty("available").GetBoolean(), "local desktop can enable the native Windows computer backend");
        var definitions = await mcp.Tool("computer_tools", new { });
        var names = definitions.GetProperty("structuredContent").GetProperty("tools").EnumerateArray().Select(t => t.GetProperty("name").GetString()).ToArray();
        assert(names.Contains("get_window_state") && names.Contains("click") && names.Contains("set_value") && !names.Contains("run_script") && !names.Contains("request_input"), "computer tool discovery exposes the real Windows allowlist without unsupported secret forms or scripts");
        assert(IsError(await mcp.Tool("computer", new { tool = "run_script", args = new { script = "anything" } })), "unadvertised composite scripts cannot bypass the daemon gate");
        assert(IsError(await mcp.Tool("computer", new { tool = "hotkey", args = new { scope = "desktop", keys = new[] { "enter" } } })), "computer input must target a specific app window");
        assert(IsError(await mcp.Tool("computer", new { tool = "click", args = new { pid = Environment.ProcessId, window_id = 1, x = 1, y = 1 } })), "computer tools cannot click Axo's own permission interface");

        var ready = Path.Combine(Path.GetTempPath(), "axo-computer-fixture-" + Guid.NewGuid() + ".json");
        var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Tests.exe")) { UseShellExecute = false };
        start.ArgumentList.Add("--computer-fixture"); start.ArgumentList.Add(ready);
        using var fixture = Process.Start(start)!;
        try
        {
            for (var n = 0; n < 100 && !File.Exists(ready); n++) { if (fixture.HasExited) throw new Exception("Computer fixture exited"); await Task.Delay(50); }
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(ready));
            int pid = document.RootElement.GetProperty("pid").GetInt32(); long window = document.RootElement.GetProperty("window_id").GetInt64();
            async Task<JsonElement> Read(bool screenshot = false) => await mcp.Tool("computer", new { tool = "get_window_state", args = new { pid, window_id = window, include_screenshot = screenshot } });
            var state = await Read();
            assert(!IsError(state) && state.ToString().Contains("Fixture input"), "real UI Automation reads only the owned WPF fixture's window");
            var image = await Read(true);
            assert(!IsError(image) && image.GetProperty("content").EnumerateArray().Any(c => c.GetProperty("type").GetString() == "image" && c.GetProperty("data").GetString()!.Length > 100), "native Windows window capture returns an inline MCP image");

            var token = FindToken(image, "Fixture input");
            var set = await mcp.Tool("computer", new { tool = "set_value", args = new { pid, window_id = window, session = "agent-supplied-label", element_token = token, value = "Axo Windows UIA verified" } });
            if (IsError(set) || token.Length == 0) { Console.WriteLine("Window structure: " + image.GetProperty("structuredContent")); Console.WriteLine("Set result: " + set); }
            assert(!IsError(set) && (await Read()).ToString().Contains("Axo Windows UIA verified"), "native set_value changes an observed fixture field and a fresh read verifies it");
            var stale = await mcp.Tool("computer", new { tool = "set_value", args = new { pid, window_id = window, element_token = "missing-snapshot:99999", value = "must not be written" } });
            assert(IsError(stale) && !(await Read()).ToString().Contains("must not be written"), "unknown element tokens fail without changing the fixture");
            state = await Read();
            var clicked = await mcp.Tool("computer", new { tool = "click", args = new { pid, window_id = window, element_token = FindToken(state, "Increment fixture") } });
            assert(!IsError(clicked) && (await Read()).ToString().Contains("Fixture count: 1"), "native element click invokes the owned fixture button and a fresh read verifies the result");
            state = await Read();
            var risky = client.CallAsync("axo.computer.call", new { sessionId = session, tool = "click", args = new { pid, window_id = window, element_token = FindToken(state, "Send fixture") }, timeoutMs = 15000 });
            var riskQuestion = await Question(client);
            assert(riskQuestion.GetProperty("message").GetString()!.Contains("Send fixture") && !risky.IsCompleted, "the shared gate reads the observed target label before a potentially committing click");
            await client.CallAsync("axo.elicitation.resolve", new { elicitationId = riskQuestion.GetProperty("id").GetString(), action = "decline" });
            assert(IsError(await risky) && (await Read()).ToString().Contains("Fixture count: 1"), "declining a flagged click leaves the fixture untouched");

            // A confirm-only read opens a real question without causing any input.
            var gate = client.CallAsync("axo.computer.call", new { sessionId = session, tool = "get_screen_size", args = new { }, confirm = true, timeoutMs = 15000 });
            var question = await Question(client);
            assert(question.GetProperty("askedBy").GetString() == "computerUse", "computer permission uses the shared elicitation schema");
            await client.CallAsync("axo.elicitation.resolve", new { elicitationId = question.GetProperty("id").GetString(), action = "decline" });
            assert(IsError(await gate), "declining a computer permission prevents the call");
            var accepted = client.CallAsync("axo.computer.call", new { sessionId = session, tool = "get_screen_size", args = new { }, confirm = true, timeoutMs = 15000 });
            question = await Question(client);
            await client.CallAsync("axo.elicitation.resolve", new { elicitationId = question.GetProperty("id").GetString(), action = "accept" });
            assert(!IsError(await accepted), "the desktop can allow one exact pending computer call");
            bool rejected = false;
            try { await client.CallAsync("axo.elicitation.resolve", new { elicitationId = question.GetProperty("id").GetString(), action = "accept" }); } catch (IOException) { rejected = true; }
            assert(rejected, "resolved computer permission cannot be reused");
            var timed = await client.CallAsync("axo.computer.call", new { sessionId = session, tool = "get_screen_size", args = new { }, confirm = true, timeoutMs = 100 });
            assert(IsError(timed) && (await client.CallAsync("axo.elicitation.list")).GetProperty("elicitations").GetArrayLength() == 0, "expired computer calls retire their question without executing");
            var disconnected = new Mcp(daemonPath, pipe, session);
            var abandoned = disconnected.Tool("computer", new { tool = "get_screen_size", args = new { }, confirm = true });
            _ = await Question(client);
            await disconnected.DisposeAsync();
            try { await abandoned; } catch (IOException) { }
            for (var i = 0; i < 100 && (await client.CallAsync("axo.elicitation.list")).GetProperty("elicitations").GetArrayLength() != 0; i++) await Task.Delay(25);
            assert((await client.CallAsync("axo.elicitation.list")).GetProperty("elicitations").GetArrayLength() == 0, "closing an MCP caller cancels its approval before a late answer can act");
            var revoked = client.CallAsync("axo.computer.call", new { sessionId = session, tool = "get_screen_size", args = new { }, confirm = true, timeoutMs = 15000 });
            _ = await Question(client);
            await client.CallAsync("axo.windows.settings.save", new { computerUseEnabled = false, codexFullAccess = true });
            await client.CallAsync("axo.windows.settings.save", new { computerUseEnabled = true, codexFullAccess = true });
            assert(IsError(await revoked) && (await client.CallAsync("axo.elicitation.list")).GetProperty("elicitations").GetArrayLength() == 0, "disable then re-enable cannot revive a previously pending permission");
            assert(IsError(await mcp.Tool("computer", new { tool = "screenshot", args = new { screenshot_out_file = Path.Combine(Path.GetTempPath(), "must-not-write.png") } })), "read-only computer tools cannot write arbitrary output files");

            var remote = await relay.CallAsync("axo.apps.computer.status", new { accountId = RelayFixture.Account });
            assert(remote.TryGetProperty("result", out var remoteStatus) && remoteStatus.GetProperty("available").GetBoolean(), "paired relay reports the Windows computer backend status");
            remote = await relay.CallAsync("axo.apps.computer", new { accountId = RelayFixture.Account, callId = Guid.NewGuid().ToString(), tool = "get_window_state", args = new { pid, window_id = window, include_screenshot = false }, sessionId = session, from = "fixture", timeoutMs = 15000 });
            assert(remote.TryGetProperty("result", out var remoteRead) && !IsError(remoteRead) && remoteRead.ToString().Contains("Fixture input"), "remote computer calls use the native Windows window backend");
            remote = await relay.CallAsync("axo.apps.computer", new { accountId = RelayFixture.Account, callId = Guid.NewGuid().ToString(), tool = "get_window_state", args = new { pid, window_id = window, include_screenshot = true }, sessionId = session, from = "fixture", timeoutMs = 15000 });
            assert(remote.TryGetProperty("result", out var remoteImage) && remoteImage.GetProperty("content").EnumerateArray().Any(c => c.GetProperty("type").GetString() == "image" && c.TryGetProperty("attachment", out _)) && relay.Assets.Count > 0, "relay screenshots upload authenticated, hash-verified image assets and return attachment references");
            var attachment=remoteImage.GetProperty("content").EnumerateArray().First(c=>c.GetProperty("type").GetString()=="image").GetProperty("attachment").Clone();
            remote=await relay.CallAsync("axo.remote.session.prompt",new{target,sessionId=session,text="must not silently discard this image",attachments=new[]{attachment},commandId=Guid.NewGuid().ToString()});
            assert(remote.TryGetProperty("error",out _),"host-owned remote dispatch rejects unsupported attachments instead of discarding them");
            remote=await relay.CallAsync("axo.remote.windows.settings.save",new{target,computerUseEnabled=false,codexFullAccess=true});
            assert(remote.TryGetProperty("error",out var permissionError)&&permissionError.GetProperty("code").GetInt32()==-32601&&(await client.CallAsync("axo.computer.status")).GetProperty("available").GetBoolean(),"account forwarding cannot reach local permission settings");
            remote=await relay.CallAsync("axo.remote.workspace.list",new{target=new{hostId=relay.Registration.GetProperty("hostId").GetString(),hostGeneration="stale"}});
            assert(remote.TryGetProperty("error",out var staleHost)&&staleHost.GetProperty("code").GetInt32()==-32002,"host-owned dispatch rejects a stale relay generation before operating");
        }
        finally { if (!fixture.HasExited) { fixture.Kill(entireProcessTree: true); await fixture.WaitForExitAsync(); } }
        await client.CallAsync("axo.session.prompt", new { sessionId = session, text = "inspect-policy" });
        for (var i = 0; i < 100; i++)
        {
            var messages = await client.CallAsync("axo.session.messages", new { sessionId = session });
            if (messages.ToString().Contains("dangerFullAccess")) { assert(messages.ToString().Contains("never"), "Full Access reaches the next Codex turn as never / dangerFullAccess"); break; }
            if (i == 99) throw new Exception("Full Access did not reach the Codex fixture");
            await Task.Delay(50);
        }
        await client.CallAsync("axo.windows.settings.save", new { computerUseEnabled = false, codexFullAccess = false });
        assert(!(await client.CallAsync("axo.computer.status")).GetProperty("available").GetBoolean(), "disabling computer use immediately revokes local and relay access");
    }

    public static async Task LiveAsync(DaemonClient client, string session, Action<bool,string> assert)
    {
        var ready = Path.Combine(Path.GetTempPath(), "axo-codex-computer-fixture-" + Guid.NewGuid() + ".json");
        var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Tests.exe")) { UseShellExecute = false };
        start.ArgumentList.Add("--computer-fixture"); start.ArgumentList.Add(ready);
        using var fixture = Process.Start(start)!;
        try
        {
            for(var i=0;i<100&&!File.Exists(ready);i++){if(fixture.HasExited)throw new Exception("Live computer fixture exited");await Task.Delay(50);}
            using var doc = JsonDocument.Parse(await File.ReadAllTextAsync(ready));
            var pid=doc.RootElement.GetProperty("pid").GetInt32();var window=doc.RootElement.GetProperty("window_id").GetInt64();
            var before=await client.CallAsync("axo.session.events.poll",new{sessionId=session});var cursor=before.GetProperty("sequence").GetUInt64();
            await client.CallAsync("axo.session.prompt",new{sessionId=session,text=$"Use only the Axo MCP computer_tools and computer tools for this owned test fixture. First inspect the get_window_state and set_value schemas using computer_tools. Read the window with pid {pid} and window_id {window}; include its screenshot. Set the field labelled Fixture input to exactly AXO_CODEX_COMPUTER_OK using the returned element_token, then read the same window again to verify. Do not use a shell, edit files, launch apps, or control any other window. Reply exactly AXO_CODEX_COMPUTER_OK after verifying the value."});
            bool mcpRead=false,mcpWrite=false,done=false;
            for(var i=0;i<360;i++)
            {
                var status=await client.CallAsync("axo.session.events.poll",new{sessionId=session,after=cursor});
                foreach(var envelope in status.GetProperty("events").EnumerateArray())
                {
                    cursor=Math.Max(cursor,envelope.GetProperty("sequence").GetUInt64());var e=envelope.GetProperty("event");
                    if(e.GetProperty("method").GetString()=="item/completed"&&e.GetProperty("params").TryGetProperty("item",out var item)&&item.GetProperty("type").GetString()=="mcpToolCall")
                    {
                        Console.WriteLine("Live MCP item: "+JsonSerializer.Serialize(new{server=item.GetProperty("server").GetString(),tool=item.GetProperty("tool").GetString(),status=item.GetProperty("status").GetString()}));
                        if(item.GetProperty("server").GetString()=="axo"&&item.GetProperty("status").GetString()=="completed")
                        {
                            var arguments=item.GetProperty("arguments").ToString();
                            if(arguments.Contains("get_window_state"))mcpRead=true;
                            if(arguments.Contains("set_value")&&arguments.Contains("AXO_CODEX_COMPUTER_OK"))mcpWrite=true;
                        }
                    }
                }
                if(status.GetProperty("status").GetString()=="needsAttention")throw new Exception("Live computer test needs input: "+status.GetProperty("pendingRequests"));
                if(status.GetProperty("status").GetString()=="ready"){done=true;break;}await Task.Delay(500);
            }
            assert(done&&mcpRead&&mcpWrite,"real Codex discovers Axo MCP and completes native window-read and set-value calls");
            var observed=await client.CallAsync("axo.computer.call",new{sessionId=session,tool="get_window_state",args=new{pid,window_id=window,include_screenshot=false}});
            assert(!IsError(observed)&&observed.ToString().Contains("AXO_CODEX_COMPUTER_OK"),"independent native read verifies the real Codex agent changed only the owned fixture field");
        }
        finally{if(!fixture.HasExited){fixture.Kill(entireProcessTree:true);await fixture.WaitForExitAsync();}}
    }

    static bool IsError(JsonElement result) => result.TryGetProperty("isError", out var error) && error.GetBoolean();
    static string FindToken(JsonElement result, string label)
    {
        if (result.ValueKind == JsonValueKind.Object)
        {
            if (result.TryGetProperty("element_token", out var token) && result.ToString().Contains(label)) return token.GetString()!;
            foreach (var child in result.EnumerateObject()) { var found = FindToken(child.Value, label); if (found.Length != 0) return found; }
        }
        if (result.ValueKind == JsonValueKind.Array) foreach (var child in result.EnumerateArray()) { var found = FindToken(child, label); if (found.Length != 0) return found; }
        return "";
    }
    static async Task<JsonElement> Question(DaemonClient client)
    {
        for (var i = 0; i < 100; i++) { var pending = await client.CallAsync("axo.elicitation.list"); if (pending.GetProperty("elicitations").GetArrayLength() > 0) return pending.GetProperty("elicitations")[0].Clone(); await Task.Delay(25); }
        throw new Exception("No computer permission question");
    }

    sealed class Mcp : IAsyncDisposable
    {
        readonly Process process;
        int id;
        public Mcp(string daemon, string pipe, string session)
        {
            var start = new ProcessStartInfo(daemon) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var a in new[] { "mcp", "--pipe", @"\\.\pipe\" + pipe, "--session", session }) start.ArgumentList.Add(a);
            process = Process.Start(start)!; process.BeginErrorReadLine();
        }
        public async Task<JsonElement> Request(string method, object parameters)
        {
            var requestId = ++id;
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", id = requestId, method, @params = parameters })); await process.StandardInput.FlushAsync();
            var line = await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30)) ?? throw new IOException("MCP exited");
            using var doc = JsonDocument.Parse(line); var root = doc.RootElement;
            if (root.GetProperty("id").GetInt32() != requestId) throw new IOException("Unexpected MCP id");
            if (root.TryGetProperty("error", out var error)) throw new IOException(error.ToString());
            return root.GetProperty("result").Clone();
        }
        public Task<JsonElement> Tool(string name, object arguments) => Request("tools/call", new { name, arguments });
        public async ValueTask DisposeAsync() { process.StandardInput.Close(); try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); } finally { if (!process.HasExited) process.Kill(entireProcessTree: true); process.Dispose(); } }
    }
}
