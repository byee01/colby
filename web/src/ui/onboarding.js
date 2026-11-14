// First-run setup: what Colby is, Bluetooth access, notification permission, and what keeps alerts working in the
// background. Shown on the first load, and again (from the Bluetooth step) while Bluetooth cannot be used and no device
// is set up. Permission prompts are only ever triggered from a click here or in Settings.

import { NotificationSink } from './platform.js';
import { escapeHtml as esc } from './format.js';

/**
 * Bluetooth readiness: 'ready', 'insecure' (not HTTPS or localhost), 'unsupported' (no Web Bluetooth), 'off' (no
 * adapter, adapter off, or Bluetooth blocked for the browser) or 'denied' (blocked for this site).
 */
export async function bluetoothStatus() {
  if (!globalThis.isSecureContext) return 'insecure';
  const bt = globalThis.navigator?.bluetooth;
  if (!bt) return 'unsupported';
  try {
    const p = await navigator.permissions?.query({ name: 'bluetooth' });
    if (p?.state === 'denied') return 'denied';
  } catch {
    /* the permission name is not queryable in every browser */
  }
  try {
    if ((await bt.getAvailability()) === false) return 'off';
  } catch {
    /* assume available */
  }
  return 'ready';
}

/** The browser's name when it is one that cannot run Colby, for naming it in the text. */
export function unsupportedBrowser() {
  const ua = globalThis.navigator?.userAgent ?? '';
  if (/Firefox\//.test(ua)) return 'Firefox';
  if (/iPhone|iPad|iPod/.test(ua)) return 'iPhone and iPad browsers';
  if (/Safari\//.test(ua) && !/Chrome\/|Chromium\//.test(ua)) return 'Safari';
  return globalThis.navigator?.bluetooth ? null : 'This browser';
}

/**
 * 'ios' or 'android' on a phone or tablet, else null. iPadOS reports itself as a Mac, so a Mac with a touch screen
 * counts as iOS (no Mac has one).
 */
export function mobilePlatform() {
  const nav = globalThis.navigator ?? {};
  const ua = nav.userAgent ?? '';
  if (/Android/.test(ua)) return 'android';
  if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && nav.maxTouchPoints > 1)) return 'ios';
  return null;
}

/** The official Combustion app for each mobile platform. */
export const COMBUSTION_APP = {
  ios: { url: 'https://apps.apple.com/app/id1658858290' },
  android: { url: 'https://play.google.com/store/apps/details?id=inc.combustion.app' },
};

/** Link to the official app for this phone or tablet, styled as a button. */
export function appStoreButton(platform, primary = true) {
  return `<a class="btn${primary ? ' primary' : ''}" href="${COMBUSTION_APP[platform].url}" target="_blank" rel="noopener">Get the Combustion app</a>`;
}

/** One line on browser support, shown wherever it matters. */
export const BROWSER_SUPPORT = 'Works in Chrome or Edge on a computer.';

/** Shown next to "Connect a device": the chooser often lists Combustion devices by address only. */
export const CHOOSER_HINT = 'Devices often show up as “Unknown or Unsupported Device”. Pick the one with the strongest signal.';

const BT_TEXT = {
  ready: ['ok', 'Bluetooth is on.', 'Have a Display or Booster? Connect that to get all your probes at once.'],
  insecure: ['no', 'Not a secure address.', 'Open Colby over https://.'],
  unsupported: ['no', 'This browser can\'t use Bluetooth.', 'Use Chrome or Edge. On Linux, turn on chrome://flags/#enable-experimental-web-platform-features.'],
  off: ['no', 'Bluetooth is off.', 'Turn it on, then check again. On a Mac, also allow your browser in Privacy & Security → Bluetooth.'],
  denied: ['no', 'Bluetooth is blocked for this site.', 'Allow it in Site settings (the icon left of the address), then check again.'],
};

const NOTIFY_LIMITS = '<p class="caption">Without notifications, alerts only show in this tab.</p>';

/** Where to look when a test notification was sent but nothing appeared: the system, not the page, hid it. */
export function notifyTroubleshooting() {
  const ua = globalThis.navigator?.userAgent ?? '';
  const browser = /Edg\//.test(ua) ? 'Microsoft Edge' : 'Google Chrome';
  const os = /Mac OS X|Macintosh/.test(ua) ? 'mac' : /Windows/.test(ua) ? 'windows' : /CrOS/.test(ua) ? 'chromeos' : /Android/.test(ua) ? 'android' : 'other';
  const steps = {
    mac: [`System Settings → Notifications → ${browser}: allow notifications.`, 'Turn off Focus.', 'Check Notification Center.'],
    windows: [`Settings → System → Notifications: turn them on for ${browser}.`, 'Turn off Do Not Disturb.'],
    chromeos: ['Settings → Apps → Notifications: allow the browser.', 'Turn off Do Not Disturb.'],
    android: [`Settings → Apps → ${browser} → Notifications: allow them.`, 'Turn off Do Not Disturb.'],
    other: ['Allow browser notifications in your system settings.'],
  }[os];
  steps.push(`${browser} → Settings → Privacy and security → Site settings → Notifications: allow this site.`);
  return `<div class="limits"><strong>Nothing appeared? Check:</strong>
    <ol>${steps.map((t) => `<li>${esc(t)}</li>`).join('')}</ol></div>`;
}

const STEPS = ['welcome', 'bluetooth', 'notifications', 'background'];

export class Onboarding {
  #step = 'welcome';
  #bt = 'ready';
  #note = '';
  /** Notification test on the notifications step: null, 'sent' (asking whether it appeared) or 'missing'. */
  #notifyTest = null;

  /**
   * @param {object} o
   * @param {HTMLElement} o.el                 overlay element
   * @param {() => Promise<boolean>} o.connect  opens the device chooser; true if a device was added
   * @param {() => void} o.demo
   * @param {NotificationSink} o.notifications
   * @param {() => void} o.testAlert            plays the alarm sound once (also unlocks audio)
   * @param {() => void} o.onDone
   */
  constructor(o) {
    Object.assign(this, o);
    this.el.addEventListener('click', (e) => {
      const b = e.target.closest('[data-ob]');
      if (b) this.#act(b.dataset.ob, b);
    });
  }

  get isOpen() { return !this.el.hidden; }

  async open(step = 'welcome') {
    this.#step = step;
    this.#note = '';
    this.#bt = await bluetoothStatus();
    this.el.hidden = false;
    this.#render();
    this.el.querySelector('.btn.primary')?.focus();
  }

  close() {
    this.el.hidden = true;
    this.onDone();
  }

  #go(step) {
    this.#step = step;
    this.#note = '';
    this.#notifyTest = null;
    this.#render();
  }

  #next() {
    const i = STEPS.indexOf(this.#step);
    if (i === STEPS.length - 1) this.close();
    else this.#go(STEPS[i + 1]);
  }

  async #act(action, button) {
    switch (action) {
      case 'next': return this.#next();
      case 'back': return this.#go(STEPS[Math.max(0, STEPS.indexOf(this.#step) - 1)]);
      case 'skip': return this.close();
      case 'demo':
        this.demo();
        return this.#go('notifications');
      case 'mobile-demo':
        this.demo();
        return this.close();
      case 'browser': return this.#go('welcome');
      case 'check':
        this.#bt = await bluetoothStatus();
        this.#note = this.#bt === 'ready' ? '' : 'Still not available.';
        return this.#render();
      case 'connect': {
        button.disabled = true;
        const added = await this.connect();
        button.disabled = false;
        if (added) return this.#go('notifications');
        this.#bt = await bluetoothStatus();
        this.#note = this.#bt === 'ready' ? 'No device picked. Take the probe out of its charger and try again.' : '';
        return this.#render();
      }
      case 'allow': {
        const result = await NotificationSink.requestPermission();
        if (result === 'granted') return this.#sendTest();
        this.#note = result === 'denied' ? 'Notifications blocked.' : '';
        return this.#render();
      }
      case 'test-notify': return this.#sendTest();
      case 'notify-seen':
        this.#notifyTest = null;
        return this.#next();
      case 'notify-missing':
        this.#notifyTest = 'missing';
        this.#note = '';
        return this.#render();
      case 'recheck':
        this.#note = NotificationSink.permission === 'denied' ? 'Still blocked. Try reloading.' : '';
        return this.#render();
      case 'test-alert':
        this.testAlert();
        if (NotificationSink.permission === 'granted') await this.notifications.test();
        this.#note = 'You should hear the alarm.';
        return this.#render();
      default:
    }
  }

  async #sendTest() {
    const ok = await this.notifications.test();
    this.#notifyTest = ok ? 'sent' : 'missing';
    this.#note = ok ? '' : 'The browser blocked it.';
    return this.#render();
  }

  #render() {
    const i = STEPS.indexOf(this.#step);
    const dots = STEPS.map((s, n) => `<span class="dot${n <= i ? ' on' : ''}"></span>`).join('');
    const body = { mobile: () => this.#mobile(), welcome: () => this.#welcome(), bluetooth: () => this.#bluetooth(), notifications: () => this.#notifications(), background: () => this.#background() }[this.#step]();
    this.el.innerHTML = `<div class="ob-panel" role="dialog" aria-modal="true" aria-labelledby="ob-title">
      ${i < 0 ? '' : `<div class="ob-dots" aria-label="Step ${i + 1} of ${STEPS.length}">${dots}</div>`}
      ${body}
      ${this.#note ? `<p class="ob-note" role="status">${esc(this.#note)}</p>` : ''}
    </div>`;
  }

  /** Phones and tablets: point to the official Combustion app instead of a browser-support error. */
  #mobile() {
    const platform = mobilePlatform() ?? 'android';
    const canConnect = platform === 'android' && this.#bt === 'ready';
    return `<img class="ob-logo" src="logo.svg" alt="" width="64" height="64">
      <h2 id="ob-title">Use the Combustion app</h2>
      <p>Colby is built for desktop computers only. If you're on a mobile device, use the official Combustion app.</p>
      <div class="row">
        ${canConnect ? '<button class="btn" data-ob="browser">Use Colby anyway</button>' : '<button class="btn" data-ob="mobile-demo">Try the demo</button>'}
        ${appStoreButton(platform)}
      </div>`;
  }

  #welcome() {
    const unsupported = unsupportedBrowser();
    return `<img class="ob-logo" src="logo.svg" alt="" width="64" height="64">
      <h2 id="ob-title">Welcome to Colby</h2>
      <p>See your Combustion probes on your computer and get alerts during a cook. Cook history stays in this browser.</p>
      ${unsupported ? `<div class="ob-status no"><strong>${esc(unsupported)} isn't supported.</strong><br>Use Chrome or Edge. The demo works here.</div>` : ''}
      <p>Setup takes a minute.</p>
      <div class="row"><button class="btn" data-ob="skip">Skip setup</button><button class="btn primary" data-ob="next">Start</button></div>`;
  }

  #bluetooth() {
    const [kind, title, help] = BT_TEXT[this.#bt];
    const ready = this.#bt === 'ready';
    return `<h2 id="ob-title">Connect over Bluetooth</h2>
      <div class="ob-status ${kind}"><strong>${esc(title)}</strong><br>${esc(help)}</div>
      ${ready ? `<p class="caption">${esc(CHOOSER_HINT)}</p>` : ''}
      <div class="row">
        ${ready ? '' : '<button class="btn" data-ob="check">Check again</button>'}
        <button class="btn" data-ob="demo">Try the demo</button>
        <button class="btn" data-ob="next">Later</button>
        ${ready ? '<button class="btn primary" data-ob="connect">Connect a device</button>' : ''}
      </div>`;
  }

  #notifications() {
    const p = NotificationSink.permission;
    const status = {
      granted: ['ok', 'Notifications are on.', ''],
      default: ['maybe', 'Allow notifications?', 'Get alerts while Colby is in the background.'],
      denied: ['no', 'Notifications are blocked.', 'Allow them in Site settings, then reload. Incognito windows always block them.'],
      unsupported: ['no', 'This browser can\'t show notifications.', ''],
    }[p];
    return `<h2 id="ob-title">Notifications</h2>
      <div class="ob-status ${status[0]}"><strong>${esc(status[1])}</strong>${status[2] ? `<br>${esc(status[2])}` : ''}</div>
      ${p === 'granted' ? '' : NOTIFY_LIMITS}
      ${p === 'granted' && this.#notifyTest === 'missing' ? notifyTroubleshooting() : ''}
      ${p === 'granted' && this.#notifyTest === 'sent' ? `<p><strong>Did you see the test notification?</strong></p>
      <div class="row">
        <button class="btn" data-ob="notify-missing">No</button>
        <button class="btn primary" data-ob="notify-seen">Yes</button>
      </div>` : `<div class="row">
        <button class="btn" data-ob="back">Back</button>
        ${p === 'granted' ? `<button class="btn${this.#notifyTest ? ' primary' : ''}" data-ob="test-notify">${this.#notifyTest ? 'Send another test' : 'Send a test'}</button>` : ''}
        ${p === 'denied' ? '<button class="btn" data-ob="recheck">Check again</button>' : ''}
        <button class="btn${p === 'granted' && !this.#notifyTest ? ' primary' : ''}" data-ob="next">${p === 'granted' ? 'Next' : 'Continue without'}</button>
        ${p === 'default' ? '<button class="btn primary" data-ob="allow">Allow notifications</button>' : ''}
      </div>`}`;
  }

  #background() {
    return `<h2 id="ob-title">Background tabs</h2>
      <p>Alerts keep working while you use other tabs.</p>
      <div class="limits"><strong>Alerts stop if</strong>
      <ul><li>you close this tab</li>
      <li>your computer sleeps</li>
      <li>Chrome unloads the tab to save memory (pin the tab to prevent this)</li></ul></div>
      <p class="caption">Play a test alarm. This also lets later alarms make sound.</p>
      <div class="row"><button class="btn" data-ob="back">Back</button><button class="btn" data-ob="test-alert">Test alarm</button><button class="btn primary" data-ob="next">Done</button></div>`;
  }
}
