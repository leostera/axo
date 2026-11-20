using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace Axo;

/// The same pane/split tree as AxoProtocol.LayoutNode. Axod owns every shell and layout.
public sealed class TerminalWorkspace : Grid
{
    readonly Dictionary<int, TerminalView> views = [];
    DaemonClient? daemon;
    string? session;
    JsonNode? layout;
    int generation, focused;
    bool changing, attaching;
    public event Action<string>? Failed;
    public IReadOnlyCollection<int> Shells => views.Keys;
    public int FocusedShell => focused;
    public async Task AttachAsync(DaemonClient client, string id)
    {
        Detach(); attaching = true; var version = generation; daemon = client; session = id;
        var snapshot = await client.CallAsync("axo.session.open", new { sessionId = id });
        if (version != generation) return;
        if (snapshot.GetProperty("shells").GetArrayLength() == 0)
        {
            await client.CallAsync("axo.terminal.create", new { sessionId = id });
            snapshot = await client.CallAsync("axo.session.open", new { sessionId = id });
        }
        if (version != generation) return;
        layout = JsonNode.Parse(snapshot.GetProperty("layout").GetRawText());
        foreach (var shell in snapshot.GetProperty("shells").EnumerateArray())
        {
            int number = shell.GetProperty("id").GetInt32();
            var view = AddView(number);
            await view.AttachAsync(client, id, number);
            if (version != generation) return;
        }
        Rebuild(); attaching = false;
    }
    public async Task SynchronizeAsync(JsonElement snapshot)
    {
        if (changing || attaching || daemon is null || session != snapshot.GetProperty("id").GetString()) return;
        var version = generation; var id = session;
        var ids = snapshot.GetProperty("shells").EnumerateArray().Select(s => s.GetProperty("id").GetInt32()).ToHashSet();
        string value = snapshot.GetProperty("layout").GetRawText();
        if (ids.SetEquals(views.Keys) && JsonNode.DeepEquals(layout, JsonNode.Parse(value))) return;
        foreach (int missing in views.Keys.Where(k => !ids.Contains(k)).ToArray()) { views[missing].Detach(); views.Remove(missing); }
        foreach (int added in ids.Where(k => !views.ContainsKey(k))) { var view = AddView(added); await view.AttachAsync(daemon, id!, added); if (version != generation) return; }
        layout = JsonNode.Parse(value); if (!views.ContainsKey(focused)) focused = views.Keys.FirstOrDefault(); Rebuild();
    }
    TerminalView AddView(int shell)
    {
        var view = new TerminalView(); views.Add(shell, view);
        view.Failed += message => Failed?.Invoke(message);
        view.GotKeyboardFocus += (_, _) => focused = shell;
        System.Windows.Automation.AutomationProperties.SetName(view, $"Terminal {shell}");
        if (focused == 0) focused = shell;
        return view;
    }
    public void Detach()
    {
        generation++; attaching = false; foreach (var view in views.Values) view.Detach();
        views.Clear(); Children.Clear(); layout = null; session = null; focused = 0;
    }
    public void Output(JsonElement e) { foreach (var view in views.Values) view.Output(e); }
    public new bool Focus() => FocusShell(focused);
    public bool FocusShell(int shell) => views.TryGetValue(shell, out var view) && view.Focus();
    public async Task SplitAsync(string direction)
    {
        var client = daemon; var id = session; var version = generation; int anchor = focused;
        if (client is null || id is null || layout is null || changing) return;
        changing = true;
        try
        {
            var created = await client.CallAsync("axo.shell.create", new { sessionId = id });
            if (version != generation) return;
            int shell = created.GetProperty("shellId").GetInt32();
            var view = AddView(shell); await view.AttachAsync(client, id, shell);
            if (version != generation) return;
            layout = Insert(layout, anchor, shell, direction);
            await SaveAsync(id); Rebuild(); view.Focus();
        }
        catch (Exception error) { Failed?.Invoke(error.Message); if (version == generation) await AttachAsync(client, id); }
        finally { changing = false; }
    }
    public async Task CloseFocusedAsync()
    {
        var client = daemon; var id = session; var version = generation; int shell = focused;
        if (client is null || id is null || !views.ContainsKey(shell) || changing) return;
        if (MessageBox.Show($"Close Terminal {shell}? Any commands running in this pane will stop.", "Close Terminal", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        changing = true;
        try
        {
            await client.CallAsync("axo.terminal.close", new { sessionId = id, shellId = shell });
            if (version != generation) return;
            views[shell].Detach(); views.Remove(shell); layout = Prune(layout, shell); focused = views.Keys.FirstOrDefault(); Rebuild(); Focus();
        }
        catch (Exception error) { Failed?.Invoke(error.Message); }
        finally { changing = false; }
    }
    Task SaveAsync(string id) => daemon!.CallAsync("axo.session.layout.set", new { sessionId = id, layout });
    static JsonNode Insert(JsonNode node, int anchor, int shell, string direction)
    {
        if ((string?)node["kind"] == "pane")
            return (int?)node["shellId"] == anchor ? new JsonObject { ["kind"] = "split", ["id"] = Guid.NewGuid().ToString(), ["direction"] = direction, ["ratio"] = .5, ["first"] = node.DeepClone(), ["second"] = new JsonObject { ["kind"] = "pane", ["shellId"] = shell } } : node.DeepClone();
        var result = node.DeepClone(); result["first"] = Insert(node["first"]!, anchor, shell, direction); result["second"] = Insert(node["second"]!, anchor, shell, direction); return result;
    }
    static JsonNode? Prune(JsonNode? node, int shell)
    {
        if (node is null) return null;
        if ((string?)node["kind"] == "pane") return (int?)node["shellId"] == shell ? null : node.DeepClone();
        var first = Prune(node["first"], shell); var second = Prune(node["second"], shell);
        if (first is null) return second; if (second is null) return first;
        var result = node.DeepClone(); result["first"] = first; result["second"] = second; return result;
    }
    void Rebuild()
    {
        foreach (var view in views.Values) if (view.Parent is Panel parent) parent.Children.Remove(view);
        Children.Clear(); if (layout is not null) Children.Add(Render(layout));
    }
    UIElement Render(JsonNode node)
    {
        if ((string?)node["kind"] == "pane") return views[(int)node["shellId"]!];
        var grid = new Grid(); bool horizontal = (string?)node["direction"] == "right"; double ratio = Math.Clamp((double?)node["ratio"] ?? .5, .01, .99);
        if (horizontal) foreach (var length in new[] { new GridLength(ratio, GridUnitType.Star), new GridLength(1), new GridLength(1 - ratio, GridUnitType.Star) }) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = length });
        else foreach (var length in new[] { new GridLength(ratio, GridUnitType.Star), new GridLength(1), new GridLength(1 - ratio, GridUnitType.Star) }) grid.RowDefinitions.Add(new RowDefinition { Height = length });
        var first = Render(node["first"]!); var second = Render(node["second"]!);
        var divider = new GridSplitter { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch, ResizeDirection = horizontal ? GridResizeDirection.Columns : GridResizeDirection.Rows, ResizeBehavior = GridResizeBehavior.PreviousAndNext };
        divider.SetResourceReference(BackgroundProperty, "BorderBrush");
        if (horizontal) { SetColumn(divider, 1); SetColumn(second, 2); } else { SetRow(divider, 1); SetRow(second, 2); }
        var id = session; var version = generation;
        divider.DragCompleted += async (_, _) =>
        {
            if (session != id || version != generation || id is null) return;
            var a = horizontal ? grid.ColumnDefinitions[0].ActualWidth : grid.RowDefinitions[0].ActualHeight;
            var b = horizontal ? grid.ColumnDefinitions[2].ActualWidth : grid.RowDefinitions[2].ActualHeight;
            node["ratio"] = Math.Clamp(a / Math.Max(1, a + b), .01, .99);
            try { await SaveAsync(id); } catch (Exception e) { Failed?.Invoke(e.Message); }
        };
        grid.Children.Add(first); grid.Children.Add(divider); grid.Children.Add(second); return grid;
    }
}
