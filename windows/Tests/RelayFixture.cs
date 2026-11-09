using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

/// <summary>Isolated HTTP + WebSocket relay. Drives the actual Windows daemon through
/// the production v2 wire format, including credential authentication and transcript sync.</summary>
sealed class RelayFixture : IAsyncDisposable
{
    readonly WebApplication app;
    readonly SemaphoreSlim sendLock = new(1,1);
    readonly ConcurrentDictionary<string,TaskCompletionSource<JsonElement>> calls=[];
    readonly ConcurrentDictionary<string,List<string>> records=[];
    WebSocket? socket;
    int callId;
    string credential="",credentialId="";
    public string Origin {get;private set;}="";
    public JsonElement Registration {get;private set;}
    public JsonElement Manifest {get;private set;}
    public int Connections {get;private set;}
    public ConcurrentQueue<JsonElement> Progress {get;}=[];
    public ConcurrentQueue<JsonElement> Questions {get;}=[];
    public const string Account="0f3af604-5e8d-4bb6-9556-111122223333";
    public ConcurrentDictionary<string,byte[]> Assets {get;}=[];
    RelayFixture(WebApplication app){this.app=app;}
    public static async Task<RelayFixture> StartAsync()
    {
        var builder=WebApplication.CreateBuilder();builder.Logging.ClearProviders();builder.WebHost.UseSetting("urls","http://127.0.0.1:0");
        var app=builder.Build();var fixture=new RelayFixture(app);app.UseWebSockets();
        app.MapPost("/api/v1/host-pairings/redeem",async(HttpContext context)=>
        {
            using var doc=await JsonDocument.ParseAsync(context.Request.Body);var p=doc.RootElement;
            if(p.GetProperty("code").GetString()!="ABCD-EFGH"||p.GetProperty("hostKind").GetString()!="windows"){context.Response.StatusCode=400;return;}
            fixture.credential=p.GetProperty("credential").GetString()!;fixture.credentialId=p.GetProperty("credentialId").GetString()!;
            await context.Response.WriteAsJsonAsync(new{linked=true,accountId=Account,hostId=p.GetProperty("hostId").GetString(),hostGeneration=p.GetProperty("hostGeneration").GetString(),credentialId=fixture.credentialId,linkedAt=DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'",System.Globalization.CultureInfo.InvariantCulture)});
        });
        app.MapGet("/api/v1/accounts/{account}/hosts/{host}/daemon",async(HttpContext context)=>
        {
            if(context.Request.Headers.Authorization!="Bearer "+fixture.credential||context.Request.Headers["X-Axo-Credential-Id"]!=fixture.credentialId){context.Response.StatusCode=401;return;}
            using var ws=await context.WebSockets.AcceptWebSocketAsync();fixture.socket=ws;fixture.Connections++;
            try{await fixture.ReadAsync(ws,context.RequestAborted);}catch(Exception e)when(e is WebSocketException or OperationCanceledException or IOException){}
        });
        app.MapPut("/api/v1/accounts/{account}/hosts/{host}/assets/{hash}",async(HttpContext context,string account,string host,string hash)=>
        {
            if(account!=Account||context.Request.Headers.Authorization!="Bearer "+fixture.credential||context.Request.Headers["X-Axo-Credential-Id"]!=fixture.credentialId){context.Response.StatusCode=401;return;}
            using var body=new MemoryStream();await context.Request.Body.CopyToAsync(body);var bytes=body.ToArray();
            if(Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes))!=hash){context.Response.StatusCode=400;return;}
            fixture.Assets[hash]=bytes;context.Response.StatusCode=201;
        });
        app.MapGet("/api/v1/accounts/{account}/hosts/{host}/assets/{hash}",async(HttpContext context,string account,string host,string hash)=>{
            if(account!=Account || context.Request.Headers.Authorization!="Bearer "+fixture.credential){context.Response.StatusCode=401;return;}
            if(!fixture.Assets.TryGetValue(hash,out var bytes)){context.Response.StatusCode=404;return;}context.Response.ContentLength=bytes.Length;await context.Response.Body.WriteAsync(bytes);
        });
        await app.StartAsync();fixture.Origin=app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single();return fixture;
    }
    async Task ReadAsync(WebSocket ws,CancellationToken token)
    {
        var buffer=new byte[65536];
        while(ws.State==WebSocketState.Open)
        {
            using var message=new MemoryStream();WebSocketReceiveResult frame;
            do{frame=await ws.ReceiveAsync(buffer,token);if(frame.MessageType==WebSocketMessageType.Close)return;message.Write(buffer,0,frame.Count);if(message.Length>8*1024*1024)throw new IOException("Oversized fixture message");}while(!frame.EndOfMessage);
            using var doc=JsonDocument.Parse(message.ToArray());var root=doc.RootElement;
            if(!root.TryGetProperty("method",out var method))
            {if(root.TryGetProperty("id",out var id)&&calls.TryRemove(id.GetString()!,out var waiting))waiting.TrySetResult(root.Clone());continue;}
            var p=root.GetProperty("params");object reply=new{};
            switch(method.GetString())
            {
                case "axo.protocol.negotiate":reply=new{protocolVersion=2};break;
                case "axo.host.register":
                    Registration=p.Clone();
                    // Match the production closed capability vocabulary, rather than accepting
                    // a new capability production would refuse.
                    if(p.GetProperty("hostKind").GetString()!="windows"||p.GetProperty("capabilities").EnumerateArray().Any(c=>!new[]{"agent.pi","terminal.pty","workspace.filesystem"}.Contains(c.GetProperty("id").GetString())))throw new IOException("Invalid production registration");
                    reply=new{registered=true};break;
                case "axo.host.sync":
                    Manifest=p.Clone();
                    reply=new{round=p.GetProperty("round").GetInt64(),applied=true,sessions=p.GetProperty("sessions").EnumerateArray().Select(s=>
                    {
                        var id=s.GetProperty("sessionId").GetString()!;var upload=s.GetProperty("upload");var held=records.GetOrAdd(id,_=>[]);
                        lock(held){if(upload.ValueKind==JsonValueKind.Object&&held.Count==upload.GetProperty("count").GetInt32()&&held.Count>0)return new{sessionId=id,state="synced",epoch=1,count=held.Count,chain=upload.GetProperty("chain").GetString()};}
                        return new{sessionId=id,state="unknown",epoch=1,count=0,chain=(string?)null};
                    }).ToArray()};break;
                case "axo.host.session.append":
                    var sessionId=p.GetProperty("sessionId").GetString()!;var lines=records.GetOrAdd(sessionId,_=>[]);int from=p.GetProperty("from").GetInt32();
                    lock(lines){foreach(var r in p.GetProperty("records").EnumerateArray()){if(lines.Count>=from)lines[from-1]=r.GetProperty("line").GetString()!;else lines.Add(r.GetProperty("line").GetString()!);from++;}}
                    reply=new{outcome="committed",epoch=1,count=from-1};break;
                case "axo.host.session.progress":Progress.Enqueue(p.Clone());break;
                case "axo.elicitation.requested":Questions.Enqueue(p.Clone());break;
                case "axo.host.heartbeat":reply=new{ok=true};break;
            }
            if(root.TryGetProperty("id",out var requestId))await SendAsync(ws,new{jsonrpc="2.0",id=requestId.Clone(),result=reply});
        }
    }
    async Task SendAsync(WebSocket ws,object value)
    {
        await sendLock.WaitAsync();try{await ws.SendAsync(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value)),WebSocketMessageType.Text,true,CancellationToken.None);}finally{sendLock.Release();}
    }
    public async Task<JsonElement> CallAsync(string method,object parameters)
    {
        var id="remote-"+Interlocked.Increment(ref callId);var result=new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);calls[id]=result;
        await SendAsync(socket??throw new IOException("No daemon connection"),new{jsonrpc="2.0",id,method,@params=parameters});
        try{return await result.Task.WaitAsync(TimeSpan.FromSeconds(15));}finally{calls.TryRemove(id,out _);}
    }
    public static object SignedAnswer(object target,string id,string action,JsonElement? sealedValue=null)
    {
        using var key=System.Security.Cryptography.ECDsa.Create(System.Security.Cryptography.ECCurve.NamedCurves.nistP256);
        var point=key.ExportParameters(false).Q;var publicKey=new byte[65];publicKey[0]=4;point.X!.CopyTo(publicKey,1);point.Y!.CopyTo(publicKey,33);
        string digest=sealedValue is JsonElement s?Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(s.GetProperty("enc").GetString()+"\n"+s.GetProperty("ciphertext").GetString()))):"";
        byte[] signature=key.SignData(Encoding.UTF8.GetBytes($"axo-answer/v1\n{id}\n{action}\n{digest}"),System.Security.Cryptography.HashAlgorithmName.SHA256,System.Security.Cryptography.DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        return new {target,elicitationId=id,action,@sealed=sealedValue,device=new {key=Convert.ToBase64String(publicKey),name="Isolated Windows fixture",signature=Convert.ToBase64String(signature)}};
    }
    public string[] Messages(string id)
    {
        if(!records.TryGetValue(id,out var list))return[];
        lock(list)return list.Select(line=>{using var doc=JsonDocument.Parse(line);return doc.RootElement.GetProperty("message").GetProperty("content")[0].GetProperty("text").GetString()!;}).ToArray();
    }
    public async Task WaitAsync(Func<bool> condition,string failure)
    {
        for(int i=0;i<150;i++){if(condition())return;await Task.Delay(100);}throw new Exception(failure);
    }
    public async ValueTask DisposeAsync(){socket?.Abort();await app.StopAsync();await app.DisposeAsync();}
}
