<h1 align="center">HealthLog Companion App for iPhone and Apple Watch</h1>

<p align="center">
  The native iOS app for <a href="https://github.com/MBombeck/HealthLog">HealthLog</a>, the self-hosted health tracker you run on your own server.<br />
  <strong>Your health on your iPhone. Your data on your server.</strong>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6769501341"><img src="https://img.shields.io/itunes/v/6769501341?label=App%20Store&color=0D96F6" alt="HealthLog on the App Store" /></a>
  <img src="https://img.shields.io/badge/iOS-18%2B-000000" alt="iOS 18 or later" />
  <img src="https://img.shields.io/badge/watchOS-11%2B-000000" alt="watchOS 11 or later" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-PolyForm%20Noncommercial%201.0.0-blue.svg" alt="License: PolyForm Noncommercial 1.0.0" /></a>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6769501341"><strong>Download on the App Store</strong></a> &middot;
  <a href="https://healthlog.dev/">healthlog.dev</a> &middot;
  <a href="https://docs.healthlog.dev/ios/ios-app/">iOS docs</a> &middot;
  <a href="https://github.com/MBombeck/HealthLog">Server project</a> &middot;
  <a href="https://healthlog.dev/support">Support</a>
</p>

---

<p align="center">
  <img src="docs/screenshots/ios-dashboard.png" width="240" alt="HealthLog home screen in dark mode: a medication compliance ring showing 2 of 3 doses taken today, and tiles for weight, blood pressure and pulse, each with a trend line. Synthetic demo data." />
  <img src="docs/screenshots/ios-medications.png" width="240" alt="Medications list in dark mode: one card per medication with last and next intake, 7-day and 30-day compliance bars, and Taken and Skipped buttons. Synthetic demo data." />
  <img src="docs/screenshots/ios-sharing.png" width="240" alt="Share screen in dark mode: pick what is included, the time range, and the output as a revocable link, a PDF report or a ZIP record. Synthetic demo data." />
</p>

HealthLog is a health tracker for iPhone and Apple Watch that stores everything on a server you run yourself. It keeps Apple Health (HealthKit) in two-way sync with that server, reminds you about your medications, and shows blood pressure, weight, glucose, sleep and your other readings as charts you can actually read. It is meant for people who self-host things: in a homelab, on a NAS or on a small VPS.

The app needs a [HealthLog server](https://github.com/MBombeck/HealthLog) to talk to. It has no built-in server and no default address. On first launch you enter the URL of your own instance, and every reading you log lands in the same database your HealthLog web app reads from. If you don't have a server yet, you can look around on the public demo first (see below).

This repository holds the full source of the app. Each [release](https://github.com/MBombeck/healthlog-iOS/releases) here matches an App Store build, and the [CHANGELOG](CHANGELOG.md) lists what changed.

## Getting the app

The easiest way is the [App Store](https://apps.apple.com/app/id6769501341). HealthLog costs a small one-time price there, with no subscription and no in-app purchases. The price helps cover Apple's yearly developer fee. If the price is a problem for you, write to [marc@healthlog.dev](mailto:marc@healthlog.dev) and you'll get a free code, no questions asked. The [App Store announcement](https://github.com/MBombeck/healthlog-iOS/discussions/8) has the background.

There are two free alternatives. The [TestFlight beta](https://testflight.apple.com/join/bucuTBpa) gets new builds before the App Store does. You can also build the app yourself from this repository; the steps are further down.

## Try it with the demo server

1. Install the app and open it. The first screen asks for a server address.
2. Enter `https://demo.healthlog.dev`.
3. Sign in with the demo credentials from the demo section on [healthlog.dev](https://healthlog.dev/).

The demo holds about a year of synthetic data. You can browse all of it, but changes are not saved.

## What the app does

- **Home screen.** Today at a glance: a health ring, your medication compliance, and tiles for blood pressure, pulse, weight, steps, mood, glucose and sleep. A "+" sheet lets you log any metric your server tracks.
- **Apple Health sync in both directions.** Weight, blood pressure, heart rate, HRV, blood oxygen, glucose and mood (State of Mind) go both ways. Steps, activity, workouts, sleep stages and ECG recordings go from Apple Health to your server. Every write carries an external ID, so the server and Apple Health don't copy each other's entries back and forth. The [table below](#what-syncs-with-apple-health) has the details.
- **Medication tracker and reminders.** Daily, weekly, cyclic, rolling and as-needed schedules. You can correct past intakes. Due doses show up as Live Activities, and the buttons in a reminder notification record a dose without opening the app. GLP-1 medications also get drug-level curves calculated from your actual doses, titration plans, injection-site tracking and a side-effects log.
- **Charts.** Every metric has a detail view with a linear or logarithmic axis, a time range picker, reference bands from the ESC/ESH and ADA guidelines, and VoiceOver descriptions. Reference ranges and scores link to the sources they are based on.
- **Insights and an optional coach.** A health score breakdown, correlation cards, a daily briefing and a coach you can ask about your numbers. All AI features are off until you turn them on (see [Privacy](#privacy)).
- **Apple Watch, widgets and Shortcuts.** A Watch app with complications, home screen and lock screen widgets, App Intents for Siri and Shortcuts ("Did I take my medication?"), and Spotlight search for your medications.
- **Sharing with your doctor.** You choose what is included, the time range and the format: a link you can revoke, a PDF report, or a ZIP of the record. There is also a doctor report based on FHIR with LOINC codes.

The app is available in English and German.

## What syncs with Apple Health

| Data | Direction | Notes |
| --- | --- | --- |
| Steps, active energy, walking distance, flights climbed | Apple Health → server | Today's value is read live from HealthKit, earlier days come from the server. |
| Weight, body fat, BMI, body temperature, VO₂ max | Apple Health ↔ server | Writes from the app carry `HKMetadataKeyExternalUUID` so re-reads are recognised and not duplicated. |
| Blood pressure, heart rate, resting heart rate, HRV, blood oxygen, blood glucose | Apple Health ↔ server | Same duplicate protection. The server is the reference for values you typed in, Apple Health for values a device measured. |
| Mood (State of Mind) | Apple Health ↔ HealthLog | Can be turned off in the app's settings. |
| Sleep stages, walking metrics, respiratory rate and other measured values | Apple Health → server | |
| ECG recordings | Apple Health → server | |
| Workouts with heart rate detail | Apple Health → server | Sent as workout bundles. |
| Medication intakes, notes | Server only | HealthKit has no standard type for these, so the app and the web UI write them to the server directly. |

You decide per data type in the iOS permission sheet what the app may read and write. Types you don't allow stay on the phone.

## Requirements

- An iPhone with iOS 18 or later. The Watch app needs watchOS 11.
- A [HealthLog server](https://github.com/MBombeck/HealthLog) the phone can reach over HTTPS, or the demo server for a first look. Keep the server up to date: the app checks the server version and only offers features your server supports. Signing in through your instance's own login page needs server v1.32.11 or later.
- For the on-device coach: an iPhone that supports Apple Intelligence, on iOS 26.

## Signing in

You sign in to your own server, never to an account of ours. Email and password work everywhere. On a current server the app can also open your instance's login page in a secure in-app browser, so passkeys, your password manager and single sign-on work the same way they do on the web. Tokens are kept in the iOS Keychain and refresh in the background.

If you build the app yourself under your own bundle ID, you can also enable native passkeys for your host. [docs/self-hosting.md](docs/self-hosting.md) explains how.

## Privacy

There is no HealthLog cloud. The app talks to the server you chose and to nothing else that we run. There is no developer backend, no account with us, no analytics SDK, no tracking and no advertising.

The coach is off until you choose how it should work, and you can pick none of the options:

- **On the device** with Apple Intelligence (iOS 26). Nothing leaves the iPhone.
- **Your own provider key** for Anthropic, OpenAI, Google Gemini or any OpenAI-compatible endpoint. Requests go straight from the phone to that provider, and the key stays in your Keychain.
- **Your server's provider**, if your HealthLog instance has one configured.

Before any health data goes to a provider, the app tells you what it sends. The full policy is at [healthlog.dev/privacy](https://healthlog.dev/privacy).

HealthLog is not a medical device. It does not diagnose, treat or give medical advice, and it doesn't replace your doctor.

## How it works

```
SwiftUI Views
    ↓
@MainActor @Observable Stores
    ↓
Repositories (stale-while-revalidate + Outbox)
    ↓
Actor-based Services  (APIClient, HealthKit, Passkey, Notifications)
    ↓
Codable + Sendable Models
```

The code uses Swift 6 strict concurrency throughout. When the network is down, the Outbox queues every write in a local SwiftData store and replays it the next time the server is reachable. Each POST carries an idempotency key that is stored with the queued payload, so a retry can't create a second entry.

`HealthLogCore` is an internal SPM library defined in [`Package.swift`](Package.swift). It holds the platform-independent layers: models, APIClient, Keychain, logger, repositories, sync and pharmacokinetics. `swift build` compiles it without iOS, which doubles as an architecture check: core code can't quietly pick up a UIKit or HealthKit dependency.

More detail lives under [`docs/`](docs/): architecture, security, the API contract, and the decision log that explains the bigger choices.

## Build from source

The repository does not commit `HealthLog.xcodeproj`. [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates it from `project.yml`. The SwiftPM lockfile inside the workspace is tracked, so dependency versions are pinned.

```bash
brew install xcodegen swiftlint swiftformat

git clone https://github.com/MBombeck/healthlog-iOS.git
cd healthlog-iOS

# For device builds: set DEVELOPMENT_TEAM in project.yml to your own team ID.
# Simulator builds work without it.

xcodegen
open HealthLog.xcodeproj    # scheme: HealthLog
```

You need a Mac with macOS 15 or later and Xcode 26.6 (the pinned toolchain, see `project.yml` and CI). Device installs need an Apple Developer account; simulator builds don't.

The platform-independent core also builds without Xcode:

```bash
swift build    # compiles HealthLogCore
```

CI holds the project to these gates: `swiftlint` and `swiftformat --lint` clean, `xcodebuild build` with warnings as errors, and a green test suite. [TESTING.md](TESTING.md) has the exact commands and the simulator baseline.

**Certificate pinning is opt-in and up to whoever runs the server.** The repository ships no pins and no pinned host, because there is no built-in server to pin. A build without pinning validates through system trust, which is the normal case. If you want pinning, passkeys or universal links in your own build, provide the Info.plist keys that `CertificatePinner` reads (`HLPinnedHosts`, `HLPinnedSPKIHashes`, `HLPasskeyRelyingPartyHosts`) in your own build configuration. `scripts/extract-spki.sh` computes the SPKI hashes for your host. A release build crashes early if the configuration is only half there (hashes without hosts or the other way round), because that looks like pinning but isn't. `Config/local.example.yml` shows the shape of such an overlay.

## Project layout

```
├── HealthLog/                  # iOS app target
│   ├── App/                    # Entry point, AuthenticatedShell, RootView
│   ├── Cache/                  # SwiftData-backed snapshots + invalidator
│   ├── DesignSystem/           # HLCard, HLText, HLSpace, HLRing, …
│   ├── FHIR/                   # SpeziFHIR mapping for doctor-report export
│   ├── Intents/                # App Intents / Shortcuts
│   ├── LiveActivity/           # Medication Live Activities
│   ├── Models/                 # Codable + Sendable domain types
│   ├── Pharmacokinetics/       # GLP-1 level modelling (EMA-parameterised)
│   ├── Repositories/           # SWR + Outbox network glue
│   ├── Screens/                # SwiftUI screen surfaces
│   ├── Services/               # APIClient, Keychain, HealthKit, Passkey, AI/
│   ├── Standalone/             # Local-only runtime (its entry point is switched off in release builds)
│   ├── Stores/                 # @MainActor @Observable view-models
│   └── Sync/                   # BackgroundSyncCoordinator + cluster filter
├── HealthLogWatch/             # watchOS companion app
├── HealthLogWidgets/           # Home/lock-screen widgets
├── HealthLogTests/             # Swift Testing + SnapshotTesting
├── HealthLogUITests/           # XCUITest journeys
├── docs/                       # Architecture, security, API contract, ADRs
├── scripts/                    # Lint/i18n gates, SPKI extractor, contract checks
├── Package.swift               # HealthLogCore SPM library definition
└── project.yml                 # XcodeGen source-of-truth
```

## Acknowledgements

This app is built on [Stanford Spezi](https://github.com/StanfordSpezi) ([spezi.stanford.edu](https://spezi.stanford.edu)), the open-source digital health framework from Stanford's Biodesign Digital Health group, and it deserves loud credit. Sixteen Spezi packages carry HealthLog's HealthKit integration, FHIR mapping, LLM plumbing, Bluetooth device support, scheduling, onboarding, storage and more, plus four packages from the sibling [StanfordBDHG](https://github.com/StanfordBDHG) org (HealthKitOnFHIR among them). Spezi helped this project enormously. If you build health software for Apple platforms, look at it first.

Beyond the Spezi ecosystem, HealthLog iOS uses Apple's [FHIRModels](https://github.com/apple/FHIRModels) and the [swift-openapi](https://github.com/apple/swift-openapi-generator) stack, [MLX Swift](https://github.com/ml-explore/mlx-swift), [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui), [Pow](https://github.com/EmergeTools/Pow), [SQLite.swift](https://github.com/stephencelis/SQLite.swift), Point-Free's [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing), and more community packages pinned in the tracked `Package.resolved`. All dependencies come in through Swift Package Manager under their own licenses; nothing is vendored into this tree.

## Feedback, bug reports and contributions

The most useful things you can do:

- **Run the app** against your own server (or the demo) and tell me where it breaks.
- **Open an [issue](https://github.com/MBombeck/healthlog-iOS/issues)** with the build number from **More → About**, one line on what you tried, one line on what happened compared with what you expected, a screenshot if it's visual, and whether it happens again.
- **Tell me what's missing.** The roadmap follows what people who self-host actually reach for.
- **Pull requests** are welcome for small fixes and tests. For larger work please open an issue first so we don't duplicate effort. Working with AI tooling is fine; [CONTRIBUTING-AI.md](CONTRIBUTING-AI.md) has the ground rules.

Questions that don't fit an issue go to the [support page](https://healthlog.dev/support). If you find a **security issue**, please report it privately through the [server project's security channel](https://github.com/MBombeck/HealthLog/security) instead of a public issue.

## License

HealthLog iOS is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE), the same license as the [server project](https://github.com/MBombeck/HealthLog). The source is available, and you may use, build and modify it for noncommercial purposes. Commercial use needs a separate agreement.

---

<p align="center">
  <a href="https://apps.apple.com/app/id6769501341">App Store</a> &middot;
  <a href="https://healthlog.dev/">Website</a> &middot;
  <a href="https://docs.healthlog.dev/ios/ios-app/">Documentation</a> &middot;
  <a href="https://github.com/MBombeck/HealthLog">Server project</a> &middot;
  <a href="https://testflight.apple.com/join/bucuTBpa">TestFlight</a> &middot;
  <a href="https://github.com/MBombeck/healthlog-iOS/issues">Issues</a>
</p>
