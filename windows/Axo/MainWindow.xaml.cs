using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using System.Windows.Data;
using System.Windows.Media;
using Microsoft.Win32;

namespace Axo;

public partial class MainWindow : Window
{
    readonly DaemonClient daemon = new();
    readonly CancellationTokenSource lifetime = new();
    readonly Preferences preferences = Preferences.Load();
    readonly DispatcherTimer sidebarClock = new() { Interval = TimeSpan.FromSeconds(30) };
    readonly Dictionary<string, MessageView> messageIndex = [];
    readonly Dictionary<string, ComboBox> questionInputs = [];
    readonly Dictionary<string, string> drafts = [];
    public ObservableCollection<SessionView> Sessions { get; } = [];
    public ObservableCollection<MessageView> Messages { get; } = [];
    List<SessionView> allSessions = [];
    string? selected;
    long messageCursor;
    ulong eventCursor;
    bool refreshing, polling, sending, closed;
    string? subscription;
    JsonElement? pendingRequest;
    JsonElement[] computerQuestions = [];
    JsonElement lastPendingRequests = JsonSerializer.SerializeToElement(Array.Empty<object>());

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        preferences.Apply();
#pragma warning disable WPF0001
        // The workbench supplies its own title-bar drag strip; Fluent's automatic
        // title-bar layer would paint over the native application menus.
        ThemeMode = System.Windows.ThemeMode.None;
#pragma warning restore WPF0001
        var view = CollectionViewSource.GetDefaultView(Sessions); view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(SessionView.Group)));
        ApplySidebar();
        EmbeddedTerminal.Failed += ShowError;
        SetupTray();
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemThemeChanged;
        sidebarClock.Tick += (_, _) => { if (!SessionList.IsMouseOver) FilterSessions(); };
    }

    async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Opacity = 0;
        var splash = new LaunchSplash(); splash.Show();
        try
        {
            await daemon.EnsureStartedAsync();
            var negotiation = await daemon.CallAsync("axo.protocol.negotiate", new { protocolVersion = 2 });
            var methods = negotiation.GetProperty("methods").EnumerateArray().Select(m => m.GetString()).ToHashSet();
            if (!methods.Contains("axo.terminal.create") || !methods.Contains("axo.relay.link"))
                throw new InvalidOperationException("This daemon predates the Windows workbench and relay support. Use the matching Axo/axod build; running sessions were left in place.");
            DaemonStatus.Text = "●  axod is running";
            subscription = (await daemon.CallAsync("axo.session.subscribe", new { includeTerminalOutput = true })).GetProperty("subscriptionId").GetString();
            await RefreshCatalogAsync();
            ApplyRelayStatus(await daemon.CallAsync("axo.relay.status"));
            _ = CatalogEventsAsync();
            sidebarClock.Start();
            await splash.ReadyAsync();
        }
        catch (Exception error) { ShowError(error.Message); DaemonStatus.Text = "Daemon unavailable"; }
        finally { Opacity = 1; splash.Close(); Activate(); }
    }

    void OnClosing(object? sender, CancelEventArgs e) { if (!closed) { e.Cancel = true; Hide(); } }

    async Task CatalogEventsAsync()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                if (subscription is null)
                {
                    subscription = (await daemon.CallAsync("axo.session.subscribe", new { includeTerminalOutput = true }, lifetime.Token)).GetProperty("subscriptionId").GetString();
                    await RefreshCatalogAsync();
                    ApplyRelayStatus(await daemon.CallAsync("axo.relay.status"));
                    await RefreshComputerQuestionsAsync();
                }
                var batch = await daemon.CallAsync("axo.session.events.next", new { subscriptionId = subscription, timeoutMs = 25000, maxEvents = 128 }, lifetime.Token);
                bool catalog = false, agent = false, questions = false;
                foreach (var item in batch.GetProperty("events").EnumerateArray())
                {
                    var type = item.GetProperty("type").GetString();
                    if (type is "session.snapshot" or "session.removed" or "workspace.changed") catalog = true;
                    else if (type == "subscription.lagged") { catalog = true; agent = true; }
                    else if (type == "relay.status") ApplyRelayStatus(item.GetProperty("status"));
                    else if (type == "terminal.output") EmbeddedTerminal.Output(item);
                    else if (type is "elicitation.requested" or "elicitation.resolved") questions = true;
                    else if (type == "pi.event" && item.GetProperty("sessionId").GetString() == selected && item.GetProperty("name").GetString() == "codex.event") agent = true;
                }
                if (catalog) await RefreshCatalogAsync();
                if (agent) await PollAsync();
                if (questions) { await RefreshComputerQuestionsAsync(); await PollAsync(); }
                UpdateTray();
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
            catch (Exception error)
            {
                DaemonStatus.Text = "Reconnecting…"; ShowError(error.Message);
                if (subscription is not null) { try { await daemon.CallAsync("axo.session.unsubscribe", new { subscriptionId = subscription }); } catch { } }
                subscription = null;
                try { await Task.Delay(1500, lifetime.Token); } catch (OperationCanceledException) { break; }
            }
        }
    }

    async Task RefreshCatalogAsync()
    {
        if (refreshing || closed) return;
        refreshing = true;
        try
        {
            var workspaceResult = await daemon.CallAsync("axo.workspace.list");
            var workspaces = workspaceResult.GetProperty("workspaces").EnumerateArray().Select(w => new WorkspaceView(
                w.GetProperty("workspaceId").GetString()!, w.GetProperty("name").GetString()!, w.GetProperty("directoryPath").GetString()!)).ToList();
            var oldWorkspace = (WorkspacePicker.SelectedItem as WorkspaceView)?.Id;
            WorkspacePicker.ItemsSource = workspaces;
            WorkspacePicker.SelectedItem = workspaces.FirstOrDefault(w => w.Id == oldWorkspace) ?? workspaces.FirstOrDefault();
            var result = await daemon.CallAsync("axo.session.list");
            allSessions = result.GetProperty("sessions").EnumerateArray().Select(SessionView.From).ToList();
            FilterSessions();
            if (selected is null && Sessions.Count > 0) SessionList.SelectedItem = Sessions[0];
            NewSessionButton.IsEnabled = workspaces.Count > 0;
        }
        finally { refreshing = false; }
    }

    void FilterSessions()
    {
        foreach (var s in allSessions) s.Pinned = preferences.Pinned.Contains(s.Id);
        var filtered = allSessions.OrderBy(s => s.GroupOrder).ThenBy(s => s.Pinned ? preferences.Pinned.IndexOf(s.Id) : 0).ThenBy(s => s.Group == "Active" ? s.Name : "", StringComparer.CurrentCultureIgnoreCase).ThenByDescending(s => s.LastActive).ToList();
        EmptySidebar.Visibility = filtered.Count == 0 && !preferences.SidebarCollapsed ? Visibility.Visible : Visibility.Collapsed;
        // Keep the selected object and avoid rebuilding ListBox selection on every status poll.
        if (Sessions.Select(s => s.Id).SequenceEqual(filtered.Select(s => s.Id)))
        {
            foreach (var item in Sessions) item.Update(filtered.First(s => s.Id == item.Id));
            CollectionViewSource.GetDefaultView(Sessions).Refresh();
            return;
        }
        var previous = selected;
        Sessions.Clear();
        foreach (var item in filtered) Sessions.Add(item);
        SessionList.SelectedItem = Sessions.FirstOrDefault(s => s.Id == previous);
    }

    void OnWorkspaceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!refreshing) FilterSessions();
        if (!refreshing && SessionList.SelectedItem is null) SessionList.SelectedItem = Sessions.FirstOrDefault();
    }

    async void OnSessionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SessionList.SelectedItem is not SessionView session)
        {
            if (refreshing) return;
            ShowEmptySession();
            return;
        }
        if (selected == session.Id) return;
        if (selected is not null) drafts[selected] = Composer.Text;
        selected = session.Id;
        Composer.Text = drafts.GetValueOrDefault(selected, "");
        var id = selected;
        EmbeddedTerminal.Detach();
        messageCursor = 0; eventCursor = 0; messageIndex.Clear(); Messages.Clear();
        SessionTitle.Text = session.Name; WorkspacePath.Text = session.Directory;
        Welcome.Visibility = Visibility.Collapsed; ChatScroll.Visibility = Visibility.Visible;
        ApprovalPanel.Visibility = Visibility.Collapsed; pendingRequest = null;
        TerminalButton.IsEnabled = MoreButton.IsEnabled = true;
        Composer.IsEnabled = SendButton.IsEnabled = false;
        ActivityText.Text = "Connecting to Codex…";
        HideError();
        try
        {
            await LoadMessagesAsync(id);
            var snapshot = await daemon.CallAsync("axo.session.open", new { sessionId = id });
            if (selected != id || closed) return;
            UpdateStatus(snapshot.GetProperty("status").GetString() ?? "ready");
            ApplyPending(snapshot.GetProperty("pendingRequests"));
            await AttachTerminalAsync(id);
            Composer.Focus();
        }
        catch (Exception error) { if (selected == id) { ShowError(error.Message); ActivityText.Text = "Connection failed. Use ••• → Reconnect to retry."; } }
    }

    void ShowEmptySession()
    {
        if (selected is not null) drafts[selected] = Composer.Text;
        selected = null;
        Composer.Clear();
        Composer.IsEnabled = SendButton.IsEnabled = TerminalButton.IsEnabled = MoreButton.IsEnabled = false;
        Welcome.Visibility = Visibility.Visible;
        ChatScroll.Visibility = Visibility.Collapsed;
        pendingRequest = null;
        ApplyPending(JsonSerializer.SerializeToElement(Array.Empty<object>()));
        SessionTitle.Text = "Axo Terminal";
        WorkspacePath.Text = "";
        EmbeddedTerminal.Detach(); SetTerminalVisible(false);
    }

    async Task LoadMessagesAsync(string id)
    {
        while (selected == id && !closed)
        {
            var result = await daemon.CallAsync("axo.session.messages", new { sessionId = id, after = messageCursor });
            if (selected != id || closed) return;
            var messages = result.GetProperty("messages").EnumerateArray().ToArray();
            foreach (var message in messages)
            {
                messageCursor = Math.Max(messageCursor, message.GetProperty("sequence").GetInt64());
                var key = message.GetProperty("itemId").GetString()!;
                var row = GetMessage(key, message.GetProperty("role").GetString() == "user" ? "YOU" : "CODEX");
                row.Text = message.GetProperty("text").GetString() ?? ""; row.Complete = true;
            }
            if (messages.Length < 200) break;
        }
    }

    async Task PollAsync()
    {
        if (polling || closed) return;
        polling = true;
        try
        {
            var id = selected;
            if (id is null) return;
            var result = await daemon.CallAsync("axo.session.events.poll", new { sessionId = id, after = eventCursor });
            if (selected != id || closed) return;
            var atBottom = ChatScroll.ScrollableHeight - ChatScroll.VerticalOffset < 80;
            if (result.GetProperty("reset").GetBoolean()) eventCursor = 0;
            foreach (var envelope in result.GetProperty("events").EnumerateArray())
            {
                var sequence = envelope.GetProperty("sequence").GetUInt64();
                if (sequence <= eventCursor) continue;
                eventCursor = sequence;
                ApplyEvent(envelope.GetProperty("event"));
            }
            await LoadMessagesAsync(id);
            if (selected != id || closed) return;
            UpdateStatus(result.GetProperty("status").GetString() ?? "ready");
            ApplyPending(result.GetProperty("pendingRequests"));
            if (result.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String) ShowError(error.GetString()!);
            DaemonStatus.Text = "●  axod is running";
            if (atBottom) ChatScroll.ScrollToEnd();
        }
        catch (Exception error) { if (!closed) { DaemonStatus.Text = "Connection interrupted"; ShowError(error.Message); } }
        finally { polling = false; }
    }

    void ApplyEvent(JsonElement message)
    {
        var method = message.GetProperty("method").GetString();
        if (!message.TryGetProperty("params", out var p)) return;
        if (method == "item/agentMessage/delta")
        {
            var row = GetMessage(p.GetProperty("itemId").GetString()!, "CODEX");
            if (!row.Complete) row.Text += p.GetProperty("delta").GetString();
        }
        else if (method == "item/completed" || method == "item/started")
        {
            var item = p.GetProperty("item");
            var type = item.GetProperty("type").GetString();
            var key = item.GetProperty("id").GetString()!;
            if (type == "userMessage")
            {
                var row = GetMessage(key, "YOU");
                row.Text = string.Join("\n", item.GetProperty("content").EnumerateArray()
                    .Where(c => c.GetProperty("type").GetString() == "text").Select(c => c.GetProperty("text").GetString()));
                row.Complete = method == "item/completed";
            }
            else if (type == "agentMessage" && method == "item/completed")
            {
                var row = GetMessage(key, "CODEX"); row.Text = item.GetProperty("text").GetString() ?? ""; row.Complete = true;
            }
            else if (type == "commandExecution")
            {
                var command = item.TryGetProperty("command", out var c) ? c.GetString() : "Command";
                var row = GetMessage(key, "TERMINAL · " + command);
                if (item.TryGetProperty("aggregatedOutput", out var output) && output.ValueKind == JsonValueKind.String) row.Text = Tail(output.GetString()!);
                else if (row.Text.Length == 0) row.Text = "Running…";
                row.Complete = method == "item/completed";
            }
            else if (type == "fileChange" && method == "item/completed")
            {
                var row = GetMessage(key, "FILES");
                row.Text = item.TryGetProperty("changes", out var changes) ? string.Join("\n", changes.EnumerateArray().Select(c => c.GetProperty("path").GetString())) : "Files updated";
                row.Complete = true;
            }
        }
        else if (method == "item/commandExecution/outputDelta")
        {
            var row = GetMessage(p.GetProperty("itemId").GetString()!, "TERMINAL");
            if (!row.Complete) row.Text = Tail((row.Text == "Running…" ? "" : row.Text) + p.GetProperty("delta").GetString());
        }
    }

    static string Tail(string text) => text.Length > 32000 ? "…\n" + text[^32000..] : text;
    MessageView GetMessage(string id, string label)
    {
        if (messageIndex.TryGetValue(id, out var existing)) return existing;
        var row = new MessageView(label); messageIndex[id] = row; Messages.Add(row); return row;
    }

    void UpdateStatus(string status)
    {
        var working = status is "working" or "needsAttention";
        ActivityText.Text = status switch { "working" => "Codex · working…", "needsAttention" => "Codex · needs input", "unavailable" => "Codex · disconnected", _ => "Codex" };
        Composer.IsEnabled = selected is not null && status != "unavailable";
        SendButton.IsEnabled = Composer.IsEnabled && !working && !sending;
        StopButton.Visibility = working ? Visibility.Visible : Visibility.Collapsed;
        if (SessionList.SelectedItem is SessionView session) session.Status = status;
        Title = (SessionList.SelectedItem as SessionView)?.Name is string name ? name + " — Axo Terminal" : "Axo Terminal";
        UpdateTray();
    }

    void ApplyPending(JsonElement requests)
    {
        lastPendingRequests = requests.Clone();
        var request = requests.EnumerateArray().FirstOrDefault();
        if (computerQuestions.FirstOrDefault() is var computerQuestion && computerQuestion.ValueKind == JsonValueKind.Object)
            request = JsonSerializer.SerializeToElement(new { id = computerQuestion.GetProperty("id").GetString(), method = "axo.computer.confirm", @params = new { message = computerQuestion.GetProperty("message").GetString() } });
        if (request.ValueKind != JsonValueKind.Object)
        {
            pendingRequest = null; ApprovalPanel.Visibility = Visibility.Collapsed; return;
        }
        if (pendingRequest is JsonElement previous && previous.GetProperty("id").GetRawText() == request.GetProperty("id").GetRawText()) return;
        pendingRequest = request.Clone();
        questionInputs.Clear(); QuestionFields.Children.Clear();
        ApprovalPanel.Visibility = Visibility.Visible;
        var method = request.GetProperty("method").GetString();
        var parameters = request.GetProperty("params");
        ApproveButton.Visibility = Visibility.Visible; ApproveButton.Content = "Allow once"; DeclineButton.Visibility = Visibility.Visible; DeclineButton.Content = "Decline";
        if (method == "axo.computer.confirm")
        {
            ApprovalTitle.Text = "Allow computer use?"; ApprovalDetail.Text = parameters.GetProperty("message").GetString();
        }
        else if (method == "item/tool/requestUserInput")
        {
            ApprovalTitle.Text = "Codex has a question"; ApprovalDetail.Text = "";
            ApproveButton.Content = "Send answers"; DeclineButton.Visibility = Visibility.Collapsed;
            foreach (var question in parameters.GetProperty("questions").EnumerateArray())
            {
                QuestionFields.Children.Add(new TextBlock { Text = question.GetProperty("question").GetString(), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
                var input = new ComboBox { IsEditable = true, Margin = new Thickness(0, 0, 0, 12), Padding = new Thickness(8) };
                if (question.TryGetProperty("options", out var options) && options.ValueKind == JsonValueKind.Array)
                    foreach (var option in options.EnumerateArray()) input.Items.Add(option.GetProperty("label").GetString());
                questionInputs[question.GetProperty("id").GetString()!] = input; QuestionFields.Children.Add(input);
            }
        }
        else if (method is "item/commandExecution/requestApproval" or "item/fileChange/requestApproval")
        {
            ApprovalTitle.Text = method.Contains("commandExecution") ? "Allow this command?" : "Allow these file changes?";
            ApprovalDetail.Text = parameters.TryGetProperty("command", out var command) && command.ValueKind == JsonValueKind.String ? command.GetString() : parameters.GetRawText();
            if (parameters.TryGetProperty("reason", out var reason) && reason.ValueKind == JsonValueKind.String) ApprovalDetail.Text += "\n" + reason.GetString();
        }
        else
        {
            ApprovalTitle.Text = "Codex requested an unsupported interaction";
            ApprovalDetail.Text = method + "\n" + parameters.GetRawText();
            ApproveButton.Visibility = Visibility.Collapsed; DeclineButton.Content = "Dismiss request";
        }
    }

    async void OpenFolder(object sender, RoutedEventArgs e)
    {
        var picker = new OpenFolderDialog { Title = "Open a workspace in Axo" };
        if (picker.ShowDialog(this) != true) return;
        var creation = new WorkspaceNameSheet(picker.FolderName) { Owner = this };
        if (creation.ShowDialog() != true) return;
        try
        {
            HideError();
            var folder = creation.Directory;
            var name = creation.WorkspaceName;
            var result = await daemon.CallAsync("axo.workspace.create", new { name, directoryPath = folder });
            await RefreshCatalogAsync();
            var workspace = result.GetProperty("workspace").GetProperty("workspaceId").GetString();
            WorkspacePicker.SelectedValue = workspace; FilterSessions();
            SessionList.SelectedItem = Sessions.FirstOrDefault(s => s.Id == result.GetProperty("session").GetProperty("id").GetString());
        }
        catch (Exception error) { ShowError(error.Message); }
    }

    async void NewSession(object sender, RoutedEventArgs e)
    {
        if (WorkspacePicker.SelectedItem is not WorkspaceView workspace) return;
        try
        {
            var session = await daemon.CallAsync("axo.workspace.session.create", new { workspaceId = workspace.Id });
            await RefreshCatalogAsync();
            SessionList.SelectedItem = Sessions.First(s => s.Id == session.GetProperty("id").GetString());
        }
        catch (Exception error) { ShowError(error.Message); }
    }

    async void Send(object sender, RoutedEventArgs e) => await SendAsync();
    async void ComposerKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { e.Handled = true; if (SendButton.IsEnabled) await SendAsync(); }
    }
    async Task SendAsync()
    {
        var id = selected; var text = Composer.Text.Trim();
        if (id is null || text.Length == 0 || sending) return;
        sending = true; SendButton.IsEnabled = false; HideError();
        try
        {
            await daemon.CallAsync("axo.session.prompt", new { sessionId = id, text, delivery = "turn" });
            drafts.Remove(id);
            if (selected == id) { if (Composer.Text.Trim() == text) Composer.Clear(); UpdateStatus("working"); ChatScroll.ScrollToEnd(); }
        }
        catch (Exception error) { ShowError(error.Message); }
        finally { sending = false; }
    }
    async void StopTurn(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        try { await daemon.CallAsync("axo.session.interrupt", new { sessionId = selected }); }
        catch (Exception error) { ShowError(error.Message); }
    }
    async void OpenTerminal(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        try { await AttachTerminalAsync(selected); EmbeddedTerminal.Focus(); }
        catch (Exception error) { ShowError(error.Message); }
    }
    async void Approve(object sender, RoutedEventArgs e) => await RespondAsync("accept");
    async void Decline(object sender, RoutedEventArgs e) => await RespondAsync("decline");
    async Task RespondAsync(string decision)
    {
        if (pendingRequest is not JsonElement request) return;
        var answers = questionInputs.ToDictionary(k => k.Key, k => new { answers = new[] { k.Value.Text } });
        try
        {
            if (request.GetProperty("method").GetString() == "axo.computer.confirm")
            {
                await daemon.CallAsync("axo.elicitation.resolve", new { elicitationId = request.GetProperty("id").GetString(), action = decision });
                pendingRequest = null;
                lastPendingRequests = JsonSerializer.SerializeToElement(Array.Empty<object>());
                await RefreshComputerQuestionsAsync();
                await PollAsync();
            }
            else
            {
                if (selected is null) return;
                await daemon.CallAsync("axo.session.approval.respond", new { sessionId = selected, requestId = request.GetProperty("id").GetRawText(), decision, answers });
            }
            if (request.GetProperty("method").GetString() != "axo.computer.confirm") { pendingRequest = null; ApprovalPanel.Visibility = Visibility.Collapsed; }
        }
        catch (Exception error) { ShowError(error.Message); }
    }

    async Task RefreshComputerQuestionsAsync()
    {
        try
        {
            var pending = await daemon.CallAsync("axo.elicitation.list");
            computerQuestions = pending.GetProperty("elicitations").EnumerateArray().OrderBy(q => q.GetProperty("createdAt").GetInt64()).Select(q => q.Clone()).ToArray();
            ApplyPending(lastPendingRequests);
        }
        catch (IOException) { computerQuestions = []; } // Compatibility with an older running daemon.
    }

    void ShowSessionMenu(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        var menu = new ContextMenu();
        var pin = new MenuItem { Header = preferences.Pinned.Contains(selected) ? "Unpin" : "Pin" };
        pin.Click += (_, _) => { if (selected is null) return; if (preferences.Pinned.Contains(selected)) preferences.Pinned.Remove(selected); else preferences.Pinned.Add(selected); preferences.Save(); FilterSessions(); };
        var copy = new MenuItem { Header = "Copy Session Info" }; copy.Click += (_, _) => Clipboard.SetText($"Session: {selected}\n{WorkspacePath.Text}\nAgent: Codex");
        menu.Items.Add(pin); menu.Items.Add(copy); menu.Items.Add(new Separator());
        var reconnect = new MenuItem { Header = "Reconnect" };
        reconnect.Click += async (_, _) =>
        {
            try { var id = selected; await daemon.EnsureStartedAsync(); eventCursor = 0; var result = await daemon.CallAsync("axo.session.open", new { sessionId = id }); if (id == selected) { HideError(); UpdateStatus(result.GetProperty("status").GetString()!); } }
            catch (Exception error) { ShowError(error.Message); }
        };
        var rename = new MenuItem { Header = "Rename session…" };
        rename.Click += async (_, _) =>
        {
            var input = new TextBox { Text = SessionTitle.Text, Margin = new Thickness(16), MinWidth = 310 };
            var button = new Button { Content = "Save", IsDefault = true, Margin = new Thickness(16, 0, 16, 16), HorizontalAlignment = HorizontalAlignment.Right };
            var panel = new StackPanel(); panel.Children.Add(input); panel.Children.Add(button);
            var dialog = new Window { Title = "Rename session", Owner = this, Content = panel, SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner };
            button.Click += (_, _) => { dialog.DialogResult = true; };
            if (dialog.ShowDialog() != true) return;
            try { await daemon.CallAsync("axo.session.rename", new { sessionId = selected, name = input.Text }); SessionTitle.Text = input.Text.Trim(); await RefreshCatalogAsync(); }
            catch (Exception error) { ShowError(error.Message); }
        };
        var close = new MenuItem { Header = "Archive" };
        close.Click += async (_, _) =>
        {
            try
            {
                await daemon.CallAsync("axo.session.close", new { sessionId = selected });
                selected = null;
                await RefreshCatalogAsync();
                if (Sessions.Count == 0) ShowEmptySession();
            }
            catch (Exception error) { ShowError(error.Message); }
        };
        menu.Items.Add(reconnect); menu.Items.Add(rename); menu.Items.Add(new Separator()); menu.Items.Add(close);
        menu.PlacementTarget = MoreButton; menu.IsOpen = true;
    }
    void ShowError(string message) { ErrorText.Text = message; ErrorBanner.Visibility = Visibility.Visible; }
    void HideError() { ErrorBanner.Visibility = Visibility.Collapsed; }
}

public sealed record WorkspaceView(string Id, string Name, string Directory);
public sealed class SessionView : INotifyPropertyChanged
{
    public required string Id { get; init; }
    public required string WorkspaceId { get; init; }
    public required string Directory { get; init; }
    string name = "", status = "ready";
    public string Name { get => name; set { name = value; Changed(); } }
    public string Status { get => status; set { if (status == value) return; status = value; Changed(); Changed(nameof(StatusLabel)); Changed(nameof(StatusSymbol)); Changed(nameof(StatusBrush)); Changed(nameof(Tooltip)); } }
    public string StatusLabel => "Codex · " + ReadableStatus(Status);
    public bool Pinned { get; set; }
    public long LastActive { get; set; }
    public string Group => Pinned ? "Pinned" : Status is "working" or "needsAttention" || DateTimeOffset.UtcNow.ToUnixTimeSeconds() - LastActive < 180 ? "Active" : "Earlier";
    public int GroupOrder => Pinned ? 0 : Group == "Active" ? 1 : 2;
    public string Glyph { get; set; } = "✧";
    public string Age { get { var seconds = Math.Max(0, DateTimeOffset.UtcNow.ToUnixTimeSeconds() - LastActive); return seconds < 60 ? "now" : seconds < 3600 ? $"{seconds / 60}m" : seconds < 86400 ? $"{seconds / 3600}h" : $"{seconds / 86400}d"; } }
    public string StatusSymbol => Status switch { "working" => "⚒", "needsAttention" => "▲", "starting" or "unavailable" => "◌", _ => "●" };
    public Brush StatusBrush => Status switch { "working" => SystemColors.HighlightBrush, "needsAttention" => Brushes.Goldenrod, "starting" or "unavailable" => SystemColors.GrayTextBrush, _ => Brushes.ForestGreen };
    public string Tooltip => $"{Name}\n{Directory}\n{StatusLabel}";
    public static string ReadableStatus(string? status) => status == "needsAttention" ? "needs attention" : status ?? "ready";
    public static SessionView From(JsonElement s) => new() { Id = s.GetProperty("id").GetString()!, WorkspaceId = s.GetProperty("workspaceId").GetString()!, Directory = s.GetProperty("initialPwd").GetString()!, Name = s.GetProperty("name").GetString()!, Status = s.GetProperty("status").GetString() ?? "ready", LastActive = s.TryGetProperty("lastMessageAt", out var at) && at.ValueKind == JsonValueKind.Number ? at.GetInt64() : s.GetProperty("createdAt").GetInt64(), Glyph = s.TryGetProperty("emoji", out var emoji) && emoji.ValueKind == JsonValueKind.String ? emoji.GetString()! : "✧" };
    public void Update(SessionView other) { Name = other.Name; Status = other.Status; LastActive = other.LastActive; Pinned = other.Pinned; Changed(nameof(Age)); Changed(nameof(Group)); }
    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
}
public sealed class MessageView(string label) : INotifyPropertyChanged
{
    string text = "";
    public string Label { get; } = label;
    public string Text { get => text; set { text = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Text))); } }
    public bool Complete { get; set; }
    public event PropertyChangedEventHandler? PropertyChanged;
}
