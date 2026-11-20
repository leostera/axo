using System.Windows;
namespace Axo;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        try { LaunchProfile.ApplyArguments(e.Args); }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Axo could not open this profile", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(2);
            return;
        }
        base.OnStartup(e);
    }
}
