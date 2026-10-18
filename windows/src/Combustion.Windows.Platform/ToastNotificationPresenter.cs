using System.Security;
using Combustion.Codec;
using Combustion.Core;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

namespace Combustion.Windows.Platform;

/// <summary>
/// Posts alerts as alarm toasts (<c>scenario="alarm"</c>: stays on screen and loops its sound) with Acknowledge and
/// Snooze buttons (docs/02 §9, 06 §7). Uses <see cref="ToastNotificationManager"/>, which needs package identity (MSIX);
/// unpackaged builds must register an AUMID first. The buttons activate the app with
/// <c>action=acknowledge|snooze&amp;alertId=...</c>; the app routes that to <c>AlertEngine</c>.
/// Untested on Windows (built on Linux only).
/// </summary>
public sealed class ToastNotificationPresenter : INotificationPresenting
{
    public const string Group = "colby.alert";
    public const string AcknowledgeAction = "acknowledge";
    public const string SnoozeAction = "snooze";

    /// <summary>Title and body for an alert. The app passes one that knows probe nicknames and the units setting.</summary>
    public delegate (string Title, string Body) Formatter(AlertInstance alert);

    private readonly Formatter _format;
    private readonly Lazy<ToastNotifier> _notifier;

    public ToastNotificationPresenter(Formatter? format = null)
    {
        _format = format ?? DefaultText;
        _notifier = new Lazy<ToastNotifier>(ToastNotificationManager.CreateToastNotifier);
    }

    public Task PostAsync(AlertInstance alert)
    {
        var (title, body) = _format(alert);
        var doc = new XmlDocument();
        doc.LoadXml(ToastXml(alert.Id, title, body));
        var toast = new ToastNotification(doc) { Tag = Tag(alert.Id), Group = Group };
        try
        {
            _notifier.Value.Show(toast);
        }
        catch (Exception)
        {
            // Notifications disabled or no package identity: the in-app alert list still shows it.
        }
        return Task.CompletedTask;
    }

    public Task WithdrawAsync(string id)
    {
        try
        {
            ToastNotificationManager.History.Remove(Tag(id), Group);
        }
        catch (Exception)
        {
        }
        return Task.CompletedTask;
    }

    /// <summary>Toast tags are limited to 64 characters; alert ids are shorter (serial + kind + channel), but be safe.</summary>
    internal static string Tag(string id) => id.Length <= 64 ? id : id[..64];

    internal static string ToastXml(string id, string title, string body)
    {
        static string E(string s) => SecurityElement.Escape(s) ?? "";
        var args = $"alertId={Uri.EscapeDataString(id)}";
        return $"""
            <toast scenario="alarm" launch="{E(args)}">
              <visual><binding template="ToastGeneric"><text>{E(title)}</text><text>{E(body)}</text></binding></visual>
              <audio src="ms-winsoundevent:Notification.Looping.Alarm" loop="true"/>
              <actions>
                <action content="Acknowledge" arguments="{E($"action={AcknowledgeAction}&{args}")}" activationType="foreground"/>
                <action content="Snooze 5 min" arguments="{E($"action={SnoozeAction}&{args}")}" activationType="foreground"/>
              </actions>
            </toast>
            """;
    }

    /// <summary>Plain wording without nicknames or units (same text as the macOS default); the app should pass its own formatter.</summary>
    public static (string Title, string Body) DefaultText(AlertInstance alert)
    {
        var probe = $"Probe {alert.Serial.Hex}";
        return alert.Source switch
        {
            AlertSource.Overheat o => ($"{probe} is overheating", $"Sensor {o.Sensor} is above its safe limit. Move the probe away from the heat."),
            AlertSource.ProbeAlarm a => ($"{probe} alarm", $"{a.Channel} {(a.Kind == AlarmKind.High ? "high" : "low")} alarm."),
            AlertSource.Rule { Kind: var k } => k switch
            {
                AlertRuleKind.PredictionDone => ($"{probe} is ready", "Remove from heat."),
                AlertRuleKind.RestingDone => ($"{probe} has rested", "Resting is done."),
                AlertRuleKind.PredictionWithin w => ($"{probe} is almost ready", $"About {w.Seconds / 60} minutes left."),
                AlertRuleKind.ProbeOffline => ($"{probe} disconnected", "No data from the probe."),
                AlertRuleKind.BatteryLow => ($"{probe} battery low", "Charge the probe before the next cook."),
                AlertRuleKind.Stall => ($"{probe} may be stalling", "The core temperature has barely risen."),
                AlertRuleKind.AmbientOutOfRange => ($"{probe} ambient out of range", "Check the heat source."),
                _ => ($"{probe} temperature alert", "A temperature limit was crossed."),
            },
            _ => (probe, "Alert"),
        };
    }
}
