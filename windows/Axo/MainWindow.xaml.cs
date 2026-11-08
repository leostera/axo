using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Axo;

public partial class MainWindow : Window
{
    readonly DaemonClient daemon = new();
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(300) };
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
    int ticks;
    JsonElement? pendingRequest;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        timer.Tick += async (_, _) => await PollAsync();
    }

    async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            await daemon.EnsureStartedAsync();
            var negotiation = await daemon.CallAsync("axo.protocol.negotiate", new { protocolVersion = 1 });
            if (!negotiation.GetProperty("methods").EnumerateArray().Any(m => m.GetString() == "axo.session.open"))
                throw new InvalidOperationException("This daemon does not support the Windows Codex client.");
            DaemonStatus.Text = "●  axod is running";
            await RefreshCatalogAsync();
            timer.Start();
        }
        catch (Exception error) { ShowError(error.Message); DaemonStatus.Text = "Daemon unavailable"; }
    }

    void OnClosing(object? sender, CancelEventArgs e) { closed = true; timer.Stop(); }

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
        var workspace = WorkspacePicker.SelectedItem as WorkspaceView;
        var filtered = allSessions.Where(s => s.WorkspaceId == workspace?.Id).ToList();
        // Keep the selected object and avoid rebuilding ListBox selection on every status poll.
        if (Sessions.Select(s => s.Id).SequenceEqual(filtered.Select(s => s.Id)))
        {
            foreach (var item in Sessions) item.Update(filtered.First(s => s.Id == item.Id));
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
        ApprovalPanel.Visibility = Visibility.Collapsed;
        SessionTitle.Text = "A place to work with Codex";
        WorkspacePath.Text = "Open a folder to start a session.";
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
            if (++ticks % 7 == 0) await RefreshCatalogAsync();
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
        ActivityText.Text = status switch { "working" => "Codex is working…", "needsAttention" => "Codex is waiting for your input.", "unavailable" => "Codex disconnected. Use ••• → Reconnect.", _ => Messages.Count > 0 ? "Ready for your next message." : "Tell Codex what you would like to build." };
        Composer.IsEnabled = selected is not null && status != "unavailable";
        SendButton.IsEnabled = Composer.IsEnabled && !working && !sending;
        StopButton.Visibility = working ? Visibility.Visible : Visibility.Collapsed;
        if (SessionList.SelectedItem is SessionView session) session.StatusLabel = "Codex · " + SessionView.ReadableStatus(status);
    }

    void ApplyPending(JsonElement requests)
    {
        var request = requests.EnumerateArray().FirstOrDefault();
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
        if (method == "item/tool/requestUserInput")
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
        try
        {
            HideError();
            var folder = picker.FolderName;
            var name = System.IO.Path.GetFileName(folder.TrimEnd(System.IO.Path.DirectorySeparatorChar));
            if (string.IsNullOrEmpty(name)) name = folder;
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
        try { await daemon.CallAsync("axo.terminal.open", new { sessionId = selected }); }
        catch (Exception error) { ShowError(error.Message); }
    }
    async void Approve(object sender, RoutedEventArgs e) => await RespondAsync("accept");
    async void Decline(object sender, RoutedEventArgs e) => await RespondAsync("decline");
    async Task RespondAsync(string decision)
    {
        if (pendingRequest is not JsonElement request || selected is null) return;
        var answers = questionInputs.ToDictionary(k => k.Key, k => new { answers = new[] { k.Value.Text } });
        try
        {
            await daemon.CallAsync("axo.session.approval.respond", new { sessionId = selected, requestId = request.GetProperty("id").GetRawText(), decision, answers });
            pendingRequest = null; ApprovalPanel.Visibility = Visibility.Collapsed;
        }
        catch (Exception error) { ShowError(error.Message); }
    }

    void ShowSessionMenu(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        var menu = new ContextMenu();
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
        var close = new MenuItem { Header = "Close session" };
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
    string name = "", status = "";
    public string Name { get => name; set { name = value; Changed(); } }
    public string StatusLabel { get => status; set { status = value; Changed(); } }
    public static string ReadableStatus(string? status) => status == "needsAttention" ? "needs attention" : status ?? "ready";
    public static SessionView From(JsonElement s) => new() { Id = s.GetProperty("id").GetString()!, WorkspaceId = s.GetProperty("workspaceId").GetString()!, Directory = s.GetProperty("initialPwd").GetString()!, Name = s.GetProperty("name").GetString()!, StatusLabel = "Codex · " + ReadableStatus(s.GetProperty("status").GetString()) };
    public void Update(SessionView other) { Name = other.Name; StatusLabel = other.StatusLabel; }
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
