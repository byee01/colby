// Browser adapters for the alert engine: system notifications, looping alarm sounds, screen wake lock.
// Web counterparts of MacAlertAdapters.swift. All work only while the page is open (docs: web/README.md).

import { describeAlert } from './format.js';

/** System notifications through the Notifications API (needs permission, asked from a click). */
export class NotificationSink {
  #open = new Map();

  constructor({ unit, nameOf, onClick }) {
    Object.assign(this, { unit, nameOf, onClick });
  }

  static get supported() { return typeof globalThis.Notification === 'function'; }
  static get permission() { return NotificationSink.supported ? Notification.permission : 'unsupported'; }

  static async requestPermission() {
    if (!NotificationSink.supported) return 'unsupported';
    return Notification.requestPermission();
  }

  deliver(event) {
    const { instance: a, to } = event;
    if (to !== 'firing') {
      this.#open.get(a.id)?.close();
      this.#open.delete(a.id);
      return;
    }
    if (NotificationSink.permission !== 'granted') return;
    const { title, detail } = describeAlert(a, this.unit());
    try {
      const n = new Notification(`${this.nameOf(a.serial)}: ${title}`, {
        body: event.failure ? `${detail} (Could not silence the probe: ${event.failure})` : detail,
        tag: a.id,
        renotify: true,
        requireInteraction: true,
        icon: 'icon.svg',
      });
      n.onclick = () => {
        globalThis.focus?.();
        this.onClick?.(a.id);
        n.close();
      };
      this.#open.set(a.id, n);
    } catch {
      // Some platforms (Android Chrome) only allow notifications from a service worker.
      navigator.serviceWorker?.ready
        .then((reg) => reg.showNotification(`${this.nameOf(a.serial)}: ${title}`, { body: detail, tag: a.id, requireInteraction: true }))
        .catch(() => {});
    }
  }
}

/** Beep patterns per sound (docs/06 §17.3): [frequency Hz, duration s] pairs, then a pause. */
const PATTERNS = {
  ready: { tones: [[660, 0.15], [880, 0.15], [1100, 0.3]], pause: 1.2 },
  overheat: { tones: [[1200, 0.12], [900, 0.12], [1200, 0.12], [900, 0.12]], pause: 0.4 },
  probeAlarm: { tones: [[1000, 0.2], [750, 0.2]], pause: 0.8 },
  alert: { tones: [[880, 0.25]], pause: 1.5 },
};
const ORDER = ['overheat', 'probeAlarm', 'ready', 'alert'];

/** Loops the most urgent firing alert's pattern until nothing is firing. Synthesized with Web Audio (no files). */
export class SoundSink {
  #ctx = null;
  #firing = new Map();
  #timer = null;
  enabled = true;
  volume = 0.25;

  constructor(soundOf) {
    this.soundOf = soundOf;
  }

  /** Browsers allow audio only after a user gesture; call from any click. */
  unlock() {
    if (!this.#ctx && globalThis.AudioContext) this.#ctx = new AudioContext();
    this.#ctx?.resume?.();
  }

  deliver(event) {
    const { instance: a, to } = event;
    if (to === 'firing') this.#firing.set(a.id, this.soundOf(a.source));
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
    const sound = ORDER.find((s) => [...this.#firing.values()].includes(s)) ?? 'alert';
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
