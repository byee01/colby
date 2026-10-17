# 04. Release, beta, and crash reporting

Both apps ship only through their store. Every release goes through a beta stage first.

## 1. Pipeline

```
 PR ─▶ CI tests ─▶ main ─▶ tag vX.Y.Z ─▶ beta (internal) ─▶ beta (external) ─▶ store release
                                          │                  │
                                macOS:    TestFlight internal TestFlight external (Beta App Review)
                                Windows:  Package flight     Package flight (wider group)
```

| Stage | macOS | Windows | Review | Who |
|---|---|---|---|---|
| Dev | Local Xcode build, sandbox on | Local MSIX sideload (dev cert) | None | Developer |
| Internal beta | TestFlight internal testers (App Store Connect users, up to 100) | Partner Center package flight, group "internal" | macOS: none. Windows: Store certification | Developer + close testers |
| External beta | TestFlight external testers (up to 10,000; email or public link) | Package flight, group "beta" | macOS: Beta App Review on first build of a version | Invited users with probes |
| Release | App Store submission of the same build | Promote flight package to the public submission | Full review | Everyone |

The same binary moves from beta to release. Never rebuild for release.

## 2. macOS: TestFlight

Setup (once, during M7):
1. App ID + bundle ID; App Store Connect app record "Colby - Desktop monitor for Combustion thermometers".
2. Entitlements: App Sandbox, `com.apple.security.device.bluetooth`. Info.plist: `NSBluetoothAlwaysUsageDescription`.
3. App Store Connect API key (Issuer ID, Key ID, `.p8`) stored as CI secrets.
4. Groups: `Internal` (no review), `Beta` (external).
5. Beta App Review notes: "Requires a Combustion Predictive Thermometer. Use Demo Mode (menu bar → Demo) to replay a recorded cook." Attach a demo video link.

Per build:
- `CFBundleShortVersionString` = `X.Y.Z` from tag; `CFBundleVersion` = CI run number (must strictly increase).
- `xcodebuild archive` → `xcodebuild -exportArchive` (method `app-store-connect`) → upload with fastlane `pilot` (or `xcrun altool --upload-package`).
- Builds expire 90 days after upload. Keep at least one live build in the `Beta` group.
- Testers send feedback and crash reports through the TestFlight app; they show up in App Store Connect → TestFlight → Feedback.

## 3. Windows: Microsoft Store package flights

Windows has no TestFlight. The equivalent is **package flights** in Partner Center: separate packages shown only to named flight groups (Microsoft account emails).

Setup (once, during W6):
1. Partner Center developer account; reserve app name.
2. First submission: publish with visibility **Private audience** (hidden from search) so flights can exist before the public launch. Verify this flow in Partner Center during W6.
3. Flight groups: `internal`, `beta`.
4. Microsoft Entra app registration for the Partner Center submission API; credentials stored as CI secrets.
5. Certification notes: same demo-mode text as macOS.

Per build:
- MSIX version `X.Y.Z.0`. The 4th part must be `0` for Store packages; bump `Z` per beta build (or encode build number in `Z`).
- Build `.msixupload` (includes `.appxsym` symbols for crash stacks).
- Upload to the flight with Microsoft Store Developer CLI (`msstore`) or the submission API. Flights still go through certification (usually hours, can be days).
- Promote: submit the same package to the non-flight (public) submission and change visibility to public at launch.

## 4. CI (GitHub Actions)

| Job | Runner | Steps |
|---|---|---|
| `mac-test` | `macos-latest` | `swift test` (codec + core vs `spec/fixtures`) |
| `win-test` | `windows-latest` | `dotnet test` (same fixtures) |
| `mac-beta` | `macos-latest`, on tag | archive → export → upload to TestFlight → assign to `Internal` |
| `win-beta` | `windows-latest`, on tag | build MSIX upload → submit to `internal` flight |
| Manual promote | workflow_dispatch | macOS: add build to `Beta` group / submit for review. Windows: move to `beta` flight / public submission |

Secrets: App Store Connect API key; signing certificate + provisioning profile (or Xcode automatic signing via API key); Partner Center tenant ID, client ID, client secret, seller ID.

## 5. Crash reporting

Only the reporting each store provides. No third-party SDK, so no extra data shared and no extra privacy-label entries.

| | macOS | Windows |
|---|---|---|
| Source | Users who opt in to share analytics with developers; TestFlight testers by default | Windows Error Reporting for Store apps |
| Where to read | Xcode → Organizer → Crashes; App Store Connect → TestFlight feedback | Partner Center → Health report (failure hits, stack traces, `.cab` downloads) |
| Symbols | dSYMs uploaded with the archive (keep "Include symbols" on) | `.appxsym` inside `.msixupload` |
| In-app extra | `MetricKit` subscriber: log `MXCrashDiagnostic` / hang diagnostics to the local diagnostics view | Log unhandled exceptions to a local file shown in the diagnostics view |
| Privacy label | "Diagnostics → Crash Data, not linked to user" if Apple's collection is declared | Privacy policy URL in Store listing |

Both stores require a privacy policy URL. Content: no account, no network calls, no data leaves the device except the OS crash reporting the user opted into.

Upgrade path if store crash data is too thin: add Sentry (supports Swift and .NET). That changes the privacy labels and needs a privacy policy update. Not planned for v1.

## 6. Release checklist

- [ ] All fixtures pass on both platforms
- [ ] 12 h recorded-cook replay in demo mode: no gaps, alerts fire, keep-awake held
- [ ] Real cook with probe direct and via Display on the beta build
- [ ] Window closed for a full cook: alerts still fire from menu bar / tray
- [ ] Login item off by default; turning it on works
- [ ] No crashes in Organizer / Health report for the beta build over ≥ 1 week of external testing
- [ ] Review notes + demo video current
