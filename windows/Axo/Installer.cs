using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Axo;

/// Versioned per-user installs. Never replace a mapped executable or stop a process.
public static class Installer
{
    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Axo");
    public static string Install(string source, string root)
    {
        root = Path.GetFullPath(root); Directory.CreateDirectory(root);
        string stage = Path.Combine(root, ".staging-" + Guid.NewGuid()); Directory.CreateDirectory(stage);
        try
        {
            if (File.Exists(source))
            {
                using var zip = ZipFile.OpenRead(source); long total = 0; var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var entry in zip.Entries)
                {
                    if (entry.FullName.EndsWith('/')) continue;
                    string target = Within(stage, entry.FullName);
                    if (!paths.Add(target) || entry.Length > 150 * 1024 * 1024 || (total += entry.Length) > 512L * 1024 * 1024) throw new IOException("The package has duplicate paths or exceeds the size limit.");
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!); entry.ExtractToFile(target);
                }
            }
            else
            {
                // Only files declared in the package are copied; never copy user state.
                using var sourceManifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(source, "build-manifest.json")));
                foreach (var file in sourceManifest.RootElement.GetProperty("files").EnumerateArray())
                {
                    string relative = file.GetProperty("path").GetString()!; string from = Within(source, relative); string to = Within(stage, relative);
                    if ((File.GetAttributes(from) & FileAttributes.ReparsePoint) != 0) throw new IOException("A package file cannot be a link.");
                    Directory.CreateDirectory(Path.GetDirectoryName(to)!); File.Copy(from, to);
                }
                File.Copy(Path.Combine(source, "build-manifest.json"), Path.Combine(stage, "build-manifest.json"));
            }
            var identity = Verify(stage);
            string destination = Path.Combine(root, "releases", identity); Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            if (Directory.Exists(destination)) Verify(destination); else Directory.Move(stage, destination);
            return Path.Combine(destination, "Axo.exe");
        }
        finally { if (Directory.Exists(stage)) Directory.Delete(stage, true); }
    }
    public static string Verify(string directory)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "build-manifest.json"))); var manifest = document.RootElement;
        string version = manifest.GetProperty("version").GetString()!; string commit = manifest.GetProperty("gitCommit").GetString()!; int build = manifest.GetProperty("axodBuild").GetInt32();
        if (!Version.TryParse(version, out _) || build < 1 || commit.Length != 40 || !commit.All(Uri.IsHexDigit)) throw new IOException("The package identity is invalid.");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in manifest.GetProperty("files").EnumerateArray())
        {
            string relative = file.GetProperty("path").GetString()!; string path = Within(directory, relative);
            if (!paths.Add(path)) throw new IOException("Duplicate manifest file.");
            using var stream = File.OpenRead(path);
            if (stream.Length != file.GetProperty("bytes").GetInt64() || !Convert.ToHexStringLower(SHA256.HashData(stream)).Equals(file.GetProperty("sha256").GetString(), StringComparison.OrdinalIgnoreCase)) throw new IOException("Package verification failed: " + relative);
        }
        foreach (string required in new[] { "Axo.exe", "Axo.dll", "axod.exe", "Axo.runtimeconfig.json" }) if (!paths.Contains(Within(directory, required))) throw new IOException("The package is missing " + required);
        foreach (string file in Directory.GetFiles(directory, "*", SearchOption.AllDirectories)) if (!paths.Contains(Path.GetFullPath(file)) && Path.GetFileName(file) != "build-manifest.json") throw new IOException("The package contains an undeclared file.");
        return $"{version}-{build}-{commit[..8]}";
    }
    static string Within(string root, string relative)
    {
        if (Path.IsPathRooted(relative) || relative.Split('/', '\\').Any(part => part is "" or "." or ".." || part.Any(c => "<>:\"|?*".Contains(c)) || part.EndsWith('.') || part.EndsWith(' '))) throw new IOException("The package contains an unsafe path.");
        string target = Path.GetFullPath(Path.Combine(root, relative)); string prefix = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
        if (!target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new IOException("The package path is outside the install directory."); return target;
    }
    public static void AddStartMenuShortcut(string executable)
    {
        string menu = Environment.GetFolderPath(Environment.SpecialFolder.Programs); string path = Path.Combine(menu, "Axo.lnk");
        var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Windows shortcut support is unavailable.");
        dynamic shell = Activator.CreateInstance(shellType)!;
        try
        {
            dynamic shortcut = shell.CreateShortcut(path); try { shortcut.TargetPath = executable; shortcut.WorkingDirectory = Path.GetDirectoryName(executable); shortcut.IconLocation = executable; shortcut.Description = "Axo"; shortcut.Save(); } finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shortcut); }
        }
        finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell); }
    }
}
