using System.Text;
using System.Text.Json;

namespace Axo;

/// <summary>Display values, not another serialization of a tool's JSON transport.</summary>
public sealed record ToolPresentation(string Title, string Input)
{
    public static ToolPresentation From(string name, JsonElement arguments)
    {
        var shortName = name.StartsWith("functions.", StringComparison.Ordinal) ? name[10..] : name;
        string Value(string key) => arguments.ValueKind == JsonValueKind.Object && arguments.TryGetProperty(key, out var value) ? Display(value) : "";
        var title = shortName switch
        {
            "exec" or "codemode" => "Run code",
            "exec_command" or "shell_command" or "shell" or "bash" => "Run command",
            "wait" or "write_stdin" => "Wait for running work",
            "apply_patch" or "edit" => "Edit files",
            "update_plan" => "Update plan",
            "read" => "Read file",
            _ => shortName.Replace('_', ' '),
        };
        var input = new[] { "command", "cmd", "code", "input" }.Select(Value).FirstOrDefault(value => value.Length != 0);
        return new(title, input ?? Display(arguments));
    }

    public static string Content(JsonElement content)
    {
        if (content.ValueKind == JsonValueKind.Array)
            return string.Join("\n", content.EnumerateArray().Select(block => block.TryGetProperty("text", out var text) ? Output(text.GetString() ?? "") : "[image]"));
        return content.ValueKind == JsonValueKind.String ? Output(content.GetString() ?? "") : Display(content);
    }

    static string Output(string text)
    {
        // Decode a complete structured result once. Never blindly unescape paths or code.
        if (!text.TrimStart().StartsWith('{')) return text;
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.TryGetProperty("stdout", out _) || root.TryGetProperty("output", out _) || root.TryGetProperty("stderr", out _)) return Display(root);
        }
        catch (JsonException) { }
        return text;
    }

    public static string Display(JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.String: return value.GetString() ?? "";
            case JsonValueKind.Null: case JsonValueKind.Undefined: return "";
            case JsonValueKind.Array: return string.Join("\n", value.EnumerateArray().Select(Display));
            case JsonValueKind.Object:
                var text = new StringBuilder();
                foreach (var property in value.EnumerateObject())
                {
                    if (text.Length != 0) text.AppendLine();
                    text.Append(property.Name).Append(": ").Append(Display(property.Value));
                }
                return text.ToString();
            default: return value.ToString();
        }
    }
}
