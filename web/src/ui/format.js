// Shared formatters (docs/06 §17.5: same rounding on every surface).

export const toUnit = (c, unit) => (c == null ? null : unit === 'F' ? (c * 9) / 5 + 32 : c);
export const fromUnit = (v, unit) => (unit === 'F' ? ((v - 32) * 5) / 9 : v);

/** Whole degrees in the chosen unit, or an em dash. */
export function temp(c, unit, { degree = false } = {}) {
  if (c == null || Number.isNaN(c)) return '—';
  return `${Math.round(toUnit(c, unit))}${degree ? '°' : ''}`;
}

const clockFormat = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
const dateFormat = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' });

export const clock = (ms) => (ms == null ? '—' : clockFormat.format(new Date(ms)));
export const dayAndTime = (ms) => `${dateFormat.format(new Date(ms))} · ${clock(ms)}`;

/** Countdown: `3:42` (h:mm) from 5 minutes up, `4m 12s` below, matching the presenter's switch to a live countdown. */
export function countdown(seconds) {
  if (seconds == null) return '—';
  if (seconds >= 300) {
    const m = Math.round(seconds / 60);
    return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`;
  }
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`;
}

/** `2h 05m` / `12m` for durations. */
export function duration(ms) {
  const m = Math.max(0, Math.round(ms / 60000));
  return m >= 60 ? `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, '0')}m` : `${m}m`;
}

export const escapeHtml = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);

const STATE_TEXT = {
  notInserted: 'Not inserted',
  inserted: 'Inserted',
  warming: 'Warming',
  predicting: 'Predicting',
  removalPredictionDone: 'Ready',
  unknown: 'Unknown',
};

export const predictionStateText = (state) => STATE_TEXT[state] ?? '—';

const CHANNEL_NAMES = { core: 'Core', surface: 'Surface', ambient: 'Ambient' };
export const channelName = (ch) => CHANNEL_NAMES[ch] ?? ch.toUpperCase();

/** Headline and detail for an alert instance (docs/06 §7). */
export function describeAlert(a, unit) {
  const s = a.source;
  if (s.type === 'overheat') return { title: 'Overheat', detail: `${s.sensor.toUpperCase()} at ${temp(a.value, unit, { degree: true })}. Remove from heat.` };
  if (s.type === 'probeAlarm') {
    return { title: `${channelName(s.channel)} ${s.kind} alarm`, detail: `Set at ${temp(a.value, unit, { degree: true })}. Acknowledge silences the probe and Display.` };
  }
  const k = s.kind;
  switch (k.type) {
    case 'predictionDone': return { title: 'Remove now', detail: 'Core has reached the target.' };
    case 'restingDone': return { title: 'Resting done', detail: 'Ready to serve.' };
    case 'predictionWithin': return { title: `${Math.round(k.seconds / 60)} minutes left`, detail: 'Get ready to remove.' };
    case 'temperatureAbove': return { title: `${channelName(k.channel)} above ${temp(k.celsius, unit, { degree: true })}`, detail: `Now ${temp(a.value, unit, { degree: true })}.` };
    case 'temperatureBelow': return { title: `${channelName(k.channel)} below ${temp(k.celsius, unit, { degree: true })}`, detail: `Now ${temp(a.value, unit, { degree: true })}.` };
    case 'ambientOutOfRange': return { title: 'Ambient out of range', detail: `Now ${temp(a.value, unit, { degree: true })}.` };
    case 'stall': return { title: 'Stall', detail: 'Core is barely rising.' };
    case 'probeOffline': return { title: 'Probe disconnected', detail: 'No data for over a minute.' };
    case 'batteryLow': return { title: 'Low battery', detail: 'Charge the probe after this cook.' };
    default: return { title: 'Alert', detail: '' };
  }
}
