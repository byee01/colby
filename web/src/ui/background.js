// Keeping Colby working while its tab is in the background.
//
// What a hidden tab still gets in Chrome: Bluetooth notifications (events, not timers), Web Audio, the Notifications
// API, and messages from a Web Worker. What it loses: requestAnimationFrame (no drawing, which is fine), the screen
// wake lock, and timer precision: main-thread timers run at most once a second, and once a minute after 5 minutes
// hidden ("intensive throttling", Chrome 88) unless the page made sound in the last 30 s. A worker's timers are not
// batched that way, so a worker heartbeat drives the app clock (`PumpedClock.pump`).

/** Calls `onTick` every second from a Web Worker; falls back to a main-thread interval. Returns `{worker, stop}`. */
export function startHeartbeat(onTick, periodMs = 1000) {
  try {
    const source = `setInterval(() => postMessage(0), ${periodMs});`;
    const url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
    const worker = new Worker(url);
    worker.onmessage = () => onTick();
    return { worker: true, stop: () => worker.terminate() };
  } catch {
    const h = setInterval(onTick, periodMs);
    return { worker: false, stop: () => clearInterval(h) };
  }
}

/**
 * Page lifecycle: `onHidden`/`onVisible` on visibility changes, `onResume` after Chrome froze the tab (no events
 * arrived meanwhile, so links may be gone). `discarded` is true when Chrome threw the tab away and this load restored it.
 */
export function watchLifecycle({ onHidden, onVisible, onResume }) {
  document.addEventListener('visibilitychange', () => (document.visibilityState === 'hidden' ? onHidden() : onVisible()));
  document.addEventListener('resume', () => onResume());
  return { discarded: !!document.wasDiscarded };
}

/** Asks before the tab is closed or reloaded while `shouldWarn()` holds (alerts stop with the tab). */
export function guardUnload(shouldWarn) {
  addEventListener('beforeunload', (e) => {
    if (!shouldWarn()) return;
    e.preventDefault();
    e.returnValue = '';
  });
}

/** Alternates the tab title with an alert text while the tab is hidden, so the tab strip shows something is up. */
export class TitleFlasher {
  #on = false;

  constructor(base = 'Colby') {
    this.base = base;
  }

  /** Call every second with the current alert text (or null). */
  tick(alertText) {
    if (!alertText) {
      this.#on = false;
      document.title = this.base;
      return;
    }
    if (document.visibilityState === 'visible') {
      document.title = `● ${alertText} · ${this.base}`;
      return;
    }
    this.#on = !this.#on;
    document.title = this.#on ? `🔔 ${alertText}` : `● ${this.base}`;
  }
}
