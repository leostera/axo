using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace Axo;

public partial class MainWindow
{
    Forms.NotifyIcon? tray;
    Forms.ToolStripMenuItem? trayHealth;
    Drawing.Bitmap? mark;
    Drawing.Icon? trayFrame;
    readonly DispatcherTimer trayClock = new() { Interval = TimeSpan.FromMilliseconds(1000.0 / 30) };
    int mascotFrame;
    SettingsWindow? settings;
    JsonElement? relayStatus;
    DataTemplate? expandedSessionTemplate, expandedGroupTemplate;
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    void SetupTray()
    {
        using var resource = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/Mark.png"))!.Stream;
        using var original = new Drawing.Bitmap(resource); mark = new Drawing.Bitmap(original);
        trayHealth = new Forms.ToolStripMenuItem("axod starting…") { Enabled = false };
        var menu = new Forms.ContextMenuStrip(); menu.Items.Add(trayHealth); menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Open Terminal", null, (_, _) => Dispatcher.Invoke(Reveal));
        menu.Items.Add("Settings…", null, (_, _) => Dispatcher.Invoke(() => ShowSettings(this, new RoutedEventArgs())));
        menu.Items.Add(new Forms.ToolStripSeparator()); menu.Items.Add("Quit Axo", null, (_, _) => Dispatcher.Invoke(() => Quit(this, new RoutedEventArgs())));
        tray = new Forms.NotifyIcon { Text = "Axo", ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(Reveal);
        trayClock.Tick += (_, _) => AnimateTray(); AnimateTray(); tray.Visible = true;
        if (SystemParameters.ClientAreaAnimation) trayClock.Start();
    }
    void AnimateTray()
    {
        if (mark is null || tray is null) return;
        int frame = (mascotFrame++) % 120;
        int attention = allSessions.Count(s => s.Status == "needsAttention");
        var light = (int?)(Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0)) != 0;
        var tint = attention > 0 ? Drawing.Color.FromArgb(217, 23, 92) : light ? Drawing.Color.FromArgb(40, 40, 40) : Drawing.Color.White;
        using var icon = new Drawing.Bitmap(32, 32);
        using (var graphics = Drawing.Graphics.FromImage(icon))
        using (var attributes = new Drawing.Imaging.ImageAttributes())
        {
            attributes.SetColorMatrix(new Drawing.Imaging.ColorMatrix(new float[][] { [0, 0, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0, 1, 0], [tint.R / 255f, tint.G / 255f, tint.B / 255f, 0, 1] }));
            graphics.DrawImage(mark, new Drawing.Rectangle(0, 7, 32, 18), frame % 12 * 64, frame / 12 * 36, 64, 36, Drawing.GraphicsUnit.Pixel, attributes);
        }
        var handle = icon.GetHicon(); Drawing.Icon next;
        try { using var borrowed = Drawing.Icon.FromHandle(handle); next = (Drawing.Icon)borrowed.Clone(); } finally { DestroyIcon(handle); }
        var previous = trayFrame; trayFrame = next; tray.Icon = next; previous?.Dispose();
    }
    void UpdateTray()
    {
        if (tray is null) return;
        var count = allSessions.Count(s => s.Status == "needsAttention");
        tray.Text = count > 0 ? $"Axo — {count} waiting for input" : "Axo";
        if (trayHealth is not null) trayHealth.Text = DaemonStatus.Text.Contains("running") ? "●  axod running" : DaemonStatus.Text;
    }
    void Reveal() { Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }
    void ShowAppMenu(object sender, RoutedEventArgs e)
    {
        var button = (Button)sender; var menu = new ContextMenu();
        void Add(string title, RoutedEventHandler action, string shortcut = "", bool enabled = true) { var item = new MenuItem { Header = title, InputGestureText = shortcut, IsEnabled = enabled }; item.Click += action; menu.Items.Add(item); }
        switch (button.Tag)
        {
            case "Axo": Add("Settings…", ShowSettings, "Ctrl+,"); menu.Items.Add(new Separator()); Add("Quit Axo", Quit, "Ctrl+Q"); break;
            case "Terminal": Add("New Workspace…", OpenFolder, "Ctrl+N"); Add("New Session", ChooseNewSession, "Ctrl+Shift+N"); menu.Items.Add(new Separator()); Add("Split Right", OpenTerminal, "Ctrl+Shift+D", selected is not null); Add("Open External Terminal", OpenExternalTerminal, "", selected is not null); menu.Items.Add(new Separator()); Add("Session", ShowSessionMenu, "", selected is not null); break;
            case "View": Add("Toggle Sidebar", ToggleSidebar, "Ctrl+B"); Add("Close Terminal Pane", CloseTerminal, "", selected is not null); break;
        }
        menu.PlacementTarget = button; menu.IsOpen = true;
    }
    void HideWindow(object sender, RoutedEventArgs e) => Close();
    void Minimize(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    void Maximize(object sender, RoutedEventArgs e) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    void DismissError(object sender, RoutedEventArgs e) => HideError();
    void ToggleSidebar(object sender, RoutedEventArgs e) { preferences.SidebarCollapsed = !preferences.SidebarCollapsed; preferences.Save(); ApplySidebar(); }
    void ApplySidebar()
    {
        expandedSessionTemplate ??= SessionList.ItemTemplate; expandedGroupTemplate ??= SessionList.GroupStyle[0].HeaderTemplate;
        SidebarColumn.Width = new GridLength(preferences.SidebarCollapsed ? 52 : 220); SidebarHeader.Visibility = preferences.SidebarCollapsed ? Visibility.Collapsed : Visibility.Visible; EmptySidebar.Visibility = !preferences.SidebarCollapsed && Sessions.Count == 0 ? Visibility.Visible : Visibility.Collapsed; AppMenu.Visibility = preferences.SidebarCollapsed ? Visibility.Collapsed : Visibility.Visible;
        SessionList.ItemTemplate = preferences.SidebarCollapsed ? (DataTemplate)FindResource("CollapsedSessionTemplate") : expandedSessionTemplate;
        SessionList.GroupStyle[0].HeaderTemplate = preferences.SidebarCollapsed ? new DataTemplate() : expandedGroupTemplate;
    }
    void SetTerminalVisible(bool visible) { TerminalColumn.Width = visible ? new GridLength(1, GridUnitType.Star) : new GridLength(0); SplitDivider.Width = new GridLength(visible ? 1 : 0); EmbeddedTerminal.Visibility = visible ? Visibility.Visible : Visibility.Collapsed; }
    async Task AttachTerminalAsync(string id) { SetTerminalVisible(true); await EmbeddedTerminal.AttachAsync(daemon, id); }
    void CloseTerminal(object sender, RoutedEventArgs e) { SetTerminalVisible(false); Composer.Focus(); }
    async void OpenExternalTerminal(object sender, RoutedEventArgs e) { if (selected is null) return; try { await daemon.CallAsync("axo.terminal.open", new { sessionId = selected }); } catch (Exception error) { ShowError(error.Message); } }
    void ChooseNewSession(object sender, RoutedEventArgs e)
    {
        var workspaces = (WorkspacePicker.ItemsSource as IEnumerable<WorkspaceView>)?.ToArray() ?? [];
        if (workspaces.Length == 0) { OpenFolder(sender, e); return; }
        var menu = new ContextMenu(); foreach (var w in workspaces) { var item = new MenuItem { Header = w.Name }; item.Click += (_, _) => { WorkspacePicker.SelectedItem = w; NewSession(sender, e); }; menu.Items.Add(item); }
        menu.PlacementTarget = AppMenu; menu.IsOpen = true;
    }
    void ShowHostMenu(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu(); menu.Items.Add(new MenuItem { Header = "This PC", IsChecked = true }); menu.Items.Add(new Separator()); var access = new MenuItem { Header = "Remote Access…" }; access.Click += (_, _) => ShowSettings(sender, e); menu.Items.Add(access); menu.PlacementTarget = (UIElement)sender; menu.IsOpen = true;
    }
    void SessionContextMenu(object sender, MouseButtonEventArgs e)
    {
        DependencyObject? source = e.OriginalSource as DependencyObject;
        while (source is not null && source is not ListBoxItem) source = VisualTreeHelper.GetParent(source);
        if (source is ListBoxItem item) { SessionList.SelectedItem = item.DataContext; ShowSessionMenu(sender, e); e.Handled = true; }
    }
    void WindowKeyDown(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control); var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        if (!ctrl || Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) return;
        if (e.Key == Key.OemComma) ShowSettings(sender, e);
        else if (e.Key == Key.Q) Quit(sender, e);
        else if (e.Key == Key.B) ToggleSidebar(sender, e);
        else if (e.Key == Key.N) { if (shift) ChooseNewSession(sender, e); else OpenFolder(sender, e); }
        else if (e.Key == Key.D && shift) OpenTerminal(sender, e);
        else return; e.Handled = true;
    }
    void SystemThemeChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs e) => Dispatcher.BeginInvoke(() => { preferences.Apply(); if (SystemParameters.ClientAreaAnimation) trayClock.Start(); else trayClock.Stop(); });
    void ShowSettings(object sender, RoutedEventArgs e)
    {
        if (settings is null) { settings = new SettingsWindow(daemon, preferences); settings.Closed += (_, _) => settings = null; settings.Show(); if (relayStatus is JsonElement status) settings.ApplyStatus(status); } else settings.Activate();
    }
    void ApplyRelayStatus(JsonElement value) { relayStatus = value.Clone(); settings?.ApplyStatus(value); }
    async void Quit(object sender, RoutedEventArgs e)
    {
        if (closed) return; closed = true; lifetime.Cancel(); trayClock.Stop(); sidebarClock.Stop();
        if (subscription is not null) { try { await daemon.CallAsync("axo.session.unsubscribe", new { subscriptionId = subscription }); } catch { } }
        Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemThemeChanged;
        tray?.Dispose(); trayFrame?.Dispose(); mark?.Dispose(); settings?.Close(); Application.Current.Shutdown();
    }
}

public sealed class LaunchSplash : Window
{
    readonly ProgressBar progress = new() { Width = 120, Height = 4, Minimum = 0, Maximum = 1, Value = .25 };
    readonly Mascot mascot = new() { Artboard = "Loader", Width = 170, Height = 170 };
    public LaunchSplash()
    {
        Width = 240; Height = 230; WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false; ResizeMode = ResizeMode.NoResize; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var panel = new StackPanel { Margin = new Thickness(14, 16, 14, 26) }; panel.Children.Add(mascot); panel.Children.Add(progress); progress.Margin = new Thickness(0, 16, 0, 0);
        var card = new Border { CornerRadius = new CornerRadius(28), BorderThickness = new Thickness(.5), Child = panel }; card.SetResourceReference(Border.BackgroundProperty, "BackgroundBrush"); card.SetResourceReference(Border.BorderBrushProperty, "BorderBrush"); Content = card;
    }
    public async Task ReadyAsync() { progress.Value = 1; mascot.Artboard = "Happy"; if (SystemParameters.ClientAreaAnimation) { await Task.Delay(600); BeginAnimation(OpacityProperty, new System.Windows.Media.Animation.DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(350))); await Task.Delay(350); } }
}
