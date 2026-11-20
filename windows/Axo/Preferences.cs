using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace Axo;

public sealed class Preferences
{
    static string PathName => Environment.GetEnvironmentVariable("AXO_DESKTOP_CONFIG") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Axo", "desktop.json");
    public string Appearance { get; set; } = "System";
    public bool SidebarCollapsed { get; set; }
    public List<string> Pinned { get; set; } = [];
    public static Preferences Load() { try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(PathName)) ?? new(); } catch { return new(); } }
    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        var temporary = PathName + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this)); File.Move(temporary, PathName, true);
    }
    public void Apply()
    {
        // WPF's built-in Fluent appearance follows Windows for native dialogs/controls.
        // .NET 10 still marks this opt-in API experimental; keep the opt-in local.
#pragma warning disable WPF0001
        Application.Current.ThemeMode = Appearance switch { "Light" => ThemeMode.Light, "Dark" => ThemeMode.Dark, _ => ThemeMode.System };
#pragma warning restore WPF0001
        bool light = Appearance == "Light" || Appearance == "System" && (int?)(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1)) != 0;
        var colors = new Dictionary<string, string>
        {
            ["BackgroundBrush"] = light ? "#F0F0F0" : "#202020",
            ["PanelBrush"] = light ? "#F0F0F0" : "#202020",
            ["BorderBrush"] = light ? "#D0D0D0" : "#383838",
            ["TextBrush"] = light ? "#202020" : "#F0F0F0",
            ["MutedBrush"] = light ? "#727272" : "#AAAAAA",
            ["HoverBrush"] = light ? "#0C000000" : "#12FFFFFF",
        };
        foreach (var (key, value) in colors) Application.Current.Resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(value));
        var accent = SystemParameters.WindowGlassColor; accent.A = 41;
        Application.Current.Resources["SelectionBrush"] = new SolidColorBrush(accent);
    }
}
