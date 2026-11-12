// Browser adapters for the alert engine: system notifications, looping alarm sounds, screen wake lock.
// Web counterparts of MacAlertAdapters.swift. All work only while the page is open (docs: web/README.md).

import { describeAlert } from './format.js';

/**
 * System notifications. Shown through the service worker when one is active (that adds Acknowledge and Snooze buttons
 * that work from another tab or app, and is the only way on Android), else with `new Notification`. A notification is
 * raised when an alert fires while the tab is hidden or unfocused, and for alerts already firing when the tab is hidden;
 * in the visible tab the red band and the sound do the job. Closed when the alert is acknowledged, snoozed or clears.
 */
export class NotificationSink {
  #firing = new Map();
  #shown = new Map();

  constructor({ unit, nameOf, loops }) {
    Object.assign(this, { unit, nameOf, loops });
  }

  static get supported() { return typeof globalThis.Notification === 'function'; }
  static get permission() { return NotificationSink.supported ? Notification.permission : 'unsupported'; }

  static async requestPermission() {
    if (!NotificationSink.supported) return 'unsupported';
    try {
      return await Notification.requestPermission();
    } catch {
      return Notification.permission;
    }
  }

  deliver(event) {
    const { instance: a, to } = event;
    if (to === 'firing') {
      this.#firing.set(a.id, event);
      if (!pageInFront()) this.#show(event);
    } else {
      this.#firing.delete(a.id);
      this.#close(a.id);
    }
  }

  /** The tab went to the background: notify about alerts that are already firing. */
  pageHidden() {
    for (const [id, event] of this.#firing) if (!this.#shown.has(id)) this.#show(event);
  }

  /**
   * Shows a sample notification (onboarding and settings). Resolves false when the browser refused it. True means the
   * browser took it; the system can still hide it (macOS or Windows settings, Focus / Do Not Disturb), which no web
   * page can detect, so the UI asks whether it appeared.
   */
  async test() {
    if (NotificationSink.permission !== 'granted') return false;
    const ok = await this.#post('Colby: notifications are on', {
      body: 'Alerts appear like this while Colby is open in another tab or behind other windows.', tag: 'colby-test',
    });
    if (!ok) return false;
    try {
      const reg = await navigator.serviceWorker?.getRegistration();
      if (reg?.active) return (await reg.getNotifications({ tag: 'colby-test' })).length > 0;
    } catch {
      /* cannot check */
    }
    return true;
  }

  async #show(event) {
    const a = event.instance;
    if (NotificationSink.permission !== 'granted') return;
    const { title, detail } = describeAlert(a, this.unit());
    const body = event.failure ? `${detail} (Could not silence the probe: ${event.failure})` : detail;
    const ok = await this.#post(`${this.nameOf(a.serial)}: ${title}`, {
      body, tag: a.id, renotify: true, requireInteraction: this.loops(a.source), data: { id: a.id },
      actions: [{ action: 'ack', title: 'Acknowledge' }, { action: 'snooze', title: 'Snooze 5 min' }],
    });
    if (ok && this.#firing.has(a.id)) this.#shown.set(a.id, true);
  }

  async #post(title, options) {
    const full = { icon: 'icon.svg', badge: 'icon.svg', ...options };
    try {
      const reg = await navigator.serviceWorker?.getRegistration();
      if (reg?.active) {
        await reg.showNotification(title, full);
        return true;
      }
    } catch {
      /* fall back to a page notification */
    }
    try {
      const { actions: _a, ...pageOptions } = full;
      const n = new Notification(title, pageOptions);
      n.onclick = () => {
        globalThis.focus?.();
        n.close();
      };
      if (options.tag) this.#shown.set(options.tag, n);
      return true;
    } catch {
      return false;
    }
  }

  async #close(id) {
    const page = this.#shown.get(id);
    this.#shown.delete(id);
    if (page instanceof Notification) page.close();
    try {
      const reg = await navigator.serviceWorker?.getRegistration();
      for (const n of (await reg?.getNotifications({ tag: id })) ?? []) n.close();
    } catch {
      /* nothing to close */
    }
  }
}

/** True when the user can see this tab right now. */
export const pageInFront = () => document.visibilityState === 'visible' && document.hasFocus();

/** Beep patterns per sound (docs/06 §17.3): [frequency Hz, duration s] pairs, then a pause. */
const PATTERNS = {
  ready: { tones: [[660, 0.15], [880, 0.15], [1100, 0.3]], pause: 1.2 },
  overheat: { tones: [[1200, 0.12], [900, 0.12], [1200, 0.12], [900, 0.12]], pause: 0.4 },
  probeAlarm: { tones: [[1000, 0.2], [750, 0.2]], pause: 0.8 },
  countdown: { tones: [[880, 0.2], [880, 0.2]], pause: 0 },
  problem: { tones: [[520, 0.35]], pause: 0 },
  custom: { tones: [[880, 0.25]], pause: 0 },
};
const ORDER = ['overheat', 'probeAlarm', 'ready'];

/**
 * Ready, overheat and probe alarms loop the most urgent pattern until nothing of theirs is firing; the other sounds
 * play once each time an alert fires. Synthesized with Web Audio (no files).
 */
export class SoundSink {
  #ctx = null;
  #firing = new Map();
  #timer = null;
  enabled = true;
  volume = 0.25;

  constructor(soundOf, loops) {
    this.soundOf = soundOf;
    this.loops = loops;
  }

  /** Browsers allow audio only after a user gesture; call from any click. */
  unlock() {
    if (!this.#ctx && globalThis.AudioContext) this.#ctx = new AudioContext();
    this.#ctx?.resume?.();
  }

  deliver(event) {
    const { instance: a, to } = event;
    const sound = this.soundOf(a.source);
    if (to === 'firing' && !this.loops(sound)) {
      if (this.enabled) this.#play(sound);
      return;
    }
    if (to === 'firing') this.#firing.set(a.id, sound);
    else this.#firing.delete(a.id);
    this.#update();
  }

  /** Plays one round of a pattern (settings "Test sound"). */
  test(sound = 'ready') {
    this.unlock();
    this.#play(sound);
  }

  #update() {
    if (this.#firing.size && this.enabled) {
      if (this.#timer == null) this.#loop();
    } else if (this.#timer != null) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
  }

  #loop() {
    const sound = ORDER.find((s) => [...this.#firing.values()].includes(s)) ?? 'ready';
    const seconds = this.#play(sound);
    this.#timer = setTimeout(() => {
      this.#timer = null;
      this.#update();
    }, seconds * 1000);
  }

  #play(sound) {
    const p = PATTERNS[sound];
    const total = p.tones.reduce((t, [, d]) => t + d + 0.05, 0) + p.pause;
    const ctx = this.#ctx;
    if (!ctx || ctx.state !== 'running') return total;
    let t = ctx.currentTime + 0.02;
    for (const [freq, dur] of p.tones) {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = 'triangle';
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0, t);
      gain.gain.linearRampToValueAtTime(this.volume, t + 0.01);
      gain.gain.setValueAtTime(this.volume, t + dur - 0.02);
      gain.gain.linearRampToValueAtTime(0, t + dur);
      osc.connect(gain).connect(ctx.destination);
      osc.start(t);
      osc.stop(t + dur);
      t += dur + 0.05;
    }
    return total;
  }
}

/**
 * Keeps the screen (and so the computer) awake while a cook is active, with the Screen Wake Lock API. The browser
 * drops the lock when the tab is hidden; it is taken again when the tab is visible.
 */
export class ScreenWakeLock {
  #wanted = false;
  #lock = null;
  enabled = true;
  onChange = () => {};

  constructor() {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') this.#sync();
    });
  }

  static get supported() { return !!globalThis.navigator?.wakeLock; }
  get held() { return !!this.#lock && !this.#lock.released; }

  setHeld(on) {
    this.#wanted = on;
    this.#sync();
  }

  refresh() { this.#sync(); }

  async #sync() {
    const want = this.#wanted && this.enabled && ScreenWakeLock.supported;
    if (want && !this.held && document.visibilityState === 'visible') {
      try {
        this.#lock = await navigator.wakeLock.request('screen');
        this.#lock.addEventListener('release', () => this.onChange());
      } catch {
        this.#lock = null;
      }
    } else if (!want && this.#lock) {
      await this.#lock.release().catch(() => {});
      this.#lock = null;
    }
    this.onChange();
  }
}
