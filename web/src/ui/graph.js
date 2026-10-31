// Temperature graph on a canvas (docs/06 §4.1): core/surface/ambient or all 8 sensors, target line, gaps as breaks,
// pointer and keyboard scrubbing. Colors come from CSS custom properties so the page theme drives them.

import { toUnit, clock } from './format.js';

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

/**
 * @typedef {{time: number, temps: number[], vs: number[]}} Sample   vs = sensor index of core, surface, ambient
 */
export class Graph {
  #data = { samples: [], target: null, from: 0, to: 1, unit: 'F', mode: 'csa', period: 5000 };
  #scrubTime = null;
  #layout = null;

  /** @param {HTMLCanvasElement} canvas  @param {(sample: Sample|null) => void} onScrub */
  constructor(canvas, onScrub) {
    this.canvas = canvas;
    this.onScrub = onScrub;
    new ResizeObserver(() => this.draw()).observe(canvas);
    canvas.addEventListener('pointermove', (e) => this.#pointer(e));
    canvas.addEventListener('pointerdown', (e) => this.#pointer(e));
    canvas.addEventListener('pointerleave', (e) => {
      if (e.pointerType === 'mouse') this.#setScrub(null);
    });
    canvas.addEventListener('keydown', (e) => this.#key(e));
  }

  /** samples ascending by time; from/to the visible window (ms); target °C or null. */
  set(data) {
    this.#data = { ...this.#data, ...data };
    if (this.#scrubTime != null) this.#setScrub(this.#scrubTime, false);
    this.draw();
  }

  get scrubbing() { return this.#scrubTime != null; }

  #visible() {
    const { samples, from, to } = this.#data;
    // Keep one sample either side so lines run to the edges.
    let lo = 0;
    while (lo < samples.length && samples[lo].time < from) lo++;
    let hi = samples.length;
    while (hi > 0 && samples[hi - 1].time > to) hi--;
    return samples.slice(Math.max(0, lo - 1), Math.min(samples.length, hi + 1));
  }

  #series(sample) {
    const { mode } = this.#data;
    if (mode === 'all') return sample.temps.map((t, i) => ({ i, t }));
    return [{ i: 'core', t: sample.temps[sample.vs[0]] }, { i: 'surface', t: sample.temps[sample.vs[1]] }, { i: 'ambient', t: sample.temps[sample.vs[2]] }];
  }

  #yRange(visible) {
    const { unit, target } = this.#data;
    const step0 = unit === 'F' ? 50 : 25;
    let lo = unit === 'F' ? 50 : 10;
    let hi = lo + step0 * 2;
    for (const s of visible) {
      for (const { t } of this.#series(s)) {
        const v = toUnit(t, unit);
        if (v == null) continue;
        hi = Math.max(hi, v);
        lo = Math.min(lo, v);
      }
    }
    if (target != null) hi = Math.max(hi, toUnit(target, unit));
    hi += unit === 'F' ? 30 : 15;
    const step = hi - lo > (unit === 'F' ? 300 : 150) ? step0 * 2 : step0;
    return { lo: Math.floor(lo / step) * step, hi: Math.ceil(hi / step) * step, step };
  }

  draw() {
    const c = this.canvas;
    const dpr = globalThis.devicePixelRatio || 1;
    const w = c.clientWidth;
    const h = c.clientHeight;
    if (!w || !h) return;
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
      c.width = Math.round(w * dpr);
      c.height = Math.round(h * dpr);
    }
    const g = c.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);

    const { from, to, unit, target, mode, period } = this.#data;
    const visible = this.#visible();
    const y = this.#yRange(visible);
    const left = 52;
    const right = target != null ? 56 : 18;
    const top = 10;
    const bottom = 30;
    const pw = Math.max(10, w - left - right);
    const ph = Math.max(10, h - top - bottom);
    const xOf = (t) => left + ((t - from) / Math.max(1, to - from)) * pw;
    const yOf = (v) => top + ph - ((v - y.lo) / (y.hi - y.lo)) * ph;
    this.#layout = { left, pw, xOf, from, to };

    const font = css('--font-num') || 'sans-serif';
    g.font = `500 14px ${font}`;
    g.textBaseline = 'middle';
    g.lineWidth = 1;
    g.strokeStyle = css('--grid');
    g.fillStyle = css('--muted');

    // Y grid and labels.
    g.textAlign = 'right';
    for (let v = y.lo; v <= y.hi + 1e-9; v += y.step) {
      const py = Math.round(yOf(v)) + 0.5;
      g.beginPath();
      g.moveTo(left, py);
      g.lineTo(left + pw, py);
      g.stroke();
      g.fillText(`${v}°`, left - 8, py);
    }
    // X grid on round times.
    const span = to - from;
    const stepMin = [5, 10, 15, 30, 60, 120, 240, 480].find((m) => span / (m * 60000) <= Math.max(2, pw / 110)) ?? 960;
    const stepMs = stepMin * 60000;
    const tz = new Date().getTimezoneOffset() * 60000;
    g.textAlign = 'center';
    g.textBaseline = 'top';
    for (let t = Math.ceil((from - tz) / stepMs) * stepMs + tz; t <= to; t += stepMs) {
      const px = Math.round(xOf(t)) + 0.5;
      g.beginPath();
      g.moveTo(px, top);
      g.lineTo(px, top + ph);
      g.stroke();
      g.fillText(clock(t), px, top + ph + 8);
    }

    // Target line, labelled outside the plot.
    if (target != null) {
      const py = Math.round(yOf(toUnit(target, unit))) + 0.5;
      g.strokeStyle = css('--target-line');
      g.lineWidth = 1.5;
      g.beginPath();
      g.moveTo(left, py);
      g.lineTo(left + pw, py);
      g.stroke();
      g.fillStyle = css('--text');
      g.textAlign = 'left';
      g.textBaseline = 'middle';
      g.fillText(`${Math.round(toUnit(target, unit))}°`, left + pw + 6, py);
    }

    // Series, clipped to the plot; a gap longer than 3 sample periods breaks the line.
    g.save();
    g.beginPath();
    g.rect(left, top - 4, pw, ph + 8);
    g.clip();
    g.lineJoin = 'round';
    g.lineCap = 'round';
    const colors = { core: css('--core'), surface: css('--surface'), ambient: css('--ambient') };
    const keys = mode === 'all' ? [0, 1, 2, 3, 4, 5, 6, 7] : ['core', 'surface', 'ambient'];
    const roleOf = (s, i) => (i === s.vs[0] ? 'core' : i === s.vs[1] ? 'surface' : i === s.vs[2] ? 'ambient' : null);
    // In "all" mode draw grey sensors first so the colored ones sit on top.
    const order = mode === 'all' && visible.length
      ? [...keys].sort((a, b) => (roleOf(visible.at(-1), a) ? 1 : 0) - (roleOf(visible.at(-1), b) ? 1 : 0))
      : keys;
    for (const key of order) {
      const last = visible.at(-1);
      const role = mode === 'all' ? (last ? roleOf(last, key) : null) : key;
      g.strokeStyle = role ? colors[role] : css('--other');
      g.lineWidth = mode === 'all' ? (role ? 2.5 : 1.5) : 3;
      g.beginPath();
      let prev = null;
      for (const s of visible) {
        const point = this.#series(s).find((p) => p.i === key);
        const v = toUnit(point?.t, unit);
        if (v == null) {
          prev = null;
          continue;
        }
        const px = xOf(s.time);
        const py = yOf(v);
        if (prev && s.time - prev.time <= period * 3) g.lineTo(px, py);
        else g.moveTo(px, py);
        prev = s;
      }
      g.stroke();
    }
    g.restore();

    // Scrub line and dots.
    const scrub = this.#scrubSample(visible);
    if (scrub) {
      const px = Math.round(xOf(scrub.time)) + 0.5;
      g.strokeStyle = css('--scrub-line');
      g.lineWidth = 2;
      g.beginPath();
      g.moveTo(px, top);
      g.lineTo(px, top + ph);
      g.stroke();
      for (const key of mode === 'all' ? [] : ['core', 'surface', 'ambient']) {
        const v = toUnit(this.#series(scrub).find((p) => p.i === key)?.t, unit);
        if (v == null) continue;
        g.beginPath();
        g.arc(px, yOf(v), 7, 0, Math.PI * 2);
        g.fillStyle = colors[key];
        g.fill();
        g.lineWidth = 2.5;
        g.strokeStyle = '#fff';
        g.stroke();
      }
    }
  }

  #scrubSample(visible = this.#visible()) {
    if (this.#scrubTime == null || !visible.length) return null;
    let best = visible[0];
    for (const s of visible) if (Math.abs(s.time - this.#scrubTime) < Math.abs(best.time - this.#scrubTime)) best = s;
    return best;
  }

  #pointer(e) {
    const l = this.#layout;
    if (!l) return;
    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    if (x < l.left || x > l.left + l.pw) {
      this.#setScrub(null);
      return;
    }
    this.#setScrub(l.from + ((x - l.left) / l.pw) * (l.to - l.from));
  }

  #key(e) {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight' && e.key !== 'Escape') return;
    e.preventDefault();
    if (e.key === 'Escape') return this.#setScrub(null);
    const visible = this.#visible();
    if (!visible.length) return;
    const cur = this.#scrubSample(visible) ?? visible.at(-1);
    const i = visible.indexOf(cur) + (e.key === 'ArrowLeft' ? -1 : 1);
    const next = visible[Math.min(visible.length - 1, Math.max(0, i))];
    this.#setScrub(next.time);
  }

  #setScrub(time, redraw = true) {
    this.#scrubTime = time;
    this.onScrub(time == null ? null : this.#scrubSample());
    if (redraw) this.draw();
  }
}
