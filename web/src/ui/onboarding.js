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

/** One line on browser support, shown wherever it matters. */
export const BROWSER_SUPPORT = 'Colby works only in Chrome or Edge (desktop or Android). Firefox, Safari and iPhone/iPad browsers are not supported: they have no Web Bluetooth.';

const BT_TEXT = {
  ready: ['ok', 'Bluetooth is available.', 'Pick your probe, or better, your Display or Booster: one connection covers every probe on it.'],
  insecure: ['no', 'This page is not on a secure address.', 'Web Bluetooth only works over HTTPS or on localhost. Open Colby from its https:// address.'],
  unsupported: ['no', 'This browser is not supported.', 'Colby needs Chrome or Edge on Windows, macOS, ChromeOS or Android. Firefox, Safari and all iPhone and iPad browsers have no Web Bluetooth, so they cannot connect to your thermometer; only the demo works there. On Linux, Chrome needs chrome://flags/#enable-experimental-web-platform-features.'],
  off: ['no', 'Bluetooth is off or not found.', 'Turn Bluetooth on in your system settings (and allow your browser to use it on macOS: System Settings → Privacy & Security → Bluetooth), then check again.'],
  denied: ['no', 'Bluetooth is blocked for this site.', 'Click the icon left of the address, open Site settings, set Bluetooth devices to Allow, then check again.'],
};

const NOTIFY_LIMITS = `<div class="limits"><strong>Without notifications</strong>
  <ul><li>Alerts show only inside this tab: the red band and a flashing tab title.</li>
  <li>The alarm sound still plays from a background tab, so keep the sound on and the volume up.</li>
  <li>You get no pop-up while you are in another tab or app, and no Acknowledge or Snooze buttons outside Colby.</li></ul></div>`;

const STEPS = ['welcome', 'bluetooth', 'notifications', 'background'];

export class Onboarding {
  #step = 'welcome';
  #bt = 'ready';
  #note = '';

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
        this.#note = this.#bt === 'ready' ? 'No device picked. Make sure the probe is out of the charger or the Display is on, then try again.' : '';
        return this.#render();
      }
      case 'allow': {
        const result = await NotificationSink.requestPermission();
        if (result === 'granted') await this.notifications.test();
        return this.#render();
      }
      case 'test-notify':
        this.#note = (await this.notifications.test()) ? 'Sent. You should see it now.' : 'It could not be shown.';
        return this.#render();
      case 'test-alert':
        this.testAlert();
        if (NotificationSink.permission === 'granted') await this.notifications.test();
        this.#note = 'You should hear the alarm sound.';
        return this.#render();
      default:
    }
  }

  #render() {
    const i = STEPS.indexOf(this.#step);
    const dots = STEPS.map((s, n) => `<span class="dot${n <= i ? ' on' : ''}"></span>`).join('');
    const body = { welcome: () => this.#welcome(), bluetooth: () => this.#bluetooth(), notifications: () => this.#notifications(), background: () => this.#background() }[this.#step]();
    this.el.innerHTML = `<div class="ob-panel" role="dialog" aria-modal="true" aria-labelledby="ob-title">
      <div class="ob-dots" aria-label="Step ${i + 1} of ${STEPS.length}">${dots}</div>
      ${body}
      ${this.#note ? `<p class="ob-note" role="status">${esc(this.#note)}</p>` : ''}
    </div>`;
  }

  #welcome() {
    return `<h2 id="ob-title">Welcome to Colby</h2>
      <p>Colby shows your Combustion thermometer on this computer: live temperatures, the prediction countdown, history and alerts.</p>
      <p>It runs entirely in this page. Nothing is sent to a server; cooks are stored in this browser.</p>
      ${unsupportedBrowser() ? `<div class="ob-status no"><strong>${esc(unsupportedBrowser())} is not supported.</strong><br>${esc(BROWSER_SUPPORT)} Open this page in Chrome or Edge, or try the demo here.</div>` : `<p class="caption">${esc(BROWSER_SUPPORT)}</p>`}
      <p>Setup takes a minute: Bluetooth, notifications, and how to keep alerts working while you use other tabs.</p>
      <div class="row"><button class="btn" data-ob="skip">Skip setup</button><button class="btn primary" data-ob="next">Start</button></div>`;
  }

  #bluetooth() {
    const [kind, title, help] = BT_TEXT[this.#bt];
    const ready = this.#bt === 'ready';
    return `<h2 id="ob-title">Connect over Bluetooth</h2>
      <div class="ob-status ${kind}"><strong>${esc(title)}</strong><br>${esc(help)}</div>
      ${ready ? '<p class="caption">The browser shows a list of nearby Combustion devices. Colby can only see the devices you pick there.</p>' : ''}
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
      granted: ['ok', 'Notifications are on.', 'Alerts pop up while Colby is in another tab or behind other windows, with Acknowledge and Snooze buttons.'],
      default: ['maybe', 'Allow notifications?', 'Colby asks only for alerts you set up: ready, 5 minutes left, probe alarms, overheat, disconnected, low battery.'],
      denied: ['no', 'Notifications are blocked for this site.', 'In an Incognito or private window they are always blocked: open Colby in a normal window. Otherwise: click the icon left of the address, set Notifications to Allow, then reload. Also check that your system lets the browser show notifications (and Focus / Do Not Disturb is off).'],
      unsupported: ['no', 'This browser cannot show notifications.', ''],
    }[p];
    return `<h2 id="ob-title">Notifications</h2>
      <div class="ob-status ${status[0]}"><strong>${esc(status[1])}</strong>${status[2] ? `<br>${esc(status[2])}` : ''}</div>
      ${p === 'granted' ? '' : NOTIFY_LIMITS}
      <div class="row">
        <button class="btn" data-ob="back">Back</button>
        ${p === 'granted' ? '<button class="btn" data-ob="test-notify">Send a test</button>' : ''}
        <button class="btn${p === 'default' ? '' : ' primary'}" data-ob="next">${p === 'default' ? 'Not now' : 'Next'}</button>
        ${p === 'default' ? '<button class="btn primary" data-ob="allow">Allow notifications</button>' : ''}
      </div>`;
  }

  #background() {
    const notify = NotificationSink.permission === 'granted';
    return `<h2 id="ob-title">Working in other tabs</h2>
      <p>You can switch tabs or apps during a cook. In the background Colby keeps receiving data, plays the alarm sound${notify ? ' and shows notifications' : ''}.</p>
      <div class="limits"><strong>Alerts stop when</strong>
      <ul><li>this tab or the browser is closed (Colby asks before closing during a cook);</li>
      <li>the computer sleeps. Colby keeps the screen awake only while its tab is visible, so set your computer not to sleep during long cooks;</li>
      <li>Chrome unloads the tab to save memory. Add this site under Settings → Performance → “Always keep these sites active”, or pin the tab;</li>
      <li>on Android, Chrome pauses background tabs after a while: keep Colby on screen.</li></ul></div>
      <p class="caption">Test the alert now: this also lets the page play sound later (browsers block sound until you click once).</p>
      <div class="row"><button class="btn" data-ob="back">Back</button><button class="btn" data-ob="test-alert">Test alert</button><button class="btn primary" data-ob="next">Done</button></div>`;
  }
}
