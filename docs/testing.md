# Testing

## Workflow (TDD)

Jedes Feature:

1. **Failing Test schreiben.**
2. Implementation minimal bis Test gruen.
3. Refactor.
4. UI-Test (XCUITest) sobald View existiert.

## Test-Pyramide

| Layer | Anteil | Framework |
|-------|--------|-----------|
| Unit | 60% | Swift Testing (`@Test`) — Models, DTOs, Repositories, Stores |
| Integration | 30% | XCTest — APIClient gegen URLProtocol-Mocks, HealthKit gegen `HKHealthStoreMock`, SwiftData mit InMemory-Container |
| UI | 10% | XCUITest — Onboarding, Erste Messung, Med-Take, Login |

## Coverage-Gate

- **Lines:** ≥80% im Domain- und Service-Layer.
- **Branches:** ≥70% im Domain- und Service-Layer.
- Views ausgenommen.
- CI-Enforcement via `xccov`.

## Snapshot-Tests

- Library: [`pointfreeco/swift-snapshot-testing`](https://github.com/pointfreeco/swift-snapshot-testing) v1.17+
- Pro Design-System-Komponente (HLCard, HLButton, HLBadge, HLListRow, HLSparkline, HLRing, HLTabBar): mindestens Light + Dark + Dynamic-Type-xxxLarge.
- Referenz-Snapshots im Repo unter `HealthLogTests/__Snapshots__/`.
- Diff-Output gitignored.

## Performance-Tests

XCTest `measure`-Bloecke fuer:
- Cold-Start (Target: <1.2s auf iPhone 12+)
- Dashboard-Render (<100ms perceived)
- JSON-Decoding der grossen Responses (`/api/dashboard/summary`, `/api/insights/comprehensive`)

## Security-Tests

- Token niemals in Logs (Logger-Sanitizer-Test mit Mock-Output-Capture)
- Keychain-Persistenz nach App-Restart simuliert
- Cert-Pinning blockiert MITM (dedicated Scheme `HealthLog-MITM-Test` mit Mock-Proxy)

## Accessibility-Tests

- VoiceOver-Labels auf jeder benannten View (Programmatic Access-Test)
- `accessibilityChartDescriptor` auf Swift Charts geprueft
- Reduce-Motion-Wert wird respektiert (Snapshot-Diff zwischen ON/OFF)
- Dynamic-Type-xxxLarge-Snapshots brechen nicht das Layout

## Mocks

- **APIClient:** `URLProtocol`-Subklasse, registriert per `URLSessionConfiguration.protocolClasses`.
- **HealthKit:** `HKHealthStoreProtocol`-Abstraktion + `HKHealthStoreMock` mit pre-seeded Samples.
- **Keychain:** `KeychainStoring`-Protocol, In-Memory-Mock fuer Tests.
- **Reachability:** `ReachabilityProviding`-Protocol, programmatisch toggle-bar.

## CI-Pipeline

GitHub Actions (`.github/workflows/ci.yml`):

1. CI-Workflow-Contract und Server-Fixtures verifizieren
2. `swiftformat --lint .`
3. Exakten SwiftLint-Warnungsbaseline-Vergleich selbsttesten und live ausfuehren
4. i18n- und String-Katalog-Gates ausfuehren
5. `xcodegen` projekt generieren
6. `xcodebuild build` (Debug-Scheme, Simulator)
7. `xcodebuild test` (alle Tests, Coverage gemessen)
8. `swift build` (Core-Library standalone)

Der `macos-26` Runner verwendet dabei exakt Xcode 26.6 wie in `project.yml`
fuer Release und Archivierung festgelegt. Neue SwiftLint-Warnungen, Fehler und
eine veraltete Warnungsbaseline brechen den Build geschlossen ab.

Jeder Schritt ist Pflicht. Failure → kein Merge.
