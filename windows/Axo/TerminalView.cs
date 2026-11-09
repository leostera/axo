using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;

namespace Axo;

/// <summary>A native WPF VT surface for the daemon's ConPTY. The daemon owns the
/// shell and bounded replay, so hiding or recreating a view preserves its process.</summary>
public sealed class TerminalView : FrameworkElement
{
    readonly VtScreen screen = new();
    readonly Decoder decoder = Encoding.UTF8.GetDecoder();
    readonly SemaphoreSlim inputLock = new(1, 1);
    readonly SortedDictionary<ulong, byte[]> pending = [];
    DaemonClient? daemon;
    string? session;
    int shell;
    ulong inputSequence, outputSequence;
    int generation;
    bool attaching;
    double cellWidth = 8, cellHeight = 17;
    int scroll;
    Point? selectionStart, selectionEnd;
    readonly Typeface font = new("Cascadia Mono, Consolas");
    public event Action<string>? Failed;
    public bool Attached => session is not null;
    public string ScreenText => string.Join("\n", screen.Visible(scroll).Select(row => string.Concat(row.Select(c => c.Text)).TrimEnd()));
    protected override AutomationPeer OnCreateAutomationPeer() => new TerminalAutomationPeer(this);
    public TerminalView()
    {
        Focusable = true; ClipToBounds = true;
        screen.Reply += text => _ = WriteAsync(text);
        SizeChanged += async (_, _) => await ResizeAsync();
        var menu = new System.Windows.Controls.ContextMenu();
        var copy = new System.Windows.Controls.MenuItem { Header = "Copy", InputGestureText = "Ctrl+Shift+C" }; copy.Click += (_, _) => Copy();
        var paste = new System.Windows.Controls.MenuItem { Header = "Paste", InputGestureText = "Ctrl+Shift+V" }; paste.Click += async (_, _) => await PasteAsync();
        menu.Items.Add(copy); menu.Items.Add(paste); ContextMenu = menu;
    }
    public async Task AttachAsync(DaemonClient client, string id, int shellId = 0)
    {
        var current = ++generation; daemon = client; session = id; shell = shellId; attaching = true; pending.Clear(); decoder.Reset(); screen.Reset(); scroll = 0;
        try
        {
            var result = shellId == 0 ? await client.CallAsync("axo.terminal.create", new { sessionId = id }) : await client.CallAsync("axo.terminal.replay", new { sessionId = id, shellId });
            if (current != generation) return;
            shell = result.GetProperty("shellId").GetInt32(); inputSequence = result.GetProperty("nextInputSequence").GetUInt64(); outputSequence = 0;
            foreach (var chunk in result.GetProperty("chunks").EnumerateArray())
            { Append(Convert.FromBase64String(chunk.GetProperty("data").GetString()!)); outputSequence = chunk.GetProperty("sequence").GetUInt64() + 1; }
            outputSequence = result.GetProperty("nextOutputSequence").GetUInt64(); attaching = false;
            foreach (var (seq, bytes) in pending) if (seq >= outputSequence) { Append(bytes); outputSequence = seq + 1; }
            pending.Clear(); await ResizeAsync(true); InvalidateVisual();
        }
        catch (Exception error) { if (current == generation) { attaching = false; Failed?.Invoke(error.Message); } }
    }
    public void Detach() { generation++; session = null; shell = 0; pending.Clear(); screen.Reset(); InvalidateVisual(); }
    public void Output(JsonElement e)
    {
        if (e.GetProperty("sessionId").GetString() != session) return;
        var number = e.GetProperty("shellId").GetInt32(); if (shell != 0 && shell != number) return;
        var sequence = e.GetProperty("sequence").GetUInt64();
        if (sequence < outputSequence && !attaching) return;
        var bytes = Convert.FromBase64String(e.GetProperty("data").GetString()!);
        if (attaching) { if (pending.Count < 512) pending[sequence] = bytes; return; }
        if (sequence != outputSequence) { _ = ReplayAsync(); return; }
        outputSequence = sequence + 1; Append(bytes); InvalidateVisual();
    }
    async Task ReplayAsync() { if (daemon is not null && session is not null && !attaching) await AttachAsync(daemon, session, shell); }
    void Append(byte[] bytes)
    {
        var chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
        var count = decoder.GetChars(bytes, 0, bytes.Length, chars, 0, false); screen.Feed(new string(chars, 0, count));
    }
    async Task ResizeAsync(bool force = false)
    {
        if (ActualWidth < 20 || ActualHeight < 20) return;
        var sample = new FormattedText("M", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, font, 13, Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip);
        cellWidth = sample.WidthIncludingTrailingWhitespace; cellHeight = Math.Ceiling(sample.Height + 1);
        var columns = Math.Clamp((int)((ActualWidth - 4) / cellWidth), 1, 1000); var rows = Math.Clamp((int)((ActualHeight - 20) / cellHeight), 1, 500);
        if (!force && screen.Columns == columns && screen.Rows == rows) return;
        if (screen.Columns != columns || screen.Rows != rows) screen.Resize(columns, rows); InvalidateVisual();
        if (daemon is null || session is null || shell == 0) return;
        try { await daemon.CallAsync("axo.terminal.resize", new { sessionId = session, shellId = shell, rows, columns }); } catch (Exception e) { Failed?.Invoke(e.Message); }
    }
    async Task WriteAsync(string text)
    {
        var id = session; var pane = shell; var current = generation;
        if (daemon is null || id is null || pane == 0) return;
        await inputLock.WaitAsync();
        try
        {
            if (current != generation) return;
            await daemon.CallAsync("axo.terminal.input", new { sessionId = id, shellId = pane, sequence = inputSequence, data = Convert.ToBase64String(Encoding.UTF8.GetBytes(text)) }); if (current == generation) inputSequence++;
        }
        catch (Exception e) { Failed?.Invoke(e.Message); }
        finally { inputLock.Release(); }
    }
    protected override void OnTextInput(TextCompositionEventArgs e) { base.OnTextInput(e); if (e.Text.Length > 0) { e.Handled = true; scroll = 0; _ = WriteAsync(e.Text); } }
    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e); var control = Keyboard.Modifiers.HasFlag(ModifierKeys.Control) && !Keyboard.Modifiers.HasFlag(ModifierKeys.Alt); var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        if (control && shift && e.Key == Key.C) { Copy(); e.Handled = true; return; }
        if (control && shift && e.Key == Key.V) { _ = PasteAsync(); e.Handled = true; return; }
        string? text = e.Key switch { Key.Enter => "\r", Key.Back => "\u007f", Key.Tab => shift ? "\x1b[Z" : "\t", Key.Escape => "\x1b", Key.Up => "\x1b[A", Key.Down => "\x1b[B", Key.Right => "\x1b[C", Key.Left => "\x1b[D", Key.Home => "\x1b[H", Key.End => "\x1b[F", Key.Delete => "\x1b[3~", Key.Insert => "\x1b[2~", Key.PageUp => "\x1b[5~", Key.PageDown => "\x1b[6~", _ => null };
        if (control && e.Key >= Key.A && e.Key <= Key.Z) text = ((char)(e.Key - Key.A + 1)).ToString();
        if (text is not null) { e.Handled = true; scroll = 0; _ = WriteAsync(text); }
    }
    async Task PasteAsync() { if (Clipboard.ContainsText()) { var text = Clipboard.GetText(); await WriteAsync(screen.BracketedPaste ? "\x1b[200~" + text + "\x1b[201~" : text); } }
    protected override void OnMouseDown(MouseButtonEventArgs e) { base.OnMouseDown(e); if (e.ChangedButton == MouseButton.Left) { Focus(); selectionStart = Cell(e.GetPosition(this)); selectionEnd = selectionStart; CaptureMouse(); InvalidateVisual(); } }
    protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); if (IsMouseCaptured) { selectionEnd = Cell(e.GetPosition(this)); InvalidateVisual(); } }
    protected override void OnMouseUp(MouseButtonEventArgs e) { base.OnMouseUp(e); if (IsMouseCaptured) { ReleaseMouseCapture(); Copy(); } }
    Point Cell(Point p) => new(Math.Clamp((int)((p.X - 2) / cellWidth), 0, screen.Columns - 1), Math.Clamp((int)((p.Y - 10) / cellHeight), 0, screen.Rows - 1));
    void Copy()
    {
        if (selectionStart is not Point a || selectionEnd is not Point b || a == b) return;
        if (a.Y > b.Y || a.Y == b.Y && a.X > b.X) (a, b) = (b, a);
        var rows = screen.Visible(scroll); var text = new StringBuilder();
        for (int y = (int)a.Y; y <= b.Y && y < rows.Count; y++) { int start = y == a.Y ? (int)a.X : 0, end = y == b.Y ? (int)b.X : screen.Columns - 1; for (int x = start; x <= end; x++) text.Append(rows[y][x].Text); if (y < b.Y) text.AppendLine(); }
        Clipboard.SetText(text.ToString());
    }
    protected override void OnMouseWheel(MouseWheelEventArgs e) { scroll = Math.Clamp(scroll + (e.Delta > 0 ? 3 : -3), 0, screen.ScrollbackCount); InvalidateVisual(); e.Handled = true; }
    protected override void OnGotKeyboardFocus(KeyboardFocusChangedEventArgs e) { base.OnGotKeyboardFocus(e); InvalidateVisual(); }
    protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs e) { base.OnLostKeyboardFocus(e); InvalidateVisual(); }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); dc.DrawRectangle(new SolidColorBrush(VtScreen.Background), null, new Rect(RenderSize));
        var rows = screen.Visible(scroll); double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        for (int y = 0; y < rows.Count; y++)
        {
            int x = 0;
            while (x < screen.Columns)
            {
                var cell = rows[y][x]; int start = x; var text = new StringBuilder();
                do { text.Append(rows[y][x].Text); x++; } while (x < screen.Columns && rows[y][x].Foreground == cell.Foreground && rows[y][x].Background == cell.Background && rows[y][x].Bold == cell.Bold);
                if (cell.Background != VtScreen.Background) dc.DrawRectangle(new SolidColorBrush(cell.Background), null, new Rect(2 + start * cellWidth, 10 + y * cellHeight, (x - start) * cellWidth, cellHeight));
                var format = new FormattedText(text.ToString(), CultureInfo.InvariantCulture, FlowDirection.LeftToRight, cell.Bold ? new Typeface(font.FontFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal) : font, 13, new SolidColorBrush(cell.Foreground), dpi);
                dc.DrawText(format, new Point(2 + start * cellWidth, 10 + y * cellHeight));
            }
        }
        if (selectionStart is Point a && selectionEnd is Point b && a != b) { if (a.Y > b.Y || a.Y == b.Y && a.X > b.X) (a, b) = (b, a); for (int y = (int)a.Y; y <= b.Y; y++) { int start = y == a.Y ? (int)a.X : 0, end = y == b.Y ? (int)b.X : screen.Columns - 1; dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(70, 120, 170, 255)), null, new Rect(2 + start * cellWidth, 10 + y * cellHeight, (end - start + 1) * cellWidth, cellHeight)); } }
        if (IsKeyboardFocused && scroll == 0 && screen.CursorVisible) dc.DrawRectangle(null, new Pen(Brushes.White, 1), new Rect(2 + screen.X * cellWidth, 10 + screen.Y * cellHeight, cellWidth, cellHeight));
    }
}

sealed class TerminalAutomationPeer(TerminalView owner) : FrameworkElementAutomationPeer(owner), IValueProvider
{
    protected override string GetClassNameCore() => "ConPTYTerminal";
    protected override string GetNameCore() => "PowerShell terminal";
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Document;
    public override object? GetPattern(PatternInterface pattern) => pattern == PatternInterface.Value ? this : base.GetPattern(pattern);
    public bool IsReadOnly => true;
    public string Value => owner.ScreenText;
    public void SetValue(string value) => throw new InvalidOperationException("Use terminal keyboard input");
}

public sealed class VtScreen
{
    public static Color Background => Color.FromRgb(0x28, 0x2C, 0x34);
    static readonly Color White = Colors.White;
    public sealed record Cell(string Text, Color Foreground, Color Background, bool Bold);
    readonly List<Cell[]> history = [];
    List<Cell[]> lines = [];
    List<Cell[]>? primary;
    readonly StringBuilder escape = new();
    int state, savedX, savedY, top, bottom;
    Color foreground = White, background = Background;
    bool bold, inverse;
    public int Columns { get; private set; } = 100;
    public int Rows { get; private set; } = 30;
    public int X { get; private set; }
    public int Y { get; private set; }
    public bool CursorVisible { get; private set; } = true;
    public bool BracketedPaste { get; private set; }
    public int ScrollbackCount => history.Count;
    public event Action<string>? Reply;
    Cell Blank() => new(" ", foreground, background, bold);
    Cell[] Row() => Enumerable.Repeat(Blank(), Columns).ToArray();
    public VtScreen() { Reset(); }
    public void Reset() { X = Y = state = savedX = savedY = top = 0; bottom = Rows - 1; history.Clear(); primary = null; foreground = White; background = Background; bold = inverse = false; CursorVisible = true; BracketedPaste = false; lines = Enumerable.Range(0, Rows).Select(_ => Row()).ToList(); }
    public void Resize(int columns, int rows)
    {
        Columns = columns; Rows = rows;
        Cell[] Fit(Cell[] row) { var copy = Row(); Array.Copy(row, copy, Math.Min(row.Length, columns)); return copy; }
        lines = lines.Select(Fit).ToList(); for (int i = 0; i < history.Count; i++) history[i] = Fit(history[i]);
        while (lines.Count > rows) lines.RemoveAt(0); while (lines.Count < rows) lines.Add(Row()); X = Math.Min(X, columns - 1); Y = Math.Min(Y, rows - 1); top = 0; bottom = rows - 1;
    }
    public IReadOnlyList<Cell[]> Visible(int scroll) { int end = history.Count + lines.Count - scroll; var all = history.Concat(lines).ToList(); return all.Skip(Math.Max(0, end - Rows)).Take(Rows).ToList(); }
    public void Feed(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            int ch = rune.Value;
            if (state == 1) { state = 0; if (ch == '[') { escape.Clear(); state = 2; } else if (ch == ']' || ch == 'P' || ch == '_') { state = 3; } else if (ch == '7') { savedX = X; savedY = Y; } else if (ch == '8') { X = savedX; Y = savedY; } else if (ch == 'D') LineFeed(); else if (ch == 'M') { if (Y == top) { lines.RemoveAt(bottom); lines.Insert(top, Row()); } else Y = Math.Max(0, Y - 1); } else if (ch == 'c') Reset(); continue; }
            if (state == 2) { if (ch >= 0x40 && ch <= 0x7E) { Csi((char)ch, escape.ToString()); state = 0; } else if (escape.Length < 256) escape.Append(rune.ToString()); else state = 0; continue; }
            if (state == 3) { if (ch == 7) state = 0; else if (ch == 27) state = 4; continue; }
            if (state == 4) { state = ch == '\\' ? 0 : 3; continue; }
            if (ch == 27) { state = 1; continue; }
            if (ch == '\r') { X = 0; continue; }
            if (ch == '\n') { LineFeed(); continue; }
            if (ch == '\b') { X = Math.Max(0, X - 1); continue; }
            if (ch == '\t') { X = Math.Min(Columns - 1, (X / 8 + 1) * 8); continue; }
            if (ch < 32 || ch == 127) continue;
            if (X >= Columns) { X = 0; LineFeed(); }
            var category = Rune.GetUnicodeCategory(rune);
            if (category == UnicodeCategory.NonSpacingMark && X > 0) { var c = lines[Y][X - 1]; lines[Y][X - 1] = c with { Text = c.Text + rune }; continue; }
            int width = (ch >= 0x1100 && (ch <= 0x115F || ch >= 0x2E80 && ch <= 0xA4CF || ch >= 0xAC00 && ch <= 0xD7AF || ch >= 0xF900 && ch <= 0xFAFF || ch >= 0xFE10 && ch <= 0xFE6F || ch >= 0xFF01 && ch <= 0xFF60 || ch >= 0x1F300)) ? 2 : 1;
            lines[Y][X++] = new(rune.ToString(), inverse ? background : foreground, inverse ? foreground : background, bold); if (width == 2 && X < Columns) lines[Y][X++] = new("", foreground, background, bold);
        }
    }
    void LineFeed() { if (Y == bottom) { var removed = lines[top]; lines.RemoveAt(top); lines.Insert(bottom, Row()); if (top == 0 && primary is null) { history.Add(removed); if (history.Count > 5000) history.RemoveAt(0); } } else Y = Math.Min(Rows - 1, Y + 1); }
    void Csi(char final, string body)
    {
        bool mode = body.StartsWith('?'); body = body.TrimStart('?', '>', '!'); var p = body.Split(';').Select(s => int.TryParse(s, out int n) ? n : 0).ToArray(); int N(int i, int fallback = 1) => i < p.Length && p[i] != 0 ? p[i] : fallback;
        switch (final)
        {
            case 'A': Y = Math.Max(top, Y - N(0)); break;
            case 'B': Y = Math.Min(bottom, Y + N(0)); break;
            case 'C': X = Math.Min(Columns - 1, X + N(0)); break;
            case 'D': X = Math.Max(0, X - N(0)); break;
            case 'E': Y = Math.Min(Rows - 1, Y + N(0)); X = 0; break;
            case 'F': Y = Math.Max(0, Y - N(0)); X = 0; break;
            case 'G': case '`': X = Math.Clamp(N(0) - 1, 0, Columns - 1); break;
            case 'd': Y = Math.Clamp(N(0) - 1, 0, Rows - 1); break;
            case 'H': case 'f': Y = Math.Clamp(N(0) - 1, 0, Rows - 1); X = Math.Clamp(N(1) - 1, 0, Columns - 1); break;
            case 'J': if (p[0] == 2 || p[0] == 3) { lines = Enumerable.Range(0, Rows).Select(_ => Row()).ToList(); if (p[0] == 3) history.Clear(); } else if (p[0] == 0) { Clear(Y, X, Columns - 1); for (int y = Y + 1; y < Rows; y++) Clear(y, 0, Columns - 1); } else { for (int y = 0; y < Y; y++) Clear(y, 0, Columns - 1); Clear(Y, 0, X); } break;
            case 'K': Clear(Y, p[0] == 0 ? X : 0, p[0] == 1 ? X : Columns - 1); break;
            case 'X': Clear(Y, X, Math.Min(Columns - 1, X + N(0) - 1)); break;
            case 'P': for (int x = X; x < Columns; x++) lines[Y][x] = x + N(0) < Columns ? lines[Y][x + N(0)] : Blank(); break;
            case '@': for (int x = Columns - 1; x >= X; x--) lines[Y][x] = x - N(0) >= X ? lines[Y][x - N(0)] : Blank(); break;
            case 'L': for (int n = 0; n < Math.Min(N(0), Rows - Y); n++) { lines.RemoveAt(bottom); lines.Insert(Y, Row()); } break;
            case 'M': for (int n = 0; n < Math.Min(N(0), Rows - Y); n++) { lines.RemoveAt(Y); lines.Insert(bottom, Row()); } break;
            case 'S': for (int n = 0; n < Math.Min(N(0), Rows); n++) { lines.RemoveAt(top); lines.Insert(bottom, Row()); } break;
            case 'T': for (int n = 0; n < Math.Min(N(0), Rows); n++) { lines.RemoveAt(bottom); lines.Insert(top, Row()); } break;
            case 'r': top = Math.Clamp(N(0) - 1, 0, Rows - 1); bottom = Math.Clamp(N(1, Rows) - 1, top, Rows - 1); X = 0; Y = top; break;
            case 's': savedX = X; savedY = Y; break;
            case 'u': X = Math.Clamp(savedX, 0, Columns - 1); Y = Math.Clamp(savedY, 0, Rows - 1); break;
            case 'n': if (p[0] == 6) Reply?.Invoke($"\x1b[{Y + 1};{Math.Min(X + 1, Columns)}R"); else if (p[0] == 5) Reply?.Invoke("\x1b[0n"); break;
            case 'c': Reply?.Invoke("\x1b[?1;2c"); break;
            case 'h': case 'l': if (mode) foreach (var setting in p) { bool on = final == 'h'; if (setting == 25) CursorVisible = on; if (setting == 2004) BracketedPaste = on; if (setting == 1049) { if (on && primary is null) { primary = lines; lines = Enumerable.Range(0, Rows).Select(_ => Row()).ToList(); savedX = X; savedY = Y; X = Y = 0; } else if (!on && primary is not null) { lines = primary; primary = null; Resize(Columns, Rows); X = Math.Clamp(savedX, 0, Columns - 1); Y = Math.Clamp(savedY, 0, Rows - 1); } } } break;
            case 'm': for (int i = 0; i < p.Length; i++) { int code = p[i]; if (code == 0) { foreground = White; background = Background; bold = inverse = false; } else if (code == 1) bold = true; else if (code == 22) bold = false; else if (code == 7) inverse = true; else if (code == 27) inverse = false; else if (code == 39) foreground = White; else if (code == 49) background = Background; else if (code >= 30 && code <= 37) foreground = Ansi(code - 30); else if (code >= 40 && code <= 47) background = Ansi(code - 40); else if (code >= 90 && code <= 97) foreground = Ansi(code - 90 + 8); else if (code >= 100 && code <= 107) background = Ansi(code - 100 + 8); else if ((code == 38 || code == 48) && i + 1 < p.Length) { Color color; if (p[i + 1] == 2 && i + 4 < p.Length) { color = Color.FromRgb((byte)Math.Clamp(p[i + 2], 0, 255), (byte)Math.Clamp(p[i + 3], 0, 255), (byte)Math.Clamp(p[i + 4], 0, 255)); i += 4; } else if (p[i + 1] == 5 && i + 2 < p.Length) { color = Ansi(Math.Clamp(p[i + 2], 0, 255)); i += 2; } else continue; if (code == 38) foreground = color; else background = color; } } break;
        }
    }
    void Clear(int y, int start, int end) { for (int x = Math.Clamp(start, 0, Columns - 1); x <= end && x < Columns; x++) lines[y][x] = Blank(); }
    static Color Ansi(int n) { uint[] colors = [0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6, 0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA]; if (n < 16) { uint c = colors[n]; return Color.FromRgb((byte)(c >> 16), (byte)(c >> 8), (byte)c); } if (n >= 232) { byte c = (byte)(8 + (n - 232) * 10); return Color.FromRgb(c, c, c); } n -= 16; byte Level(int v) => (byte)(v == 0 ? 0 : 55 + 40 * v); return Color.FromRgb(Level(n / 36), Level(n / 6 % 6), Level(n % 6)); }
}
