using System.IO;
using System.Text.Json;

namespace Axo;

public partial class MainWindow
{
    string? transcriptSession;
    DateTime nextTranscriptRead;

    async Task LoadTranscriptAsync(string id)
    {
        if (transcriptSession == id && DateTime.UtcNow < nextTranscriptRead) return;
        transcriptSession = id;
        nextTranscriptRead = DateTime.UtcNow.AddSeconds(1);
        var result = await daemon.CallAsync("axo.session.transcript", new { sessionId = id });
        var path = result.GetProperty("path").GetString()!;
        var records = new List<JsonElement>();
        // The daemon replaces this file atomically; never hold a handle that prevents rename.
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(stream))
            while (await reader.ReadLineAsync() is string line)
            {
                using var document = JsonDocument.Parse(line);
                records.Add(document.RootElement.Clone());
            }
        if (selected != id || closed) return;
        var order = new List<MessageView>();
        var seen = new HashSet<MessageView>();
        var toolInputs = new Dictionary<string, string>();
        string? currentRequest = null;
        string? publishedPlan = null;
        void Remember(MessageView row) { if (seen.Add(row)) order.Add(row); }
        foreach (var entry in records)
        {
            if (entry.GetProperty("type").GetString() != "message") continue;
            var key = entry.GetProperty("id").GetString()!;
            var message = entry.GetProperty("message");
            var role = message.GetProperty("role").GetString();
            var content = message.GetProperty("content");
            if (role == "toolResult")
            {
                var callId = message.GetProperty("toolCallId").GetString()!;
                var row = GetMessage(callId, "TOOL");
                var input = toolInputs.TryGetValue(callId, out var supplied) ? "Input:\n" + supplied + "\n\nOutput:\n" : "";
                row.Text = Tail(input + ToolPresentation.Content(content)); row.Complete = true; Remember(row);
                continue;
            }
            if (role == "user")
            {
                var row = GetMessage(key, "YOU");
                row.Text = TranscriptText(content); row.Complete = true; Remember(row);
                currentRequest = row.Text;
                publishedPlan = null;
                continue;
            }
            if (role != "assistant" || content.ValueKind != JsonValueKind.Array) continue;
            int index = 0;
            foreach (var block in content.EnumerateArray())
            {
                switch (block.GetProperty("type").GetString())
                {
                    case "text":
                        var words = GetMessage(key, "CODEX");
                        words.Text = block.GetProperty("text").GetString() ?? ""; words.Complete = true; Remember(words);
                        break;
                    case "thinking":
                        var thinking = GetMessage(key + ":thinking:" + index, "THINKING · SUMMARY");
                        thinking.Text = block.GetProperty("thinking").GetString() ?? ""; thinking.Complete = true; Remember(thinking);
                        break;
                    case "toolCall":
                        var toolId = block.GetProperty("id").GetString()!;
                        var name = block.GetProperty("name").GetString()!;
                        var arguments = block.TryGetProperty("arguments", out var suppliedArguments) ? suppliedArguments : default;
                        var presentation = ToolPresentation.From(name, arguments);
                        var tool = GetMessage(toolId, "TOOL · " + presentation.Title);
                        tool.Label = "TOOL · " + presentation.Title;
                        tool.RawDetails = arguments.ValueKind == JsonValueKind.Undefined ? "" : arguments.GetRawText();
                        toolInputs[toolId] = presentation.Input;
                        if (name is "update_plan" or "functions.update_plan") publishedPlan = presentation.Input;
                        if (tool.Text.Length == 0) tool.Text = toolInputs[toolId].Length > 0 ? toolInputs[toolId] : "Running…";
                        Remember(tool);
                        break;
                }
                index++;
            }
        }
        if (currentRequest is not null)
        {
            CurrentTask.Text = "Current request: " + currentRequest;
            CurrentTask.ToolTip = currentRequest;
            CurrentTask.Visibility = System.Windows.Visibility.Visible;
        }
        PublishedPlan.Text = publishedPlan ?? "The agent has not published a plan.";
        // Late native flushes may add activity before an already visible final answer.
        // Reorder existing rows by canonical history, retaining in-flight streamed rows.
        for (int index = 0; index < order.Count; index++)
        {
            int previous = Messages.IndexOf(order[index]);
            if (previous != index) Messages.Move(previous, index);
        }
    }

    static string TranscriptText(JsonElement content)
    {
        if (content.ValueKind == JsonValueKind.String) return content.GetString() ?? "";
        if (content.ValueKind != JsonValueKind.Array) return content.ToString();
        return string.Join("\n", content.EnumerateArray().Select(block =>
            block.TryGetProperty("text", out var text) ? text.GetString() : "[image]"));
    }
}
