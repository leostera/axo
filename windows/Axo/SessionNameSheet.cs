using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace Axo;

/// <summary>The optional name of a Session in a chosen folder.</summary>
public sealed class SessionNameSheet : Window
{
    readonly TextBox name = new() { MaxLength = 80, Margin = new Thickness(12, 6, 12, 12) };
    public string Directory { get; }
    public string? SessionName => string.IsNullOrWhiteSpace(name.Text) ? null : name.Text.Trim();

    public SessionNameSheet(string directory)
    {
        Directory = directory;
        Title = "New Session";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = directory, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12) });
        panel.Children.Add(new TextBlock { Text = "Session name (optional)", Margin = new Thickness(12, 0, 12, 0) });
        panel.Children.Add(name);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(12, 0, 12, 12) };
        actions.Children.Add(new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) });
        var create = new Button { Content = "Create Session", IsDefault = true, Padding = new Thickness(10, 4, 10, 4) };
        create.Click += (_, _) => DialogResult = true;
        actions.Children.Add(create);
        panel.Children.Add(actions);
        Content = panel;
        Loaded += (_, _) => name.Focus();
    }
}
