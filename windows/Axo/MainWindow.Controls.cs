using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace Axo;

public partial class MainWindow
{
    string deliveryMode = "followUp";
    readonly Dictionary<string, List<string>> fileDrafts = [];
    List<string> attachedFiles => selected is null ? [] : fileDrafts.TryGetValue(selected, out var files) ? files : fileDrafts[selected] = [];
    void UpdateComposerHint()
    {
        AttachmentSummary.Text = string.Join(", ", attachedFiles.Select(System.IO.Path.GetFileName));
        AttachmentSummary.Visibility = attachedFiles.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        Composer.ToolTip = attachedFiles.Count == 0 ? "Message Codex" : "Attached: " + AttachmentSummary.Text;
    }
    void AttachFiles(object sender, RoutedEventArgs e)
    {
        if (selected is null || sending) return;
        var dialog = new OpenFileDialog { Title = "Attach Files", Multiselect = true };
        if (dialog.ShowDialog(this) != true) return;
        if (attachedFiles.Count + dialog.FileNames.Length > 8) { ShowError("Attach up to eight files per message."); return; }
        attachedFiles.AddRange(dialog.FileNames); UpdateComposerHint(); Composer.Focus();
    }
    void ComposerMenu(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        foreach (var (name, value) in new[] { ("Queue after this turn", "followUp"), ("Steer this turn", "steer"), ("Interrupt and send", "interrupt") })
        {
            var item = new MenuItem { Header = name, IsChecked = deliveryMode == value }; item.Click += (_, _) => { deliveryMode = value; SendButton.ToolTip = name; }; menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        var models = new MenuItem { Header = "Model and Reasoning…", IsEnabled = selected is not null }; models.Click += ChooseModel; menu.Items.Add(models);
        var queued = new MenuItem { Header = "Queued Messages…", IsEnabled = selected is not null }; queued.Click += ShowQueue; menu.Items.Add(queued);
        foreach (var file in attachedFiles.ToArray()) { var item = new MenuItem { Header = "Remove " + System.IO.Path.GetFileName(file) }; var session = selected; item.Click += (_, _) => { if (selected == session) { attachedFiles.Remove(file); UpdateComposerHint(); } }; menu.Items.Add(item); }
        menu.PlacementTarget = (UIElement)sender; menu.IsOpen = true;
    }
    async void SplitDown(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        try { if (EmbeddedTerminal.Shells.Count == 0) await AttachTerminalAsync(selected); else { SetTerminalVisible(true); await EmbeddedTerminal.SplitAsync("down"); } }
        catch (Exception error) { ShowError(error.Message); }
    }
    async void CloseFocusedTerminal(object sender, RoutedEventArgs e) => await EmbeddedTerminal.CloseFocusedAsync();
    async void ChooseModel(object sender, RoutedEventArgs e)
    {
        var id = selected; if (id is null) return;
        try
        {
            var available = await daemon.CallAsync("axo.session.models", new { sessionId = id });
            var current = await daemon.CallAsync("axo.session.model", new { sessionId = id });
            var models = available.GetProperty("models").EnumerateArray().ToArray();
            var panel = new StackPanel { Margin = new Thickness(20) };
            var picker = new ComboBox { Margin = new Thickness(0, 6, 0, 14), DisplayMemberPath = "Label" };
            picker.Items.Add(new ModelOption("Codex default", null)); foreach (var model in models) picker.Items.Add(new ModelOption(model.GetProperty("displayName").GetString()!, model.GetProperty("model").GetString()));
            var effort = new ComboBox { Margin = new Thickness(0, 6, 0, 14) };
            picker.SelectionChanged += (_, _) =>
            {
                effort.Items.Clear(); effort.Items.Add("default");
                var model = models.FirstOrDefault(m => m.GetProperty("model").GetString() == (picker.SelectedItem as ModelOption)?.Id);
                if (model.ValueKind == JsonValueKind.Object) foreach (var choice in model.GetProperty("supportedReasoningEfforts").EnumerateArray()) effort.Items.Add(choice.GetProperty("reasoningEffort").GetString());
                effort.SelectedIndex = 0;
            };
            picker.SelectedItem = picker.Items.Cast<ModelOption>().FirstOrDefault(m => m.Id == (current.TryGetProperty("model", out var saved) ? saved.GetString() : null)) ?? picker.Items[0];
            if (current.TryGetProperty("effort", out var chosen) && chosen.ValueKind == JsonValueKind.String && effort.Items.Contains(chosen.GetString())) effort.SelectedItem = chosen.GetString();
            panel.Children.Add(new TextBlock { Text = "Model" }); panel.Children.Add(picker); panel.Children.Add(new TextBlock { Text = "Reasoning" }); panel.Children.Add(effort);
            panel.Children.Add(new TextBlock { Text = "Applies to the next turn in this session.", Margin = new Thickness(0, 0, 0, 14) });
            var save = new Button { Content = "Save", HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(14, 5, 14, 5) }; panel.Children.Add(save);
            var dialog = ControlDialog("Model and Reasoning", panel, 420, 300);
            save.Click += async (_, _) => { save.IsEnabled = false; try { await daemon.CallAsync("axo.session.model.set", new { sessionId = id, model = (picker.SelectedItem as ModelOption)?.Id, effort = effort.SelectedItem as string is string value && value != "default" ? value : null }); dialog.Close(); } catch (Exception error) { ShowError(error.Message); save.IsEnabled = true; } };
            dialog.ShowDialog();
        }
        catch (Exception error) { ShowError(error.Message); }
    }
    sealed record ModelOption(string Label, string? Id);
    Window ControlDialog(string title, UIElement content, double width, double height)
    {
        var dialog = new Window { Title = title, Owner = this, Content = content, Width = width, Height = height, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        dialog.SetResourceReference(BackgroundProperty, "BackgroundBrush"); dialog.SetResourceReference(ForegroundProperty, "TextBrush"); return dialog;
    }
    async void ShowQueue(object sender, RoutedEventArgs e)
    {
        var id = selected; if (id is null) return;
        try
        {
            var result = await daemon.CallAsync("axo.session.queue", new { sessionId = id });
            var panel = new StackPanel { Margin = new Thickness(16) };
            foreach (var message in result.GetProperty("messages").EnumerateArray())
            {
                var row = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
                string state = message.GetProperty("state").GetString()!;
                row.Children.Add(new TextBlock { Text = state == "submitting" ? "Delivery unconfirmed — inspect the conversation before resending." : state, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
                row.Children.Add(new TextBlock { Text = message.GetProperty("prompt").GetProperty("text").GetString(), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4) });
                var cancel = new Button { Content = "Remove", IsEnabled = state != "submitting", HorizontalAlignment = HorizontalAlignment.Left };
                string command = message.GetProperty("commandId").GetString()!;
                cancel.Click += async (_, _) => { try { await daemon.CallAsync("axo.session.queue.cancel", new { sessionId = id, commandId = command }); panel.Children.Remove(row); } catch (Exception error) { ShowError(error.Message); } };
                row.Children.Add(cancel); panel.Children.Add(row);
            }
            if (panel.Children.Count == 0) panel.Children.Add(new TextBlock { Text = "No queued messages." });
            ControlDialog("Queued Messages", new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, 520, 360).ShowDialog();
        }
        catch (Exception error) { ShowError(error.Message); }
    }
    sealed record PaletteOption(string Label, Action Run);
    void ShowPalette(object sender, RoutedEventArgs e)
    {
        // Snapshot visible IDs, as CommandPaletteCatalog/Performer do on Mac.
        var entries = new List<(string Label, Action Run)>();
        foreach (var s in allSessions.ToArray()) { var id = s.Id; entries.Add(($"{s.Name} — {s.Directory}", () => { var live = Sessions.FirstOrDefault(s => s.Id == id); if (live is not null) SessionList.SelectedItem = live; })); }
        entries.Add(("New Workspace…", () => OpenFolder(this, new()))); entries.Add(("New Session", () => ChooseNewSession(this, new())));
        var selectedId = selected;
        if (selectedId is not null)
        {
            entries.Add(("Split Right", () => { if (selected == selectedId) OpenTerminal(this, new()); }));
            entries.Add(("Split Down", () => { if (selected == selectedId) SplitDown(this, new()); }));
            foreach (int shell in EmbeddedTerminal.Shells) { int target = shell; entries.Add(($"Focus Terminal {target}", () => { if (selected == selectedId) EmbeddedTerminal.FocusShell(target); })); }
            entries.Add(("Model and Reasoning…", () => { if (selected == selectedId) ChooseModel(this, new()); }));
            entries.Add(("Queued Messages…", () => { if (selected == selectedId) ShowQueue(this, new()); }));
        }
        entries.Add(("Toggle Sidebar", () => ToggleSidebar(this, new()))); entries.Add(("Settings…", () => ShowSettings(this, new())));
        var search = new TextBox { Margin = new Thickness(12), Padding = new Thickness(8) };
        var list = new ListBox { Margin = new Thickness(12, 0, 12, 12), DisplayMemberPath = "Label" }; var panel = new DockPanel(); DockPanel.SetDock(search, Dock.Top); panel.Children.Add(search); panel.Children.Add(list);
        var dialog = ControlDialog("Command Palette", panel, 640, 420);
        void Refresh() { list.Items.Clear(); foreach (var entry in entries.Where(e => search.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(q => e.Label.Contains(q, StringComparison.OrdinalIgnoreCase)))) list.Items.Add(new PaletteOption(entry.Label, entry.Run)); if (list.Items.Count > 0) list.SelectedIndex = 0; }
        void Choose() { if (list.SelectedItem is not PaletteOption entry) return; var action = entry.Run; dialog.Close(); action(); }
        search.TextChanged += (_, _) => Refresh(); list.MouseDoubleClick += (_, _) => Choose();
        dialog.PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) { args.Handled = true; dialog.Close(); } else if (args.Key == Key.Enter) { args.Handled = true; Choose(); } else if (args.Key == Key.Down) { args.Handled = true; list.SelectedIndex = Math.Min(list.Items.Count - 1, list.SelectedIndex + 1); list.ScrollIntoView(list.SelectedItem); } else if (args.Key == Key.Up) { args.Handled = true; list.SelectedIndex = Math.Max(0, list.SelectedIndex - 1); list.ScrollIntoView(list.SelectedItem); } };
        dialog.Loaded += (_, _) => search.Focus(); Refresh(); dialog.ShowDialog();
    }
}
