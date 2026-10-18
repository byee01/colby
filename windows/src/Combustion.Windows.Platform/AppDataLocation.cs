using Windows.Storage;

namespace Combustion.Windows.Platform;

/// <summary>App data paths from the platform API, never hard-coded (docs/02 §6.3). Need package identity (MSIX).</summary>
public static class AppDataLocation
{
    /// <summary>The app database (history, alert rules, alert log).</summary>
    public static string DatabasePath(string file = "colby.sqlite") =>
        Path.Combine(ApplicationData.Current.LocalFolder.Path, file);

    /// <summary>The widget snapshot file read by the widget provider in the same package.</summary>
    public static string LiveSnapshotPath(string file = "live-snapshot.json") =>
        Path.Combine(ApplicationData.Current.LocalFolder.Path, file);
}
