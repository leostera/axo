using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Axo;

/// <summary>Original Axo Rive artboards sampled by tools/generate-mascot.mjs.
/// Frame atlases keep release builds independent of a browser or Rive installation.</summary>
public sealed class Mascot : Image
{
    public static readonly DependencyProperty ArtboardProperty = DependencyProperty.Register(nameof(Artboard), typeof(string), typeof(Mascot), new PropertyMetadata("Face", (o, _) => ((Mascot)o).LoadFrames()));
    public string Artboard { get => (string)GetValue(ArtboardProperty); set => SetValue(ArtboardProperty, value); }
    static readonly Dictionary<string, BitmapSource[]> cache = [];
    readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromMilliseconds(1000.0 / 30) };
    BitmapSource[] frames = [];
    int frame;
    public Mascot()
    {
        System.Windows.Automation.AutomationProperties.SetName(this, "Axo");
        clock.Tick += (_, _) => { if (frames.Length > 0) Source = frames[(frame++) % frames.Length]; };
        Loaded += (_, _) => { LoadFrames(); UpdateClock(); };
        Unloaded += (_, _) => clock.Stop();
        IsVisibleChanged += (_, _) => UpdateClock();
    }
    void UpdateClock() { if (IsVisible && SystemParameters.ClientAreaAnimation) clock.Start(); else clock.Stop(); }
    void LoadFrames()
    {
        var (w, h, count) = Artboard switch { "Mark" => (64, 36, 120), "Icon" => (128, 128, 120), "Loader" => (192, 192, 90), "Happy" => (192, 192, 30), _ => (256, 146, 120) };
        if (!cache.TryGetValue(Artboard, out var loaded))
        {
            var atlas = new BitmapImage(new Uri($"pack://application:,,,/Assets/{Artboard}.png")); atlas.Freeze();
            loaded = Enumerable.Range(0, count).Select(i => { var crop = new CroppedBitmap(atlas, new Int32Rect(i % 12 * w, i / 12 * h, w, h)); crop.Freeze(); return (BitmapSource)crop; }).ToArray();
            cache[Artboard] = loaded;
        }
        frames = loaded; frame = 0; Source = frames[0];
    }
}
