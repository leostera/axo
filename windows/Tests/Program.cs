using System.Diagnostics;
using System.Text.Json;
using Axo;

if (args.Length == 3 && args[0] == "--package-check")
{
    string installed = Installer.Install(Path.GetFullPath(args[1]), Path.GetFullPath(args[2]));
    Console.WriteLine("Verified and staged package: " + Installer.Verify(Path.GetDirectoryName(installed)!));
    return 0;
}

if (args.Length == 2 && args[0] == "--computer-fixture") return ComputerChecks.RunFixture(args[1]);
if (args.Length == 2 && args[0] == "--untrusted-permissions")
{
    var untrusted = new DaemonClient(args[1]);
    int refused = 0;
    foreach (var (method, parameters) in new (string, object)[] {
        ("axo.windows.settings.save", new { computerUseEnabled = true, codexFullAccess = true }),
        ("axo.elicitation.resolve", new { elicitationId = Guid.NewGuid().ToString(), action = "accept" }) })
    {
        try { await untrusted.CallAsync(method, parameters); }
        catch (IOException e) when (e.Message.Contains("Only the bundled Axo")) { refused++; }
    }
    Console.WriteLine($"Refused {refused}/2 unauthorized requests"); return refused == 2 ? 0 : 1;
}
if (args.Length < 2 || args.Length > 3) throw new ArgumentException("Usage: Tests <axod.exe> <fake_codex.exe> OR <axod.exe> <codex.exe> --live");
// The process peer check uses the actual connected image, not a JSON role. Run
// tests as the desktop in a private bundle; Tests.exe remains the tool peer.
if (!string.Equals(Path.GetFileName(Environment.ProcessPath), "Axo.exe", StringComparison.OrdinalIgnoreCase))
{
    var bundle = Path.Combine(Path.GetTempPath(), "axo-desktop-fixture-" + Guid.NewGuid()); Directory.CreateDirectory(bundle);
    foreach (var file in Directory.GetFiles(AppContext.BaseDirectory, "*", SearchOption.AllDirectories))
    {
        var destination = Path.Combine(bundle, Path.GetRelativePath(AppContext.BaseDirectory, file)); Directory.CreateDirectory(Path.GetDirectoryName(destination)!); File.Copy(file, destination, true);
    }
    File.Copy(Path.Combine(AppContext.BaseDirectory, "Tests.exe"), Path.Combine(bundle, "Axo.exe"), true);
    File.Copy(Path.GetFullPath(args[0]), Path.Combine(bundle, "axod.exe"), true);
    if(args.Length != 3)File.Copy(Path.GetFullPath(Path.Combine(Path.GetDirectoryName(args[0])!,"../axo-seal/seal_fixture.exe")),Path.Combine(bundle,"seal_fixture.exe"));
    var launch = new ProcessStartInfo(Path.Combine(bundle, "Axo.exe")) { UseShellExecute = false };
    launch.ArgumentList.Add(Path.Combine(bundle, "axod.exe")); launch.ArgumentList.Add(Path.GetFullPath(args[1])); if (args.Length == 3) launch.ArgumentList.Add(args[2]);
    using var runner = Process.Start(launch)!; await runner.WaitForExitAsync(); return runner.ExitCode;
}
var live = args.Length == 3 && args[2] == "--live";
var daemonPath = Path.GetFullPath(args[0]); var codexPath = Path.GetFullPath(args[1]);
var root = Path.Combine(Path.GetTempPath(), "axo-windows-test-" + Guid.NewGuid());
var server = Path.Combine(root, "server"); var workspace = Path.Combine(root, "project with spaces ž");
Directory.CreateDirectory(workspace);
var pipe = "Axo-Test-" + Guid.NewGuid();
var client = new DaemonClient(pipe);
await using var relay = live ? null : await RelayFixture.StartAsync();
Process? daemon = null;
int assertions = 0;
void Assert(bool condition, string name) { if (!condition) throw new Exception("FAIL: " + name); assertions++; Console.WriteLine("PASS: " + name); }
Process Start()
{
    var start = new ProcessStartInfo(daemonPath) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput=true, RedirectStandardError=true };
    foreach (var a in new[] { "--pipe", @"\\.\pipe\" + pipe, "--server-dir", server, "--codex", codexPath }) start.ArgumentList.Add(a);
    if(relay is not null){start.ArgumentList.Add("--relay-url");start.ArgumentList.Add(relay.Origin);}
    var process=Process.Start(start)!;
    process.BeginOutputReadLine();process.BeginErrorReadLine();
    return process;
}
async Task Ready()
{
    for (int i = 0; i < 30; i++)
    {
        try { await client.CallAsync("axo.daemon.health"); return; }
        catch { if (daemon!.HasExited) throw new Exception("Daemon failed to start: " + daemon.ExitCode); await Task.Delay(100); }
    }
    throw new Exception("Daemon startup timed out");
}
async Task<JsonElement> Status(string id, string expected)
{
    for (int i = 0; i < 150; i++)
    {
        var r = await client.CallAsync("axo.session.events.poll", new { sessionId = id, after = 0 });
        if (r.GetProperty("status").GetString() == expected) return r;
        await Task.Delay(50);
    }
    throw new Exception("Session did not become " + expected);
}
async Task<bool> Fails(string method, object p)
{
    try { await client.CallAsync(method, p); return false; } catch (IOException) { return true; }
}
async Task<string[]> Messages(string id)
{
    var r = await client.CallAsync("axo.session.messages", new { sessionId = id, after = 0 });
    return r.GetProperty("messages").EnumerateArray().Select(m => m.GetProperty("text").GetString()!).ToArray();
}
try
{
    if(!live)
    {
        Exception? viewError=null;
        var views=new Thread(()=>
        {
            try
            {
                var application=new App();application.InitializeComponent();
                var settings=new SettingsWindow(client,new Preferences());
                settings.Measure(new System.Windows.Size(740,580));settings.Arrange(new System.Windows.Rect(0,0,740,580));settings.Close();application.Shutdown();
            }
            catch(Exception error){viewError=error;}
        });
        views.SetApartmentState(ApartmentState.STA);views.Start();
        Assert(views.Join(TimeSpan.FromSeconds(15))&&viewError is null,"native Settings and segmented appearance picker compose with the shipped WPF resources" + (viewError is null?"":": "+viewError.Message));
        ParityChecks.Installation(root,Assert);
        var vt=new VtScreen();vt.Resize(12,3);string? reply=null;vt.Reply+=text=>reply=text;
        vt.Feed("hello\r\x1b[2K\x1b[3");vt.Feed("1mworld\x1b[0m\x1b[6n");
        Assert(string.Concat(vt.Visible(0)[0].Select(c=>c.Text)).StartsWith("world")&&reply=="\x1b[1;6R","VT handles split escape sequences, line editing, and cursor-position queries");
        vt.Feed("\x1b[?1049h");vt.Resize(24,5);vt.Feed("alternate\x1b[?1049l");
        Assert(string.Concat(vt.Visible(0)[0].Select(c=>c.Text)).StartsWith("world"),"VT restores the primary screen after an alternate-screen resize");
        vt.Reset();vt.Resize(12,3);vt.Feed("one\r\ntwo\r\nthree\r\nfour");
        Assert(vt.ScrollbackCount==1&&string.Concat(vt.Visible(0)[2].Select(c=>c.Text)).StartsWith("four"),"VT retains scrollback independently of the visible screen");
    }
    daemon = Start(); await Ready();
    if (live)
    {
        var project = await client.CallAsync("axo.workspace.create", new { name = "Live Codex smoke test", directoryPath = workspace });
        var sessionId = project.GetProperty("session").GetProperty("id").GetString()!;
        var snapshot = await client.CallAsync("axo.session.open", new { sessionId });
        var savedThread = snapshot.GetProperty("threadId").GetString();
        Console.WriteLine("Real Codex thread opened.");
        await client.CallAsync("axo.session.prompt", new { sessionId, text = "Reply with exactly AXO_WINDOWS_READY. Do not use tools or modify files." });
        for (var i = 0; i < 180; i++)
        {
            var status = await client.CallAsync("axo.session.events.poll", new { sessionId, after = 0 });
            if (status.GetProperty("status").GetString() == "ready") break;
            if (status.GetProperty("status").GetString() == "needsAttention") throw new Exception("Live smoke unexpectedly requires input: " + status.GetRawText());
            await Task.Delay(500);
        }
        Assert((await Messages(sessionId)).Any(t => t.Trim() == "AXO_WINDOWS_READY"), "real Codex returns a streamed assistant message");
        daemon.Kill(); await daemon.WaitForExitAsync(); daemon.Dispose(); daemon = Start(); await Ready();
        snapshot = await client.CallAsync("axo.session.open", new { sessionId });
        Assert(snapshot.GetProperty("threadId").GetString() == savedThread, "real Codex resumes its saved thread after daemon restart");
        await client.CallAsync("axo.session.prompt", new { sessionId, text = "What exact marker did I ask you to reply with in my previous message? Reply only with that marker. Do not use tools." });
        for (var i = 0; i < 180; i++)
        {
            var status = await client.CallAsync("axo.session.events.poll", new { sessionId, after = 0 });
            if (status.GetProperty("status").GetString() == "ready") break;
            await Task.Delay(500);
        }
        Assert((await Messages(sessionId)).Count(t => t.Trim() == "AXO_WINDOWS_READY") >= 2, "resumed Codex conversation retains context");
        await client.CallAsync("axo.windows.settings.save", new { codexFullAccess = true, computerUseEnabled = true });
        await client.CallAsync("axo.session.prompt", new { sessionId, text = "Create axo-smoke.txt in this workspace with exactly AXO_WINDOWS_FILE_OK followed by a newline. Use tools to create the file and then run a shell command to read it back. Do not change any other files or access anything outside this workspace. Reply with the file contents." });
        var commandCompleted = false;
        for (var i = 0; i < 240; i++)
        {
            var status = await client.CallAsync("axo.session.events.poll", new { sessionId, after = 0 });
            foreach (var envelope in status.GetProperty("events").EnumerateArray())
            {
                var notification = envelope.GetProperty("event");
                if (notification.GetProperty("method").GetString() == "item/completed")
                {
                    var item = notification.GetProperty("params").GetProperty("item");
                    if (item.GetProperty("type").GetString() == "commandExecution" && item.TryGetProperty("exitCode", out var exit) && exit.ValueKind == JsonValueKind.Number && exit.GetInt32() == 0) commandCompleted = true;
                }
            }
            if (status.GetProperty("status").GetString() == "ready") break;
            if (status.GetProperty("status").GetString() == "needsAttention") throw new Exception("Live tool smoke needs input: " + status.GetProperty("pendingRequests").GetRawText());
            await Task.Delay(500);
        }
        var smokeFile = Path.Combine(workspace, "axo-smoke.txt");
        Assert(File.Exists(smokeFile) && File.ReadAllText(smokeFile).Trim() == "AXO_WINDOWS_FILE_OK", "real Codex creates a file inside its Windows workspace");
        Assert(commandCompleted, "real Codex completes a Windows shell tool call");
        await ComputerChecks.LiveAsync(client, sessionId, Assert);
        Console.WriteLine("Live Codex smoke test passed.");
        return 0;
    }
    var n = await client.CallAsync("axo.protocol.negotiate", new { protocolVersion = 1 });
    Assert(n.GetProperty("agent").GetString() == "codex", "Windows negotiation reports Codex");
    Assert((await client.CallAsync("axo.protocol.negotiate",new{protocolVersion=2})).GetProperty("protocolVersion").GetInt32()==2,"Windows supports the shared protocol version alongside the first preview's version");
    Assert(await Fails("axo.protocol.negotiate", new { protocolVersion = 500 }), "unsupported protocol is rejected");
    Assert(await Fails("axo.session.pi.restart.force.v2", new { }), "Pi-only method is not advertised or implemented");
    using (var duplicate = Start())
    {
        await duplicate.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
        Assert(duplicate.ExitCode != 0, "duplicate daemon cannot claim the same pipe");
    }
    var subscription=(await client.CallAsync("axo.session.subscribe",new{includeTerminalOutput=false})).GetProperty("subscriptionId").GetString();
    var change=client.CallAsync("axo.session.events.next",new{subscriptionId=subscription,timeoutMs=10000,maxEvents=128});
    var created = await client.CallAsync("axo.workspace.create", new { name = "Fixture workspace", directoryPath = workspace });
    Assert((await change).GetProperty("events").EnumerateArray().Any(e=>e.GetProperty("type").GetString() is "session.snapshot" or "workspace.changed"),"catalog long-poll wakes on workspace creation");
    var id = created.GetProperty("session").GetProperty("id").GetString()!;
    var workspaceId = created.GetProperty("workspace").GetProperty("workspaceId").GetString()!;
    Assert(created.GetProperty("session").GetProperty("initialPwd").GetString() == workspace, "workspace paths preserve spaces and Unicode");
    var opened = await client.CallAsync("axo.session.open", new { sessionId = id });
    var threadId = opened.GetProperty("threadId").GetString();
    Assert(!string.IsNullOrEmpty(threadId), "session opens a real child process and records its thread ID");
    var pty=await client.CallAsync("axo.terminal.create",new{sessionId=id});
    int shellId=pty.GetProperty("shellId").GetInt32(),ptyPid=pty.GetProperty("processId").GetInt32();ulong input=0,output=0;
    async Task PumpTerminal()
    {
        var snapshot=await client.CallAsync("axo.terminal.replay",new{sessionId=id,shellId});
        foreach(var chunk in snapshot.GetProperty("chunks").EnumerateArray())
        {
            var seq=chunk.GetProperty("sequence").GetUInt64();if(seq<output)continue;output=seq+1;
            var text=System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(chunk.GetProperty("data").GetString()!));
            if(text.Contains("\x1b[6n"))await client.CallAsync("axo.terminal.input",new{sessionId=id,shellId,sequence=input++,data=Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("\x1b[1;1R"))});
        }
    }
    for(int i=0;i<20;i++){await PumpTerminal();await Task.Delay(100);}
    await client.CallAsync("axo.terminal.resize",new{sessionId=id,shellId,rows=26,columns=90});
    var command=Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("Set-Content conpty-smoke.txt AXO_CONPTY_OK; Get-Content conpty-smoke.txt\r"));
    var commandSequence=input++;
    await client.CallAsync("axo.terminal.input",new{sessionId=id,shellId,sequence=commandSequence,data=command});
    await client.CallAsync("axo.terminal.input",new{sessionId=id,shellId,sequence=commandSequence,data=command});
    for(int i=0;i<80&&!File.Exists(Path.Combine(workspace,"conpty-smoke.txt"));i++){await PumpTerminal();await Task.Delay(100);}
    Assert(File.Exists(Path.Combine(workspace,"conpty-smoke.txt"))&&File.ReadAllText(Path.Combine(workspace,"conpty-smoke.txt")).Trim()=="AXO_CONPTY_OK","embedded ConPTY runs PowerShell in the Unicode workspace");
    var reattached=await new DaemonClient(pipe).CallAsync("axo.terminal.create",new{sessionId=id});
    Assert(reattached.GetProperty("processId").GetInt32()==ptyPid&&reattached.GetProperty("chunks").GetArrayLength()>0,"terminal reattachment replays output and preserves its process");
    var terminalOutput=string.Concat(reattached.GetProperty("chunks").EnumerateArray().Select(c=>System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(c.GetProperty("data").GetString()!))));
    Assert(terminalOutput.Contains("AXO_CONPTY_OK")&&terminalOutput.Contains("PS "),"shell prompt and command output use ConPTY even when the daemon's stdio is redirected");
    await client.CallAsync("axo.session.prompt", new { sessionId = id, text = "hello\nsecond line" });
    await Status(id, "ready");
    Assert((await Messages(id)).Contains("Echo: hello\nsecond line"), "app-server notifications become durable chat messages");
    Assert(await Fails("axo.session.prompt", new { sessionId = id, text = " " }), "empty message is rejected");
    Assert(await Fails("axo.session.open", new { sessionId = id, typo = true }), "misspelled parameters are rejected");
    await client.CallAsync("axo.session.prompt", new { sessionId = id, text = "wait" });
    await Status(id, "working");
    Assert(await Fails("axo.session.prompt", new { sessionId = id, text = "second concurrent turn", delivery = "turn" }), "busy session refuses an explicit competing turn");
    var newClient = new DaemonClient(pipe);
    var list = await newClient.CallAsync("axo.session.list");
    Assert(list.GetProperty("sessions")[0].GetProperty("status").GetString() == "working", "session keeps working after client reconnection");
    await client.CallAsync("axo.session.interrupt", new { sessionId = id }); await Status(id, "ready");
    Assert(true, "Stop interrupts the active Codex turn");
    await client.CallAsync("axo.session.prompt", new { sessionId = id, text = "approval" });
    var waiting = await Status(id, "needsAttention");
    var requestId = waiting.GetProperty("pendingRequests")[0].GetProperty("id").GetRawText();
    await client.CallAsync("axo.session.approval.respond", new { sessionId = id, requestId, decision = "decline" }); await Status(id, "ready");
    Assert((await Messages(id)).Contains("Approval: decline"), "approval decision is delivered to the correct app-server request");
    Assert(await Fails("axo.session.approval.respond", new { sessionId = id, requestId, decision = "accept" }), "stale approval cannot be reused");
    var relayState=await client.CallAsync("axo.relay.status");
    Assert(relayState.GetProperty("hostKind").GetString()=="windows"&&relayState.GetProperty("state").GetString()=="disconnected","unpaired relay identifies this PC without connecting");
    await client.CallAsync("axo.relay.link",new{code="ABCD-EFGH"});
    await relay!.WaitAsync(()=>relay.Registration.ValueKind==JsonValueKind.Object,"Relay did not register after pairing");
    await relay.WaitAsync(()=>relay.Messages(id).Contains("Approval: decline"),"Relay did not upload the Codex transcript");
    Assert(relay.Registration.GetProperty("hostKind").GetString()=="windows","pairing and authenticated WebSocket registration identify Windows");
    Assert(relay.Messages(id).Contains("Echo: hello\nsecond line"),"Codex messages upload through the existing relay transcript format");
    var target=new{hostId=relay.Registration.GetProperty("hostId").GetString(),hostGeneration=relay.Registration.GetProperty("hostGeneration").GetString()};
    var remote=await relay.CallAsync("axo.remote.workspace.list",new{target});
    Assert(remote.GetProperty("result").GetProperty("workspaces")[0].GetProperty("workspaceId").GetString()==workspaceId,"remote clients can list Windows workspaces");
    var commandId=Guid.NewGuid().ToString();
    remote=await relay.CallAsync("axo.remote.session.prompt",new{target,sessionId=id,text="relay hello",commandId});
    Assert(remote.TryGetProperty("result",out _),"relay routes a remote prompt to the Codex agent");
    await Status(id,"ready");
    await relay.CallAsync("axo.remote.session.prompt",new{target,sessionId=id,text="relay hello",commandId});
    Assert((await Messages(id)).Count(m=>m=="Echo: relay hello")==1,"retrying a remote command ID never starts a duplicate Codex turn");
    await relay.WaitAsync(()=>relay.Messages(id).Contains("Echo: relay hello"),"Remote Codex reply was not synced");
    await relay.CallAsync("axo.remote.session.prompt",new{target,sessionId=id,text="approval",commandId=Guid.NewGuid().ToString()});
    await Status(id,"needsAttention");
    await relay.WaitAsync(()=>!relay.Questions.IsEmpty,"Codex approval did not reach the relay");
    relay.Questions.TryPeek(out var question);
    remote=await relay.CallAsync("axo.elicitation.resolve",RelayFixture.SignedAnswer(target,question.GetProperty("id").GetString()!,"decline"));
    Assert(remote.TryGetProperty("result",out _),"remote approval names and resolves the exact Codex permission request");
    await Status(id,"ready");
    remote=await relay.CallAsync("axo.elicitation.resolve",RelayFixture.SignedAnswer(target,question.GetProperty("id").GetString()!,"accept"));
    Assert(remote.TryGetProperty("error",out _),"resolved remote approval cannot authorize a later request");
    await ParityChecks.Controls(client,id,workspace,Assert);
    await ComputerChecks.RunAsync(client, daemonPath, pipe, id, relay, target, Assert);
    var stopCommand=Guid.NewGuid().ToString();
    await relay.CallAsync("axo.remote.session.prompt",new{target,sessionId=id,text="wait",commandId=stopCommand});await Status(id,"working");
    var queuedRemoteCommand=Guid.NewGuid().ToString();
    await relay.CallAsync("axo.remote.session.prompt",new{target,sessionId=id,text="remote queued marker",commandId=queuedRemoteCommand});
    remote=await relay.CallAsync("axo.remote.session.stop",new{target,sessionId=id,commandIds=new[]{queuedRemoteCommand}});
    Assert(!remote.GetProperty("result").GetProperty("stopped").GetBoolean(),"a queued remote command cannot stop the preceding turn");
    remote=await relay.CallAsync("axo.remote.session.stop",new{target,sessionId=id,commandIds=new[]{Guid.NewGuid().ToString()}});
    Assert(!remote.GetProperty("result").GetProperty("stopped").GetBoolean(),"remote Stop cannot interrupt a turn the client never saw");
    remote=await relay.CallAsync("axo.remote.session.stop",new{target,sessionId=id,commandIds=new[]{stopCommand}});
    Assert(remote.GetProperty("result").GetProperty("stopped").GetBoolean(),"remote Stop interrupts its own Codex turn");await Status(id,"ready");
    var catalog=await client.CallAsync("axo.session.events.next",new{subscriptionId=subscription,timeoutMs=1,maxEvents=128});
    Assert(catalog.GetProperty("events").EnumerateArray().All(e=>e.GetProperty("type").GetString() is not "pi.event" and not "terminal.output"),"catalog subscriptions exclude terminal and token streams");
    await client.CallAsync("axo.session.unsubscribe",new{subscriptionId=subscription});
    await client.CallAsync("axo.session.prompt", new { sessionId = id, text = "flood" }); await Status(id, "ready");
    var flood = await client.CallAsync("axo.session.events.poll", new { sessionId = id, after = 0 });
    Assert(flood.GetProperty("reset").GetBoolean() && flood.GetProperty("events").GetArrayLength() == 200, "bounded event journal reports lost cursor and paginates recovery");
    Assert((await Messages(id)).Contains("flood complete"), "completed message survives event journal overflow");
    await client.CallAsync("axo.session.rename", new { sessionId = id, name = "Renamed session" });
    await client.CallAsync("axo.session.prompt", new { sessionId = id, text = "crash" }); await Status(id, "unavailable");
    var recovered = await client.CallAsync("axo.session.open", new { sessionId = id });
    Assert(recovered.GetProperty("threadId").GetString() == threadId, "crashed Codex process resumes the existing thread");
    var agentPid = recovered.GetProperty("agentProcessId").GetInt32();
    await client.CallAsync("axo.session.prompt",new{sessionId=id,text="wait"});await Status(id,"working");
    await client.CallAsync("axo.session.prompt",new{sessionId=id,text="restart queue marker",delivery="followUp"});
    var beforeRestart=await client.CallAsync("axo.session.open",new{sessionId=id});
    daemon.Kill(); await daemon.WaitForExitAsync(); daemon.Dispose();
    try
    {
        using var child = Process.GetProcessById(agentPid);
        await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
    }
    catch (ArgumentException) { /* Windows already removed the process. */ }
    Assert(true, "Windows job terminates the agent when its daemon is killed");
    try{using var terminalProcess=Process.GetProcessById(ptyPid);await terminalProcess.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));}catch(ArgumentException){}
    Assert(true,"Windows job terminates the embedded shell when its daemon is killed");
    daemon = Start(); await Ready();
    recovered = await client.CallAsync("axo.session.open", new { sessionId = id });
    await relay.WaitAsync(()=>relay.Connections>=2,"Relay did not reconnect after daemon restart");
    Assert(relay.Registration.GetProperty("hostId").GetString()==target.hostId&&relay.Registration.GetProperty("hostGeneration").GetString()!=target.hostGeneration,"DPAPI credential and stable host identity survive restart with a fresh generation");
    Assert(recovered.GetProperty("threadId").GetString() == threadId, "daemon restart preserves Codex thread identity");
    Assert(recovered.GetProperty("name").GetString() == "Renamed session", "session name survives daemon restart");
    Assert((await Messages(id)).Contains("Echo: hello\nsecond line"), "chat history survives daemon restart");
    for(int attempt=0;attempt<150 && !(await Messages(id)).Contains("Echo: restart queue marker");attempt++)await Task.Delay(50);
    Assert((await Messages(id)).Count(m=>m=="Echo: restart queue marker")==1,"a queued follow-up survives daemon restart and is delivered once");
    var preferences=await client.CallAsync("axo.session.model",new{sessionId=id});
    Assert(preferences.GetProperty("model").GetString()=="fixture"&&preferences.GetProperty("effort").GetString()=="high","model and reasoning preferences survive restart");
    Assert(recovered.GetProperty("layout").GetRawText()==beforeRestart.GetProperty("layout").GetRawText(),"terminal layout and shell identity survive daemon restart");
    await client.CallAsync("axo.session.close", new { sessionId = id });
    list = await client.CallAsync("axo.session.list");
    Assert(list.GetProperty("sessions").GetArrayLength() == 0, "closing session archives it and stops its agent");
    await client.CallAsync("axo.session.reopen", new { sessionId = id });
    Assert((await Messages(id)).Contains("flood complete"), "reopening archived session retains history");
    var second = await client.CallAsync("axo.workspace.session.create", new { workspaceId });
    Assert(second.GetProperty("id").GetString() != id, "sessions receive distinct Axo UUIDs");
    // A genuine native PowerShell window is opened, then closed by session shutdown.
    var terminal = await client.CallAsync("axo.terminal.open", new { sessionId = id });
    Assert(terminal.GetProperty("processId").GetInt32() > 0, "daemon opens an interactive terminal in the workspace");
    await client.CallAsync("axo.session.close", new { sessionId = id });
    await client.CallAsync("axo.daemon.stop");
    await daemon.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
    Assert(daemon.ExitCode == 0, "graceful shutdown acknowledges its request and exits cleanly");
    Console.WriteLine($"All {assertions} Windows integration checks passed.");
}
finally
{
    if (daemon is not null) { if (!daemon.HasExited) { daemon.Kill(entireProcessTree: true); await daemon.WaitForExitAsync(); } daemon.Dispose(); }
    // Tests intentionally keep a diagnostic catalog on failure; caller owns scratch cleanup.
    Console.WriteLine("Test catalog: " + root);
}
return 0;
