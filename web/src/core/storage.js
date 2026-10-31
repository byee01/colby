// Browser persistence. History in IndexedDB (same methods as MemoryHistoryStorage); small settings in localStorage.
// Storage can be unavailable (private windows, blocked site data); everything degrades to memory.

import { MemoryHistoryStorage } from './history.js';

const DB_NAME = 'colby';
const DB_VERSION = 1;

function request(r) {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

/** Sessions in `sessions` (keyPath key), samples in `samples` (keyPath [key, seq]). */
export class IndexedDbHistoryStorage {
  static async open() {
    if (!globalThis.indexedDB) return new MemoryHistoryStorage();
    try {
      const open = indexedDB.open(DB_NAME, DB_VERSION);
      open.onupgradeneeded = () => {
        const db = open.result;
        if (!db.objectStoreNames.contains('sessions')) db.createObjectStore('sessions', { keyPath: 'key' });
        if (!db.objectStoreNames.contains('samples')) db.createObjectStore('samples', { keyPath: ['key', 'seq'] });
      };
      return new IndexedDbHistoryStorage(await request(open));
    } catch (e) {
      console.warn('IndexedDB unavailable; history is kept in memory only', e);
      return new MemoryHistoryStorage();
    }
  }

  constructor(db) {
    this.db = db;
    // Ask the browser not to evict history under storage pressure (best effort).
    globalThis.navigator?.storage?.persist?.().catch(() => {});
  }

  #store(name, mode = 'readonly') {
    return this.db.transaction(name, mode).objectStore(name);
  }

  async loadSessions() { return request(this.#store('sessions').getAll()); }
  async putSession(session) { await request(this.#store('sessions', 'readwrite').put(session)); }

  async deleteSession(key) {
    const tx = this.db.transaction(['sessions', 'samples'], 'readwrite');
    tx.objectStore('sessions').delete(key);
    tx.objectStore('samples').delete(IDBKeyRange.bound([key, 0], [key, Infinity]));
    await new Promise((resolve, reject) => {
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  }

  async loadSamples(key) {
    const rows = await request(this.#store('samples').getAll(IDBKeyRange.bound([key, 0], [key, Infinity])));
    return rows.map(({ key: _k, ...s }) => s);
  }

  async putSamples(key, samples) {
    const tx = this.db.transaction('samples', 'readwrite');
    const store = tx.objectStore('samples');
    for (const s of samples) store.put({ key, ...s });
    await new Promise((resolve, reject) => {
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  }
}

/** localStorage with a memory fallback; values are JSON. */
export const prefs = {
  memory: new Map(),
  get(key, fallback) {
    try {
      const v = globalThis.localStorage?.getItem(`colby.${key}`);
      if (v != null) return JSON.parse(v);
    } catch {
      /* storage blocked */
    }
    return this.memory.has(key) ? this.memory.get(key) : fallback;
  },
  set(key, value) {
    this.memory.set(key, value);
    try {
      globalThis.localStorage?.setItem(`colby.${key}`, JSON.stringify(value));
    } catch {
      /* storage blocked */
    }
  },
};

/** Alert rules per probe in localStorage. */
export const prefsRuleStore = {
  async load(serial) { return prefs.get(`rules.${serial}`, null); },
  async save(serial, rules) { prefs.set(`rules.${serial}`, rules); },
};
