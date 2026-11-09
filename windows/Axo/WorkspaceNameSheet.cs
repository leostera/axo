using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace Axo;

/// <summary>WorkspaceCreationSheet's name step, after the native Windows folder chooser.</summary>
public sealed class WorkspaceNameSheet : Window
{
    readonly TextBox name = new() { FontSize = 18, FontWeight = FontWeights.Light, BorderThickness = new Thickness(0), Padding = new Thickness(0) };
    readonly TextBlock folder = new(), path = new() { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis };
    public string Directory { get; private set; }
    public string WorkspaceName => name.Text.Trim();
    public WorkspaceNameSheet(string directory)
    {
        Directory = directory; Title = "New Workspace"; Width = 560; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var panel = new StackPanel(); Content = panel;
        var heading = new DockPanel { Height = 48, Margin = new Thickness(14, 0, 14, 0) }; heading.Children.Add(new TextBlock { Text = "▱", FontSize = 18, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center }); heading.Children.Add(name); name.VerticalAlignment = VerticalAlignment.Center; panel.Children.Add(heading); panel.Children.Add(new Separator());
        var row = new DockPanel { Height = 64, Margin = new Thickness(14, 0, 14, 0) }; var change = new Button { Content = "Change…", VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(8, 4, 8, 4) }; DockPanel.SetDock(change, Dock.Right); row.Children.Add(change); var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) }; info.Children.Add(folder); info.Children.Add(path); row.Children.Add(info); panel.Children.Add(row); panel.Children.Add(new Separator());
        var actions = new DockPanel { Height = 44, Margin = new Thickness(12, 0, 12, 0) }; var cancel = new Button { Content = "Cancel", IsCancel = true, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(10, 4, 10, 4) }; DockPanel.SetDock(cancel, Dock.Left); actions.Children.Add(cancel); var create = new Button { Content = "Create Workspace", IsDefault = true, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(10, 4, 10, 4) }; actions.Children.Add(create); panel.Children.Add(actions);
        name.TextChanged += (_, _) => create.IsEnabled = WorkspaceName.Length > 0; create.Click += (_, _) => DialogResult = true;
        change.Click += (_, _) => { var picker = new OpenFolderDialog { Title = "Choose Workspace directory" }; if (picker.ShowDialog(this) == true) { Directory = picker.FolderName; UpdateDirectory(); } };
        UpdateDirectory(); Loaded += (_, _) => { name.Focus(); name.SelectAll(); };
    }
    void UpdateDirectory() { name.Text = System.IO.Path.GetFileName(Directory.TrimEnd(System.IO.Path.DirectorySeparatorChar)); if (name.Text.Length == 0) name.Text = Directory; folder.Text = name.Text; path.Text = Directory; }
}
