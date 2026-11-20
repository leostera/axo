using System.Text.Json;
using Axo;

static class LaunchProfileChecks
{
    public static void Run(string root, Action<bool,string> assert)
    {
        string[] keys = ["AXO_SERVER_DIR", "AXO_DESKTOP_CONFIG", "AXO_PIPE", "AXO_CODEX", "AXO_LAUNCH_PROFILE"];
        var before = keys.ToDictionary(key => key, Environment.GetEnvironmentVariable);
        try
        {
            var profileRoot = Path.Combine(root, "profile with spaces ž");
            var file = Path.Combine(profileRoot, "launch.json");
            var config = new LaunchProfile.Configuration(Path.Combine(profileRoot, "server"), Path.Combine(profileRoot, "preferences.json"),
                "Axo-existing-profile", Path.Combine(root, "codex.exe"));
            var json = JsonSerializer.Serialize(config);
            Directory.CreateDirectory(profileRoot); File.WriteAllText(file, json);
            LaunchProfile.ApplyArguments(["--profile", file]);
            assert(Environment.GetEnvironmentVariable("AXO_SERVER_DIR") == config.ServerDirectory
                && Environment.GetEnvironmentVariable("AXO_DESKTOP_CONFIG") == config.DesktopConfig
                && Environment.GetEnvironmentVariable("AXO_PIPE") == config.PipeName,
                "a native installed launch keeps the existing database, preferences and pipe without moving user data");
            assert(LaunchProfile.CurrentShortcutArguments() == "--profile \"" + file + "\"",
                "installed shortcuts and subsequent updates retain the selected profile with spaces and Unicode");
            var current = keys.Select(Environment.GetEnvironmentVariable).ToArray();
            bool Refused(Action action) { try { action(); return false; } catch (Exception e) when (e is IOException or JsonException) { return true; } }
            assert(Refused(() => LaunchProfile.ApplyArguments(["--profile", file, "--unexpected"])), "unknown launch arguments fail before changing the profile");
            assert(Refused(() => LaunchProfile.Parse(file, JsonSerializer.Serialize(config with { ServerDirectory = "relative" })))
                && Refused(() => LaunchProfile.Parse(file, JsonSerializer.Serialize(config with { DesktopConfig = null! })))
                && Refused(() => LaunchProfile.Parse(file, JsonSerializer.Serialize(config with { PipeName = @"\\.\pipe\other" })))
                && Refused(() => LaunchProfile.Parse(file, "{\"unknown\":true}")),
                "launch configuration rejects relative paths, missing values, pipe paths and unknown fields");
            assert(current.SequenceEqual(keys.Select(Environment.GetEnvironmentVariable)), "rejected launch profiles leave every environment setting unchanged");
            Environment.SetEnvironmentVariable("AXO_LAUNCH_PROFILE", null);
            var arguments = LaunchProfile.CurrentShortcutArguments();
            var captured = Path.Combine(config.ServerDirectory, "desktop-launch.json");
            assert(File.Exists(captured) && arguments == "--profile \"" + captured + "\"",
                "installing from a configured preview captures only its launch paths, not its conversations or credentials");
            LaunchProfile.ApplyArguments(["--profile", captured]);
            assert(Environment.GetEnvironmentVariable("AXO_PIPE") == config.PipeName, "captured profiles reopen the same daemon identity");
        }
        finally { foreach (var key in keys) Environment.SetEnvironmentVariable(key, before[key]); }
    }
}
