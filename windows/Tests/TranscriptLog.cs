using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

/// <summary>The fixture's committed pi/3 copy, including real chains and rewrite fencing.</summary>
sealed class TranscriptLog
{
    public List<string> Lines { get; } = [];
    readonly List<string> hashes = [];
    readonly List<string> chains = [];
    public long Epoch { get; private set; } = 1;
    public long Round { get; set; }
    public string? Chain(int position) => position >= 0 && position < chains.Count ? chains[position] : null;
    public bool Known => chains.Count != 0;

    static string Digest(string tag, string text) => "sha256:" + Convert.ToHexStringLower(
        SHA256.HashData(Encoding.UTF8.GetBytes("axo/pi3/" + tag + "\n" + text)));

    public object Append(JsonElement parameters)
    {
        int from = parameters.GetProperty("from").GetInt32();
        if (parameters.GetProperty("epoch").GetInt64() != Epoch || from != Lines.Count + 1)
            return new { outcome = "conflict", epoch = Epoch, count = Lines.Count };
        string headerHash = Known ? chains[0] : "";
        if (from == 1)
        {
            var header = parameters.GetProperty("header").GetString()!;
            var digest = Digest("transcript", header);
            if (Known && chains[0] != digest) return new { outcome = "conflict", epoch = Epoch, count = Lines.Count };
            headerHash = digest;
        }
        var byId = new Dictionary<string, string>(StringComparer.Ordinal);
        for (int index = 0; index < Lines.Count; index++)
        {
            using var entry = JsonDocument.Parse(Lines[index]);
            if (entry.RootElement.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String) byId[id.GetString()!] = hashes[index];
        }
        // Parse and hash the whole batch before mutating the committed copy.
        var batch = new List<(string Line, string Hash)>();
        foreach (var record in parameters.GetProperty("records").EnumerateArray())
        {
            var line = record.GetProperty("line").GetString()!;
            using var document = JsonDocument.Parse(line);
            var refs = new SortedDictionary<string, string?>(StringComparer.Ordinal);
            foreach (var field in new[] { "firstKeptEntryId", "fromId", "parentId", "targetId" })
                if (document.RootElement.TryGetProperty(field, out var reference))
                    refs[field] = reference.ValueKind == JsonValueKind.String && byId.TryGetValue(reference.GetString()!, out var hash) ? hash : null;
            var envelope = JsonSerializer.Serialize(new { content = Digest("content", line), refs, transcript = headerHash });
            var computed = Digest("record", envelope);
            if (computed != record.GetProperty("hash").GetString()) throw new IOException("Invalid pi/3 record hash");
            batch.Add((line, computed));
            if (document.RootElement.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String) byId[id.GetString()!] = computed;
        }
        if (!Known) chains.Add(headerHash);
        foreach (var record in batch)
        {
            Lines.Add(record.Line); hashes.Add(record.Hash);
            chains.Add(Digest("chain", chains[^1] + "\n" + record.Hash));
        }
        return new { outcome = "committed", epoch = Epoch, count = Lines.Count, chain = chains[^1] };
    }

    public static void CheckProtocol(Action<bool,string> assert)
    {
        var lines = File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "pi3-session.jsonl"));
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "pi3-vectors.json")));
        var vectors = document.RootElement;
        var batch = vectors.GetProperty("records").EnumerateArray().Select((record,index)=>new { line=lines[index+1],hash=record.GetProperty("hash").GetString() }).ToArray();
        var log = new TranscriptLog { Round = 4 };
        log.Append(JsonSerializer.SerializeToElement(new { epoch=1,from=1,header=lines[0],records=batch }));
        assert(log.Chain(0)==vectors.GetProperty("headerHash").GetString()
            && log.Chain(batch.Length)==vectors.GetProperty("chain").GetString(), "relay fixture validates the shared pi/3 golden hash chains");
        log.Truncate(JsonSerializer.SerializeToElement(new { round=4,keep=2,expectedChain=log.Chain(2) }));
        log.Append(JsonSerializer.SerializeToElement(new { epoch=log.Epoch,from=3,records=batch.Skip(2).ToArray() }));
        assert(log.Lines.Count==batch.Length && log.Chain(batch.Length)==vectors.GetProperty("chain").GetString(),
            "relay fixture reconciles a rewritten prefix with fenced truncate and append");
        var before = log.Epoch;
        log.Truncate(JsonSerializer.SerializeToElement(new { round=3,keep=0,expectedChain=log.Chain(0) }));
        assert(log.Epoch==before,"a stale handshake cannot truncate the fixture transcript");
        bool rejected=false;
        try { log.Append(JsonSerializer.SerializeToElement(new { epoch=log.Epoch,from=batch.Length+1,records=new[]{new { line=lines[1],hash="invalid" }} })); }
        catch(IOException){rejected=true;}
        assert(rejected && log.Lines.Count==batch.Length,"an invalid record hash cannot mutate the fixture transcript");
    }

    public object Truncate(JsonElement parameters)
    {
        int keep = parameters.GetProperty("keep").GetInt32();
        var round = parameters.GetProperty("round").GetInt64();
        if (round != Round || keep < 0 || keep > Lines.Count || Chain(keep) is null
            || Chain(keep) != parameters.GetProperty("expectedChain").GetString())
            return new { round, outcome = "refused", epoch = Epoch };
        Lines.RemoveRange(keep, Lines.Count - keep);
        hashes.RemoveRange(keep, hashes.Count - keep);
        chains.RemoveRange(keep + 1, chains.Count - keep - 1);
        if (keep == 0) chains.Clear();
        Epoch++;
        return new { round, outcome = "truncated", epoch = Epoch };
    }
}
