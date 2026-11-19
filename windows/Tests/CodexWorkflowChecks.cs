using System.Text.Json;
using Axo;

static class CodexWorkflowChecks
{
    public static void Run(Action<bool,string> assert)
    {
        var code = "const path = String.raw`C:\\work\\file.rs`;\nconsole.log(path);";
        var arguments = JsonSerializer.SerializeToElement(new { input = code });
        var view = ToolPresentation.From("exec", arguments);
        assert(view.Title == "Run code" && view.Input == code, "Codex exec cards show literal code rather than JSON-escaped transport arguments");
        var command = ToolPresentation.From("functions.exec_command", JsonSerializer.SerializeToElement(new { cmd = "Get-Content C:\\work\\file.rs" }));
        assert(command.Title == "Run command" && command.Input == "Get-Content C:\\work\\file.rs", "native command arguments retain Windows paths without extra escaping");
        var output = JsonSerializer.SerializeToElement(new[] { new { type = "text", text = JsonSerializer.Serialize(new { stdout = "C:\\work\\file.rs\nDone", exit_code = 0 }) } });
        assert(ToolPresentation.Content(output).Contains("C:\\work\\file.rs\nDone"), "structured tool output is decoded once without corrupting paths or line breaks");
        var request = JsonSerializer.SerializeToElement(new { mode = "form", message = "Allow Codex to use Axo?", serverName = "node_repl",
            requestedSchema = new { type = "object", properties = new { } }, _meta = new { persist = true, tool_params_display = new { tool = "fixture" } } });
        assert(CodexInteraction.IsConfirmation(request) && CodexInteraction.Describe(request).Contains("remember permission")
            && CodexInteraction.Describe(request).Contains("fixture"), "empty MCP confirmation forms show the requested action and persistence warning");
        var form = JsonSerializer.SerializeToElement(new { mode = "form", requestedSchema = new { type = "object", properties = new { secret = new { type = "string" } } } });
        assert(!CodexInteraction.IsConfirmation(form), "MCP forms with input fields cannot be accepted as empty confirmations");
    }
}
