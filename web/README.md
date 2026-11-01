# Colby web

Browser version of Colby. It is plain static files: no server component, no build step, no third-party requests.
Everything (Bluetooth, decoding, alerts, history) runs in the page. Data stays in the browser (IndexedDB, localStorage).

## Run and host

The source runs as is (plain ES modules, no build). The deployed site is built from it.

| Task | Command |
|---|---|
| Develop | `cd web && npm run serve`, then open http://localhost:8080 (any static server works) |
| Test | `npm test` (Node 20+, no install needed) |
| Production build | `npm ci && npm run build` → `web/dist/` |
| Preview the build | `npm run preview`, then open http://localhost:8080 |
| Try without hardware | add `#demo` to the URL; `#setup` reopens the first-run setup |

Web Bluetooth needs a secure context: HTTPS, or `localhost`. Opening `index.html` from disk (`file://`) does not work.

### GitHub Pages

`.github/workflows/web.yml` tests and builds on every change to `web/` and deploys `web/dist` from `main` (or from
"Run workflow" in the Actions tab). One-time setup: Settings → Pages → Build and deployment → Source: **GitHub Actions**.
The site then lives at `https://<owner>.github.io/<repo>/`; all paths are relative, so the sub-path needs no config.

Limits to know:
- A private repository can use Pages only on a paid plan (GitHub Pro, Team or Enterprise); on GitHub Free the repo must
  be public.
- The `github-pages` environment only accepts deployments from the default branch unless you add other branches under
  Settings → Environments → github-pages.
- Pages sets `Cache-Control: max-age=600` and cannot be configured; hashed asset names and the service worker make that
  irrelevant for repeat visits.

### Why this setup

| Choice | Reason |
|---|---|
| No build for development | Edit, reload, test with nothing but Node and a static server; the tests import the source directly |
| esbuild for the deployed site only | One pinned dev dependency, builds in ~20 ms. One minified bundle instead of 25 modules imported five levels deep: 39 KB instead of 66 KB of JS (gzipped) and one request instead of five round trips. On a simulated slow link (150 ms RTT, 1.6 Mbps) the demo view appeared in 1.67 s instead of 2.18 s |
| Content-hashed names (`assets/app-<hash>.js`) | A deploy never mixes old and new files; the service worker serves them cache-first |
| Fonts preloaded (Barlow 400, Barlow Condensed 500) | They are on the first screen; the other weights load only when used |
| Generated service-worker file list | It always matches what was deployed; the cache name changes with the content, so old caches are dropped |

A first visit downloads about 64 KB gzipped before the page is usable (HTML, CSS, JS, two fonts); `npm run build`
prints the per-file sizes. After that the site works offline.

## Browser support

**Chrome or Edge only** (desktop or Android). Firefox, Safari and every iPhone/iPad browser are not supported: they
have no Web Bluetooth, so they cannot connect to a thermometer (the demo still runs there). The app says so on first load.

Source: [WebBluetoothCG implementation status](https://github.com/WebBluetoothCG/web-bluetooth/blob/main/implementation-status.md) (primary).

| Browser | Works |
|---|---|
| Chrome, Edge, Opera on Windows, macOS, ChromeOS | Yes |
| Chrome on Android | Yes |
| Chrome on Linux | Only with a flag; the spec group lists Linux as "partially implemented and not supported" |
| Firefox (all platforms) | No Web Bluetooth. Demo mode only |
| Safari, every iOS browser | No Web Bluetooth. Demo mode only |

## Features

| Feature | Web | Notes |
|---|---|---|
| Wire codec (advertisements, status, UART) | Yes | Port of `mac/Sources/CombustionCodec`; passes every file in `spec/fixtures` |
| Connect to a probe directly | Yes | The browser's device chooser opens on a click, once per device |
| Connect to a MeatNet node (Display, Timer, Booster) | Yes | Recommended: one connection gives every probe on the network |
| Live temperatures, all 8 sensors, virtual core/surface/ambient | Yes | |
| Prediction countdown (same rounding as the Display) | Yes | Port of `PredictionPresenter` |
| Set target, set probe high/low alarms, silence alarms | Yes | Confirmed by the next status, as on desktop |
| History backfill (Read Logs) and stored cooks | Yes | IndexedDB; CSV export |
| App alerts (ready, 5 min, offline, battery, custom temperature rules) | Yes, while the page is open | Port of `AlertEngine` |
| Alerts while Colby's tab is in the background | Yes | Bluetooth data still arrives; a Web Worker heartbeat drives the app clock so timers stay on time; sound, notifications and a flashing tab title |
| Alarm sound | Yes, also from a background tab | Web Audio; needs one click on the page first (the setup's "Test alert" does it) |
| System notifications | Yes, after permission | Through the service worker, with Acknowledge and Snooze buttons that act without switching tabs; raised when an alert fires while the tab is hidden or unfocused |
| First-run setup | Yes | Bluetooth check, notification permission, background tips; shown again while Bluetooth is unusable and nothing is set up (`#setup` forces it) |
| Keep the computer awake during a cook | Partly | Screen Wake Lock; the browser releases it when the tab is hidden |
| Kitchen mode | Yes | Full screen |
| Reconnect after a dropped link | Yes | Backoff 1, 2, 4 … 30 s |
| Reconnect after reloading the page | Flag only | `getDevices()` needs chrome://flags/#enable-experimental-web-platform-features; otherwise pick the devices again |
| Passive advertisement scanning (no connection) | Flag only | `requestLEScan()`, same flag |
| Probe serial and signal strength on a direct connection | Flag only | `watchAdvertisements()`, same flag. Without it a direct probe gets a stand-in ID (see below) |
| Alerts with the tab closed or the computer asleep | No | Service workers cannot use Bluetooth |
| Menu bar / tray icon, widgets, start at login | No | No web APIs |

### Background tabs and notifications

What keeps working with Colby in a background tab, and what stops it. Sources: [Chrome 88 timer throttling](https://developer.chrome.com/blog/timer-throttling-in-chrome-88/) (primary: hidden-tab timers batched to once a minute after 5 minutes, unless the page made sound in the last 30 s); worker timers are not batched per [secondary sources](https://www.github.com/chrisguttandin/worker-timers), so Colby drives its clock from a worker.

| Situation | Alerts |
|---|---|
| Another tab or app in front | Work: sound, notification (if allowed), flashing tab title |
| Notifications not allowed | Sound and the in-tab band and title only; no pop-up, no Acknowledge/Snooze outside Colby. The setup and Settings say how to allow them |
| Incognito / private window | Chrome blocks notifications there without asking; use a normal window |
| Tab closed, browser closed | Stop. Colby asks before closing during a cook |
| Computer asleep | Stop. The screen is kept awake only while the tab is visible |
| Chrome Memory Saver unloads the tab | Stop. Add the site to "Always keep these sites active" or pin the tab. On return Colby says it was unloaded |
| Tab frozen and resumed | Colby reconnects dropped links on resume |
| Android | Chrome pauses background tabs after a while; keep Colby on screen |

Checked in Chromium with an emulated hidden tab: the demo's alert fired, the notification showed both buttons, Acknowledge
from the notification cleared the alert without bringing the tab forward, and the tab title flashed. Real 5-minute
throttling and Memory Saver were not reproduced in tests.

Stand-in ID: a direct probe connection does not carry the probe serial (it is only in advertisements), and Web
Bluetooth blocks the Serial Number characteristic `0x2A25` ("Block access to standardized unique identifiers, for
privacy reasons", [GATT blocklist](https://github.com/WebBluetoothCG/registries/blob/master/gatt_blocklist.txt)). Without the flag, a directly connected probe is labelled with an ID derived
from the browser's device ID. If the same probe is also seen through a node, it then shows up twice. Using a node avoids
this.

## Other open-source implementations

No other browser client for Combustion devices was found (searched 2026-10-31). What the others contributed here:

| Project | Type | Used for |
|---|---|---|
| [combustion-android-ble](https://github.com/combustion-inc/combustion-android-ble) | Primary (vendor SDK, Kotlin) | Device Information is `0x180A` on every product; Model Number strings (`Timer` = Display, `Charger` = Booster, empty = probe); probes advertise the Probe Status service; UART written without response |
| [Android PR #190](https://github.com/combustion-inc/combustion-android-ble/pull/190) | Primary | A log reset counts only when `logRange.max` falls by 2 or more (a relayed status can lag by one) |
| [Android PR #191](https://github.com/combustion-inc/combustion-android-ble/pull/191) | Primary | Session ID and sample period are the 6 bytes after the alarms; ID 0 means not supplied (matches the codec) |
| [combustion_ble](https://github.com/legrego/combustion_ble) | Secondary (Python, port of the Swift SDK) | Nothing new |
| [homeassistant-combustion](https://github.com/legrego/homeassistant-combustion), [maintained fork](https://github.com/Milkbone911/homeassistant-combustion) | Secondary (Python) | Hop count in the top 2 bits (matches); UART written without response |

## Layout

| Path | Contents | Swift counterpart |
|---|---|---|
| `src/codec/` | Pure codec | `CombustionCodec` |
| `src/core/` | Store, presenter, UART client, links, commands, alerts, history, app facade | `CombustionCore` |
| `src/transport/webBluetooth.js` | Web Bluetooth GATT connection, chooser, flagged APIs | `CombustionCoreBluetooth` |
| `src/transport/simulated.js` | Simulated probe and node (demo, tests) | `CombustionSim` |
| `src/ui/` | Page controller, canvas graph, formatters, notification/sound/wake-lock adapters | (SwiftUI app, not built yet) |
| `fonts/` | Barlow and Barlow Condensed, SIL OFL 1.1 (`fonts/OFL.txt`) | |

`src/core` and `src/codec` have no DOM code, so they run under Node for tests.

## Tests

```
cd web && npm test     # node --test, no dependencies; Node 20+
```

The suite runs all codec fixtures plus core tests on a fake clock: prediction smoothing, UART correlation, alert engine,
session tracking and backfill, and the whole app against a simulated probe and a simulated node (connect, backfill,
commands, alarm acknowledge and snooze, legacy firmware, reconnect). `test/replay.test.js` feeds every hardware
capture in `spec/replays` (probe fw v2.3.3, Display fw v2.6.0, recorded on macOS and Windows) through the app.

Not tested: Web Bluetooth itself against real hardware. The captures cover the bytes and their timing, not the browser's
Bluetooth stack.
