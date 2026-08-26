# Testing the iOS App

Concrete steps to get HealthLog iOS running in the Simulator. **No Apple Developer Team-ID needed for Simulator builds** — only required for physical device + TestFlight.

## One-time setup

```bash
brew install xcodegen swiftformat swiftlint
```

Full Xcode 16+ is required (not just Command Line Tools — Swift Testing module ships only with Xcode 16). Install from the App Store.

## Run

```bash
cd healthlog-iOS
xcodegen
open HealthLog.xcodeproj
```

In Xcode:
1. Select scheme **HealthLog**
2. Choose any iPhone Simulator (iPhone 16 Pro recommended)
3. ⌘R to build + run

There is **no default server**: `AppEnvironment.baseURL` is `nil` until you enter your own instance's address in onboarding (it is then stored in the Keychain). Until then every request fails with `HLError.serverNotConfigured` — a setup state, not a network error.

## What works against production today

| Flow | Server | iOS code | Verified |
|------|--------|----------|----------|
| Login (email + password) | ✅ PR #117 | ✅ Phase 1 | needs runtime check |
| Login (passkey) | ✅ PR #117 | ✅ Phase 1 | needs runtime check |
| Bearer-token auto-issue | ✅ PR #117 | ✅ `X-Client-Type: native` header | needs runtime check |
| Dashboard summary | ✅ `/api/dashboard/summary` | ✅ Phase 4 cards layout | needs runtime check |
| Measurements list / series | ✅ `/api/measurements/*` | ✅ Phase 5 + body water/bone mass (PR #1) | needs runtime check |
| Mood capture | ✅ `/api/mood-entries` | ✅ Phase 5 | needs runtime check |
| Medications + intake | ✅ `/api/medications/*` | ✅ Phase 5 | needs runtime check |
| Charts / Insights / Achievements | ✅ aggregator endpoints | partial Phase 6 | needs runtime check |
| Settings + Doctor Report | ✅ `/api/user/profile` + `/api/doctor-report` | partial Phase 7 | needs runtime check |
| HealthKit sync | ✅ `/api/integrations/healthkit` | ✅ Phase 3 | **Simulator can't generate HK data — needs physical device** |

## What needs additional setup before testing

### Push notifications (Phase 8 — deferred)

- Generate APNs `.p8` key in Apple Developer Portal
- Configure server-side APNs sender (HTTP/2 + key) — not implemented yet
- Add `aps-environment` capability to Xcode project (already in entitlements)

Without this, `/api/devices` registration succeeds but no pushes ever arrive. The app still works for everything else.

### Physical device + TestFlight (Phase 9 — deferred)

> **Correction, 2026-08-25 (Phase-23 legibility sweep).** The `HL_LOCAL_CONFIG` overlay described below is **not wired today**. Commit `04130697` (*"fix(release): keep distributed builds operator-neutral"*, 2026-08-12) deleted the `include: { path: Config/local.yml, enable: ${HL_LOCAL_CONFIG} }` block from `project.yml` and the automatic export from the release script. `project.yml` now contains no `include:` at all, so `HL_LOCAL_CONFIG=1 xcodegen` currently has **no effect** and `Config/local.yml` is never read. Distributed builds are operator-neutral by construction rather than by discipline. Nothing was re-wired for this correction — the mechanism was measured, not restored. If you need pinning, passkeys or universal links in your own build, inject the Info.plist keys `CertificatePinner` reads yourself.

1. Set `DEVELOPMENT_TEAM: "<your-team-id>"` in `project.yml`
2. `xcodegen` to regenerate
3. Plug in iPhone, select it as run destination
4. Apple Developer Portal: register `dev.healthlog.app` bundle ID with HealthKit + Push capabilities
5. Cert pinning (optional): extract SPKI hashes with `scripts/extract-spki.sh <host>`, paste them plus your host into `Config/local.yml` (template: `Config/local.example.yml`, gitignored), then build with `HL_LOCAL_CONFIG=1 xcodegen`

## Testing flows manually

1. **Cold-launch login** — open app, complete onboarding, login with PWA credentials. Verify Bearer token persists by killing + relaunching.
2. **Dashboard cold-load** — should show greeting, streak, compliance ring, metric cards within ~1.2s of launch.
3. **Add a measurement** — Tab → Measure → Weight → enter value → save. Verify it appears in list + on server (check the PWA of the configured host).
4. **Offline write** — turn on Airplane Mode, save a measurement, turn off Airplane Mode → verify it syncs (Outbox replay).
5. **Pull-to-refresh** on Dashboard — verify it re-fetches `/api/dashboard/summary`.
6. **Logout** — Settings → Logout → verify keychain cleared, falls back to login screen.

## Running tests

```bash
xcodebuild test \
  -project HealthLog.xcodeproj \
  -scheme HealthLog \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest'
```

Or in Xcode: ⌘U.

The HealthLogTests target uses Swift Testing (Xcode 16+ only). UITests use XCTest.

## Known gaps + roadmap

See `.planning/ROADMAP.md` for phase breakdown. Current state:

- Phases 0–7 — code complete, needs runtime verification
- Phase 8 (notifications + widgets) — deferred until APNs key + server-side sender
- Phase 9 (polish + TestFlight) — deferred until Team-ID

## CI

GitHub Actions runs the CI source-contract self-test, `swiftformat --lint`, the
fail-closed exact SwiftLint warning-baseline self-test and live gate, the i18n
and string-catalog gates, `xcodegen`, `xcodebuild build`, `xcodebuild test`, and
`swift build` (HealthLogCore SPM target) on every PR. The `macos-26` runner uses
the exact Xcode 26.6 release/archive toolchain pinned in `project.yml`. See
`.github/workflows/ci.yml`.
