using System.IO;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Axo;

/// <summary>Local launch configuration, never account credentials or a copy of user data.</summary>
public sealed class LaunchProfile
{
    public sealed record Configuration(string ServerDirectory, string DesktopConfig, string PipeName, string? CodexExecutable = null);
    static readonly JsonSerializerOptions JsonOptions = new() { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };
    readonly Configuration configuration;
    public string FileName { get; }
    public string Arguments => "--profile \"" + FileName + "\"";
    LaunchProfile(string file, Configuration configuration) { FileName = file; this.configuration = configuration; }

    static string Absolute(string? value, string field)
    {
        if (string.IsNullOrWhiteSpace(value) || !Path.IsPathFullyQualified(value)) throw new IOException(field + " must be an absolute Windows path.");
        return Path.GetFullPath(value);
    }
    public static LaunchProfile Parse(string file, string json)
    {
        file = Absolute(file, "Profile file");
        if (json.Length > 16384) throw new IOException("Launch profile is too large.");
        var parsed = JsonSerializer.Deserialize<Configuration>(json, JsonOptions) ?? throw new IOException("Launch profile is empty.");
        var server = Absolute(parsed.ServerDirectory, "ServerDirectory");
        var desktop = Absolute(parsed.DesktopConfig, "DesktopConfig");
        var codex = parsed.CodexExecutable is null ? null : Absolute(parsed.CodexExecutable, "CodexExecutable");
        if (string.IsNullOrWhiteSpace(parsed.PipeName) || parsed.PipeName.Length > 128
            || !parsed.PipeName.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.'))
            throw new IOException("PipeName must be a short local pipe name, not a pipe path.");
        return new(file, new(server, desktop, parsed.PipeName, codex));
    }
    public static LaunchProfile Load(string file)
    {
        file = Absolute(file, "Profile file");
        if (new FileInfo(file).Length > 16384) throw new IOException("Launch profile is too large.");
        return Parse(file, File.ReadAllText(file));
    }
    public void Apply()
    {
        Environment.SetEnvironmentVariable("AXO_SERVER_DIR", configuration.ServerDirectory);
        Environment.SetEnvironmentVariable("AXO_DESKTOP_CONFIG", configuration.DesktopConfig);
        Environment.SetEnvironmentVariable("AXO_PIPE", configuration.PipeName);
        if (configuration.CodexExecutable is not null) Environment.SetEnvironmentVariable("AXO_CODEX", configuration.CodexExecutable);
        Environment.SetEnvironmentVariable("AXO_LAUNCH_PROFILE", FileName);
    }
    public static void ApplyArguments(string[] arguments)
    {
        if (arguments.Length == 0) return;
        if (arguments.Length != 2 || arguments[0] != "--profile") throw new IOException("Usage: Axo.exe [--profile <absolute profile.json>]");
        Load(arguments[1]).Apply();
    }
    public static string CurrentShortcutArguments()
    {
        if (Environment.GetEnvironmentVariable("AXO_LAUNCH_PROFILE") is string selected) return Load(selected).Arguments;
        var server = Environment.GetEnvironmentVariable("AXO_SERVER_DIR");
        var desktop = Environment.GetEnvironmentVariable("AXO_DESKTOP_CONFIG");
        var pipe = Environment.GetEnvironmentVariable("AXO_PIPE");
        var codex = Environment.GetEnvironmentVariable("AXO_CODEX");
        if (server is null && desktop is null && pipe is null && codex is null) return "";
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Axo");
        var config = new Configuration(server ?? Path.Combine(root, "server"), desktop ?? Path.Combine(root, "desktop.json"),
            pipe ?? "Axo-" + WindowsIdentity.GetCurrent().User!.Value, codex);
        var file = Path.Combine(config.ServerDirectory, "desktop-launch.json");
        var json = JsonSerializer.Serialize(config);
        var profile = Parse(file, json); // Establish every path before writing or mutating the environment.
        Directory.CreateDirectory(config.ServerDirectory);
        File.WriteAllText(file + ".tmp", json);
        File.Move(file + ".tmp", file, true);
        return profile.Arguments;
    }
}
