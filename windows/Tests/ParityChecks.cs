using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Axo;

static class ParityChecks
{
    static async Task<JsonElement> Question(DaemonClient client)
    {
        for(int n=0;n<150;n++){var all=await client.CallAsync("axo.elicitation.list");if(all.GetProperty("elicitations").GetArrayLength()>0)return all.GetProperty("elicitations")[0].Clone();await Task.Delay(25);}throw new Exception("Input form did not appear");
    }
    static async Task<JsonElement> Seal(JsonElement question,string? id=null)
    {
        var start=new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"seal_fixture.exe")){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true};
        using var process=Process.Start(start)!;
        await process.StandardInput.WriteAsync(JsonSerializer.Serialize(new {id=id??question.GetProperty("id").GetString(),key=question.GetProperty("input").GetProperty("key").GetString(),values=new {values=new {f0="fixture secret phrase 5294",f1="fixture-password-5294"}}}));process.StandardInput.Close();
        string text=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();return JsonDocument.Parse(text).RootElement.Clone();
    }
    public static async Task SecureInput(DaemonClient client,RelayFixture relay,object target,string session,int pid,long window,string ready,Action<bool,string> assert)
    {
        object request=new {sessionId=session,tool="request_input",args=new {pid,window_id=window,fields=new[]{new{kind="text",label="Fixture input"},new{kind="password",label="Fixture password"}}},timeoutMs=15000};
        File.Delete(ready+".filled");
        var waiting=client.CallAsync("axo.computer.call",request);
        var question=await Question(client);string id=question.GetProperty("id").GetString()!;
        assert(question.GetProperty("kind").GetString()=="input" && question.GetProperty("input").GetProperty("fields").GetArrayLength()==2,"Windows reads and presents the target form with the shared input protocol");
        bool refused=false;try{await client.CallAsync("axo.elicitation.resolve",new {elicitationId=id,action="accept",values=new{wrong="value"}});}catch(IOException){refused=true;}
        assert(refused && !waiting.IsCompleted,"malformed field answers leave the form pending and fill nothing");
        var sealedValue=await Seal(question,"wrong-request");
        var reply=await relay.CallAsync("axo.elicitation.resolve",RelayFixture.SignedAnswer(target,id,"accept",sealedValue));
        assert(reply.TryGetProperty("error",out _) && !waiting.IsCompleted,"a device-signed ciphertext for another request cannot be opened");
        reply=await relay.CallAsync("axo.elicitation.resolve",new{target,elicitationId=id,action="accept",@sealed=await Seal(question)});
        assert(reply.TryGetProperty("error",out _) && !waiting.IsCompleted,"a sealed answer without a device signature cannot authorize filling");
        await File.WriteAllTextAsync(ready+".change","change");await Task.Delay(200);
        reply=await relay.CallAsync("axo.elicitation.resolve",RelayFixture.SignedAnswer(target,id,"accept",await Seal(question)));
        var changed=await waiting;
        assert(changed.GetProperty("isError").GetBoolean() && !File.Exists(ready+".filled"),"a changed target window refuses the approved fill");
        waiting=client.CallAsync("axo.computer.call",request);question=await Question(client);id=question.GetProperty("id").GetString()!;
        reply=await relay.CallAsync("axo.elicitation.resolve",RelayFixture.SignedAnswer(target,id,"accept",await Seal(question)));
        var result=await waiting;
        assert(reply.TryGetProperty("result",out _) && !result.GetProperty("isError").GetBoolean() && !result.ToString().Contains("5294"),"the agent receives only a receipt after a signed sealed fill");
        for(int n=0;n<100 && !File.Exists(ready+".filled");n++)await Task.Delay(25);
        using(var observed=JsonDocument.Parse(await File.ReadAllTextAsync(ready+".filled")))assert(observed.RootElement.GetProperty("plain").GetBoolean() && observed.RootElement.GetProperty("password").GetBoolean(),"the independent fixture verifies both plain and password values without exposing them to the agent");
        var read=await client.CallAsync("axo.computer.call",new{sessionId=session,tool="get_window_state",args=new{pid,window_id=window,include_screenshot=true}});
        assert(!read.ToString().Contains("5294") && !read.GetProperty("content").EnumerateArray().Any(c=>c.GetProperty("type").GetString()=="image"),"later computer reads redact phrases and suppress screenshots that could reveal filled secrets");
        reply=await relay.CallAsync("axo.elicitation.resolve",RelayFixture.SignedAnswer(target,id,"accept",await Seal(question)));
        assert(reply.TryGetProperty("error",out _),"a consumed sealed answer cannot be replayed");
        waiting=client.CallAsync("axo.computer.call",request);question=await Question(client);
        await client.CallAsync("axo.windows.settings.save",new{computerUseEnabled=false,codexFullAccess=true});await client.CallAsync("axo.windows.settings.save",new{computerUseEnabled=true,codexFullAccess=true});
        assert((await waiting).GetProperty("isError").GetBoolean(),"disabling and re-enabling computer use cancels pending secret input");
    }

    public static async Task Controls(DaemonClient client,string session,string workspace,Action<bool,string> assert)
    {
        async Task Ready(){for(int n=0;n<150;n++){if((await client.CallAsync("axo.session.events.poll",new{sessionId=session})).GetProperty("status").GetString()=="ready")return;await Task.Delay(25);}throw new Exception("Control test did not settle");}
        async Task<string> History()=> (await client.CallAsync("axo.session.messages",new{sessionId=session})).ToString();
        var models=await client.CallAsync("axo.session.models",new{sessionId=session});assert(models.GetProperty("models").GetArrayLength()==1,"model options come from Codex model/list");
        bool invalid=false;try{await client.CallAsync("axo.session.model.set",new{sessionId=session,model="fixture",effort="invalid"});}catch(IOException){invalid=true;}assert(invalid,"unsupported reasoning effort is refused");
        await client.CallAsync("axo.session.model.set",new{sessionId=session,model="fixture",effort="high"});
        string image=Path.Combine(workspace,"attachment.png");await File.WriteAllBytesAsync(image,Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="));
        await client.CallAsync("axo.session.prompt",new{sessionId=session,text="inspect-controls",attachments=new[]{image}});await Ready();
        string history=await History();assert(history.Contains("high")&&history.Contains("fixture")&&history.Contains("localImage"),"model, reasoning and a snapshotted image reach turn/start");
        await client.CallAsync("axo.session.prompt",new{sessionId=session,text="wait"});
        await client.CallAsync("axo.session.prompt",new{sessionId=session,text="steer marker",delivery="steer"});await Ready();assert((await History()).Contains("Steered: steer marker"),"steering reaches the observed active Codex turn");
        await client.CallAsync("axo.session.prompt",new{sessionId=session,text="wait"});
        var queued=await client.CallAsync("axo.session.prompt",new{sessionId=session,text="queued marker",delivery="followUp"});
        assert(queued.GetProperty("queued").GetBoolean() && !(await History()).Contains("Echo: queued marker"),"follow-up waits durably while the active turn runs");
        var removed=await client.CallAsync("axo.session.prompt",new{sessionId=session,text="removed marker",delivery="followUp"});
        await client.CallAsync("axo.session.queue.cancel",new{sessionId=session,commandId=removed.GetProperty("commandId").GetString()});
        await client.CallAsync("axo.session.prompt",new{sessionId=session,text="interrupt marker",delivery="interrupt"});
        for(int n=0;n<150 && !(await History()).Contains("Echo: queued marker");n++)await Task.Delay(30);
        history=await History();assert(history.IndexOf("Echo: interrupt marker",StringComparison.Ordinal)<history.IndexOf("Echo: queued marker",StringComparison.Ordinal) && !history.Contains("Echo: removed marker"),"interrupt-and-send takes priority; queued work follows and a removed message never runs");
        await Ready();
        var first=await client.CallAsync("axo.terminal.create",new{sessionId=session});var second=await client.CallAsync("axo.shell.create",new{sessionId=session});
        int a=first.GetProperty("shellId").GetInt32(),b=second.GetProperty("shellId").GetInt32();
        assert(a!=b,"splitting creates two independently identified ConPTY shells");
        object layout=new{kind="split",id=Guid.NewGuid().ToString(),direction="down",ratio=.35,first=new{kind="pane",shellId=a},second=new{kind="pane",shellId=b}};
        await client.CallAsync("axo.session.layout.set",new{sessionId=session,layout});
        var snapshot=await client.CallAsync("axo.session.open",new{sessionId=session});assert(snapshot.GetProperty("layout").GetProperty("direction").GetString()=="down","the daemon persists the shared Mac layout format");
        await client.CallAsync("axo.terminal.close",new{sessionId=session,shellId=b});snapshot=await client.CallAsync("axo.session.open",new{sessionId=session});assert(snapshot.GetProperty("shells").GetArrayLength()==1&&snapshot.GetProperty("layout").GetProperty("kind").GetString()=="pane","closing one pane prunes the split and leaves the other shell running");
    }
    public static void Installation(string scratch,Action<bool,string> assert)
    {
        string source=Path.Combine(scratch,"package");Directory.CreateDirectory(source);
        foreach(string file in new[]{"Axo.exe","Axo.dll","axod.exe","Axo.runtimeconfig.json"})File.WriteAllText(Path.Combine(source,file),"inert installer fixture "+file);
        var files=Directory.GetFiles(source).Select(path=>new{path=Path.GetFileName(path),bytes=new FileInfo(path).Length,sha256=Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)))}).ToArray();
        File.WriteAllText(Path.Combine(source,"build-manifest.json"),JsonSerializer.Serialize(new{version="0.39.0",axodBuild=63,gitCommit=new string('a',40),files}));
        string root=Path.Combine(scratch,"installed");string executable=Installer.Install(source,root);assert(File.Exists(executable),"per-user installer verifies a package and stages a versioned release");
        File.AppendAllText(Path.Combine(source,"Axo.dll"),"tampered");bool refused=false;try{Installer.Install(source,root);}catch(IOException){refused=true;}assert(refused && File.Exists(executable),"a corrupt update leaves the existing installed release intact");
        string zip=Path.Combine(scratch,"unsafe.zip");using(var archive=ZipFile.Open(zip,ZipArchiveMode.Create)){using var writer=new StreamWriter(archive.CreateEntry("../escaped.txt").Open());writer.Write("escape");}
        refused=false;try{Installer.Install(zip,root);}catch(IOException){refused=true;}assert(refused&&!File.Exists(Path.Combine(scratch,"escaped.txt")),"the updater rejects archive path traversal before installing");
    }
}
