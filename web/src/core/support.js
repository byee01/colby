// Small runtime pieces: an event emitter and an injectable clock (docs/02 §15). Times are epoch milliseconds.

/** Minimal synchronous event emitter. `on` returns an unsubscribe function. */
export class Emitter {
  #handlers = new Map();

  on(event, fn) {
    if (!this.#handlers.has(event)) this.#handlers.set(event, new Set());
    this.#handlers.get(event).add(fn);
    return () => this.#handlers.get(event)?.delete(fn);
  }

  /** Resolves with the first event that passes `filter`, or null after `timeoutMs` on `clock`. */
  once(event, { filter = () => true, timeoutMs, clock } = {}) {
    return new Promise((resolve) => {
      let timer = null;
      const off = this.on(event, (value) => {
        if (!filter(value)) return;
        off();
        if (timer != null) clock.clearTimeout(timer);
        resolve(value);
      });
      if (timeoutMs != null) {
        timer = clock.setTimeout(() => {
          off();
          resolve(null);
        }, timeoutMs);
      }
    });
  }

  emit(event, value) {
    for (const fn of [...(this.#handlers.get(event) ?? [])]) {
      try {
        fn(value);
      } catch (e) {
        console.error(`handler for ${event} failed`, e);
      }
    }
  }
}

/** The real clock. */
export const systemClock = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimeout: (h) => globalThis.clearTimeout(h),
  setInterval: (fn, ms) => globalThis.setInterval(fn, ms),
  clearInterval: (h) => globalThis.clearInterval(h),
  sleep: (ms) => new Promise((r) => globalThis.setTimeout(r, ms)),
};

/**
 * Deterministic clock for tests: timers fire only from `advance`, in time order. Promise continuations run between
 * timers (`advance` awaits a microtask flush after each one), so async code behaves as with real time.
 */
export class FakeClock {
  #now;
  #timers = [];
  #nextId = 1;

  constructor(start = Date.UTC(2026, 9, 1, 12, 0, 0)) {
    this.#now = start;
  }

  now() { return this.#now; }

  setTimeout(fn, ms) {
    const id = this.#nextId++;
    this.#timers.push({ id, at: this.#now + Math.max(0, ms), fn, every: null });
    return id;
  }

  setInterval(fn, ms) {
    const id = this.#nextId++;
    this.#timers.push({ id, at: this.#now + ms, fn, every: ms });
    return id;
  }

  clearTimeout(id) { this.#timers = this.#timers.filter((t) => t.id !== id); }
  clearInterval(id) { this.clearTimeout(id); }
  sleep(ms) { return new Promise((r) => this.setTimeout(r, ms)); }

  /** Runs every timer due within `ms`, in order, letting promises settle after each. */
  async advance(ms) {
    const end = this.#now + ms;
    await settle();
    for (;;) {
      this.#timers.sort((a, b) => a.at - b.at || a.id - b.id);
      const next = this.#timers[0];
      if (!next || next.at > end) break;
      this.#now = next.at;
      if (next.every != null) next.at += next.every;
      else this.#timers.shift();
      next.fn();
      await settle();
    }
    this.#now = end;
    await settle();
  }
}

/** Lets pending promise continuations run. */
export async function settle() {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}

/**
 * A clock whose timers fire from native timers or from `pump()`, whichever comes first. In a hidden tab Chrome batches
 * main-thread timers to once a minute after 5 minutes ("intensive throttling", Chrome 88); messages from a Web Worker
 * still arrive every second, so the page calls `pump()` on each worker tick and offline, snooze and UART timeouts stay
 * on time in the background (see ui/background.js).
 */
export class PumpedClock {
  #timers = new Map();
  #nextId = 1;

  constructor(base = systemClock) {
    this.base = base;
  }

  now() { return this.base.now(); }
  sleep(ms) { return new Promise((r) => this.setTimeout(r, ms)); }

  setTimeout(fn, ms) {
    const id = this.#nextId++;
    this.#arm(id, { fn, at: this.now() + Math.max(0, ms), every: null });
    return id;
  }

  setInterval(fn, ms) {
    const id = this.#nextId++;
    this.#arm(id, { fn, at: this.now() + ms, every: Math.max(1, ms) });
    return id;
  }

  clearTimeout(id) {
    const t = this.#timers.get(id);
    if (!t) return;
    this.base.clearTimeout(t.native);
    this.#timers.delete(id);
  }

  clearInterval(id) { this.clearTimeout(id); }

  /** Fires every timer that is due. Call it often (each worker tick). */
  pump() {
    const now = this.now();
    const due = [...this.#timers].filter(([, t]) => t.at <= now).sort((a, b) => a[1].at - b[1].at || a[0] - b[0]);
    for (const [id] of due) this.#fire(id);
  }

  /** Timers waiting to fire (for diagnostics and tests). */
  get pending() { return this.#timers.size; }

  #arm(id, t) {
    t.native = this.base.setTimeout(() => this.#fire(id), Math.max(0, t.at - this.now()));
    this.#timers.set(id, t);
  }

  #fire(id) {
    const t = this.#timers.get(id);
    if (!t) return;
    if (t.at > this.now()) {
      // A native timer that ran a moment early: wait out the rest.
      this.base.clearTimeout(t.native);
      t.native = this.base.setTimeout(() => this.#fire(id), t.at - this.now());
      return;
    }
    this.base.clearTimeout(t.native);
    if (t.every == null) {
      this.#timers.delete(id);
    } else {
      // A late interval runs once, not once per missed period.
      const now = this.now();
      t.at += t.every;
      if (t.at <= now) t.at = now + t.every;
      this.#arm(id, t);
    }
    try {
      t.fn();
    } catch (e) {
      console.error('timer failed', e);
    }
  }
}
