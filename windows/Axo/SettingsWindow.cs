using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Axo;

/// <summary>SettingsView's 180-point navigation and grouped forms. The Windows
/// slice includes General, Appearance, Remote Access and About.</summary>
public sealed class SettingsWindow : Window
{
    readonly DaemonClient daemon;
    readonly ContentControl page = new() { Margin = new Thickness(20) };
    readonly TextBlock connection = new(), host = new(), detail = new() { TextWrapping = TextWrapping.Wrap }, result = new() { TextWrapping = TextWrapping.Wrap };
    readonly TextBlock duration = new(), daemonVersion = new(), daemonBuild = new(), daemonStatus = new();
    readonly TextBox code = new() { FontFamily = new FontFamily("Consolas"), FontSize = 18, MaxLength = 20 };
    readonly Button link = new() { Content = "Link this PC", Padding = new Thickness(10, 4, 10, 4), HorizontalAlignment = HorizontalAlignment.Left };
    readonly Button retry = new() { Content = "Connect", Padding = new Thickness(10, 4, 10, 4), HorizontalAlignment = HorizontalAlignment.Left };
    readonly System.Windows.Threading.DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
    long? connectedSince;

    public SettingsWindow(DaemonClient client, Preferences preferences)
    {
        daemon = client; Title = "Axo Settings"; Width = 740; Height = 580; MinWidth = 700; MinHeight = 440; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var root = new Grid(); root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) }); root.ColumnDefinitions.Add(new ColumnDefinition()); Content = root;
        var sections = new ListBox { Margin = new Thickness(8, 12, 8, 8), ItemsSource = new[] { "General", "Appearance", "Remote Access", "About" } };
        var sidebar = new Border { Child = sections, BorderThickness = new Thickness(0, 0, 1, 0) }; sidebar.SetResourceReference(Border.BorderBrushProperty, "BorderBrush"); sidebar.SetResourceReference(Border.BackgroundProperty, "PanelBrush"); root.Children.Add(sidebar);
        Grid.SetColumn(page, 1); root.Children.Add(page);

        var general = new StackPanel();
        var status = new TextBlock { Text = "Starting…" };
        AddSection(general, "axod", status);
        var permissions = new StackPanel();
        var fullAccess = new CheckBox { Content = "Full access — run Codex commands without asking", IsEnabled = false, Margin = new Thickness(0, 0, 0, 8) };
        var computerUse = new CheckBox { Content = "Allow computer use on this PC", IsEnabled = false, Margin = new Thickness(0, 0, 0, 8) };
        var permissionStatus = new TextBlock { Text = "Loading permissions…", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
        var savePermissions = new Button { Content = "Save permissions", IsEnabled = false, HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 4, 10, 4) };
        permissions.Children.Add(fullAccess);
        permissions.Children.Add(new TextBlock { Text = "Full access lets Codex read, write and run commands with your Windows account's permissions. It applies on the next turn and does not require Administrator rights.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) });
        permissions.Children.Add(computerUse);
        permissions.Children.Add(new TextBlock { Text = "Allows agents in Axo and your paired account to inspect and operate Windows apps. Actions that may send, delete or commit changes can still ask you first. Locked screens and elevated apps remain protected by Windows.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) });
        permissions.Children.Add(savePermissions); permissions.Children.Add(permissionStatus); AddSection(general, "Agent permissions", permissions);
        savePermissions.Click += async (_, _) =>
        {
            savePermissions.IsEnabled = false;
            try { await daemon.CallAsync("axo.windows.settings.save", new { codexFullAccess = fullAccess.IsChecked == true, computerUseEnabled = computerUse.IsChecked == true }); permissionStatus.Text = "Saved. Codex command permissions apply on the next turn."; }
            catch (Exception error) { permissionStatus.Text = error.Message; }
            finally { savePermissions.IsEnabled = true; }
        };
        var terminal = new StackPanel(); terminal.Children.Add(new TextBlock { Text = "Shell command" }); terminal.Children.Add(new TextBox { Text = "powershell.exe -NoLogo -NoProfile -NoExit", IsReadOnly = true, FontFamily = new FontFamily("Consolas"), Margin = new Thickness(0, 8, 0, 0) }); AddSection(general, "Terminal", terminal);

        var appearance = new StackPanel(); var themes = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var title in new[] { "System", "Light", "Dark" })
        {
            var choice = new RadioButton { Content = title, GroupName = "appearance", IsChecked = preferences.Appearance == title, Margin = new Thickness(0, 0, 20, 0) };
            // The Mac appearance picker is segmented. Keep the native radio-group
            // semantics, with the same compact three-segment presentation.
            choice.Margin = new Thickness(1); choice.Padding = new Thickness(14, 5, 14, 5);
            choice.Style = (Style)System.Windows.Markup.XamlReader.Parse("""
                <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="RadioButton">
                  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
                    <Border x:Name="Segment" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" CornerRadius="4" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                    <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Segment" Property="Background" Value="{DynamicResource SelectionBrush}"/></Trigger></ControlTemplate.Triggers>
                  </ControlTemplate></Setter.Value></Setter>
                </Style>
                """);
            choice.Checked += (_, _) => { preferences.Appearance = title; preferences.Save(); preferences.Apply(); }; themes.Children.Add(choice);
        }
        var segmented = new Border { Child = themes, CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Left }; segmented.SetResourceReference(Border.BorderBrushProperty, "BorderBrush"); AddSection(appearance, "Theme", segmented);

        var remote = new StackPanel(); var pairing = new StackPanel();
        pairing.Children.Add(new TextBlock { Text = "Enter the one-time code from your Axo account to connect this PC.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) });
        System.Windows.Automation.AutomationProperties.SetName(code, "Host pairing code");
        var entry = new Grid(); var placeholder = new TextBlock { Text = "XXXX-YYYY", Foreground = SystemColors.GrayTextBrush, FontFamily = new FontFamily("Consolas"), FontSize = 18, Margin = new Thickness(8, 4, 0, 0), IsHitTestVisible = false };
        entry.Children.Add(code); entry.Children.Add(placeholder); pairing.Children.Add(entry);
        result.Margin = new Thickness(0, 8, 0, 8); pairing.Children.Add(result); pairing.Children.Add(link); AddSection(remote, "Link this PC", pairing);
        var summary = new StackPanel(); summary.Children.Add(connection); summary.Children.Add(duration); detail.Margin = new Thickness(0, 5, 0, 10); summary.Children.Add(detail); summary.Children.Add(retry); AddSection(remote, "Connection", summary);
        var identity = new StackPanel(); identity.Children.Add(host); var version = Environment.OSVersion.Version;
        identity.Children.Add(new TextBlock { Text = $"Platform     Windows {(version.Build >= 22000 ? "11" : "10")} ({version.Build})", Margin = new Thickness(0, 8, 0, 0) }); AddSection(remote, "This PC", identity);

        var about = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        about.Children.Add(new Mascot { Artboard = "Face", Width = 184, Height = 104, HorizontalAlignment = HorizontalAlignment.Center });
        about.Children.Add(new TextBlock { Text = "Axo", FontSize = 30, FontWeight = FontWeights.Bold, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 14, 0, 6) });
        about.Children.Add(new TextBlock { Text = "Agentic harness for terminal romantics", TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 0, 0, 14) });
        var information = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "Unknown";
        AboutRow(about, "Semantic version", new TextBlock { Text = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "Unknown" });
        AboutRow(about, "Commit hash", new TextBlock { Text = information.Contains('+') ? information.Split('+')[1][..Math.Min(7, information.Split('+')[1].Length)] : "Development" });
        AboutRow(about, "Build number", new TextBlock { Text = information.Split('+')[0].Split('.').Last() });
        about.Children.Add(new Separator { Width = 260, Margin = new Thickness(0, 6, 0, 6) });
        AboutRow(about, "axod version", daemonVersion); AboutRow(about, "axod build", daemonBuild); AboutRow(about, "Daemon status", daemonStatus);
        var links = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0) };
        foreach (var (label, url) in new[] { ("Docs", "https://github.com/leostera/axo#readme"), ("GitHub", "https://github.com/leostera/axo") }) { var button = new Button { Content = label, Margin = new Thickness(6, 0, 6, 0), Padding = new Thickness(10, 4, 10, 4) }; button.Click += (_, _) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); links.Children.Add(button); }
        about.Children.Add(links);
        var installation = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0,12,0,0) };
        var install = new Button { Content = "Install This Build", Margin = new Thickness(4), Padding = new Thickness(8,4,8,4) };
        var update = new Button { Content = "Update from Package…", Margin = new Thickness(4), Padding = new Thickness(8,4,8,4) };
        var installStatus = new TextBlock { MaxWidth = 340, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,8,0,0) };
        async Task Install(string source) { install.IsEnabled=update.IsEnabled=false; try { var executable=await Task.Run(()=>Installer.Install(source,Installer.DefaultRoot)); Installer.AddStartMenuShortcut(executable); installStatus.Text="Installed in your Start menu. Running sessions are unchanged. Open the installed build after quitting Axo and restarting axod when your work is saved."; } catch(Exception error) { installStatus.Text=error.Message; } finally { install.IsEnabled=update.IsEnabled=true; } }
        install.Click+=async (_,_)=>await Install(AppContext.BaseDirectory);
        update.Click+=async (_,_)=>{ var picker=new Microsoft.Win32.OpenFileDialog {Title="Choose an Axo Windows package",Filter="Axo package (*.zip)|*.zip"}; if(picker.ShowDialog(this)==true)await Install(picker.FileName); };
        installation.Children.Add(install);installation.Children.Add(update);about.Children.Add(installation);about.Children.Add(installStatus);

        UIElement Scroll(UIElement content) => new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var pages = new Dictionary<string, UIElement> { ["General"] = Scroll(general), ["Appearance"] = Scroll(appearance), ["Remote Access"] = Scroll(remote), ["About"] = about };
        sections.SelectionChanged += (_, _) => { if (sections.SelectedItem is string selected) page.Content = pages[selected]; }; sections.SelectedItem = "Remote Access";
        link.Click += async (_, _) => await LinkAsync();
        retry.Click += async (_, _) => { retry.IsEnabled = false; try { ApplyStatus(await daemon.CallAsync("axo.relay.connect")); } catch (Exception e) { detail.Text = e.Message; } finally { retry.IsEnabled = true; } };
        code.TextChanged += (_, _) => { placeholder.Visibility = code.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; link.IsEnabled = ValidCode(); }; link.IsEnabled = false;
        Loaded += async (_, _) =>
        {
            try
            {
                ApplyStatus(await daemon.CallAsync("axo.relay.status")); var health = await daemon.CallAsync("axo.daemon.health");
                daemonVersion.Text = health.GetProperty("version").GetString(); daemonBuild.Text = health.GetProperty("buildNumber").ToString(); status.Text = daemonStatus.Text = "Running";
                try
                {
                    var settings = await daemon.CallAsync("axo.windows.settings");
                    fullAccess.IsChecked = settings.GetProperty("codexFullAccess").GetBoolean(); computerUse.IsChecked = settings.GetProperty("computerUseEnabled").GetBoolean();
                    fullAccess.IsEnabled = computerUse.IsEnabled = savePermissions.IsEnabled = true; permissionStatus.Text = "";
                }
                catch (Exception error) { permissionStatus.Text = "Update axod to change permissions. " + error.Message; }
            }
            catch (Exception e) { detail.Text = e.Message; status.Text = daemonStatus.Text = "Unavailable"; }
            clock.Start();
        };
        clock.Tick += (_, _) => UpdateDuration(); Closed += (_, _) => clock.Stop();
    }
    static void AddSection(Panel parent, string title, UIElement content)
    {
        parent.Children.Add(new GroupBox { Header = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold }, Content = new Border { Child = content, Padding = new Thickness(12) }, Margin = new Thickness(0, 0, 0, 16) });
    }
    static void AboutRow(Panel panel, string title, TextBlock value)
    {
        var row = new Grid { Margin = new Thickness(0, 3, 0, 3) }; row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) }); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        row.Children.Add(new TextBlock { Text = title, TextAlignment = TextAlignment.Right, Margin = new Thickness(0, 0, 10, 0), Foreground = SystemColors.GrayTextBrush }); Grid.SetColumn(value, 1); row.Children.Add(value); panel.Children.Add(row);
    }
    string NormalizeCode() { var text = code.Text.Trim().ToUpperInvariant().Replace(" ", ""); if (text.Length == 8 && !text.Contains('-')) text = text[..4] + "-" + text[4..]; return text; }
    bool ValidCode() => System.Text.RegularExpressions.Regex.IsMatch(NormalizeCode(), "^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{4}-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{4}$");
    async Task LinkAsync()
    {
        link.IsEnabled = false; code.IsEnabled = false; link.Content = "Linking this PC…"; result.Text = "";
        try { var response = await daemon.CallAsync("axo.relay.link", new { code = NormalizeCode() }); code.Clear(); result.Text = response.GetProperty("hostLabel").GetString() + " is linked. axod will connect automatically."; ApplyStatus(await daemon.CallAsync("axo.relay.status")); }
        catch (Exception error) { result.Text = error.Message; }
        finally { link.Content = "Link this PC"; code.IsEnabled = true; link.IsEnabled = ValidCode(); }
    }
    public void ApplyStatus(JsonElement status)
    {
        var state = status.GetProperty("state").GetString(); connection.Text = state switch { "connected" => "●  Connected", "connecting" => "◌  Connecting…", _ => "○  Disconnected" };
        host.Text = "Host name     " + status.GetProperty("hostName").GetString(); detail.Text = status.TryGetProperty("lastError", out var error) && error.ValueKind == JsonValueKind.String ? error.GetString() : "";
        retry.Content = state == "connected" ? "Reconnect" : "Connect"; connectedSince = status.TryGetProperty("connectedSinceUnixMillis", out var at) && at.ValueKind == JsonValueKind.Number ? at.GetInt64() : null; UpdateDuration();
    }
    void UpdateDuration() { duration.Text = connectedSince is long at ? "Connected for " + (DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeMilliseconds(at)).ToString(@"hh\:mm\:ss") : ""; }
}
