# Architektur

## Layering

```
┌─────────────────────────────────────┐
│  Views (SwiftUI)                    │  Stateless, beobachten Stores
├─────────────────────────────────────┤
│  Stores (@Observable)               │  ViewModel-equivalent, halten UI-State
├─────────────────────────────────────┤
│  Services (Actor)                   │  HealthKitService, APIClient, NotificationService
├─────────────────────────────────────┤
│  Repositories                       │  Cache + Network (SWR-Pattern)
├─────────────────────────────────────┤
│  Models (Codable, Sendable)         │  DTOs + Domain Types
└─────────────────────────────────────┘
```

Strict-Concurrency `complete`. Alle Modelle sind `Sendable`. Services sind Actors. Stores sind `@MainActor @Observable`.

## Daten-Strategie

**Server-first, kein Duplikat.**

- **Read:** SWR (stale-while-revalidate). Cache zeigen, im Hintergrund refreshen, View aktualisiert sich reactive.
- **Write:** optimistisch, mit Rollback bei Fehler. Bei Offline → Outbox-Queue (SwiftData), Replay beim naechsten App-Start oder Reachability-Wechsel.
- **Settings:** immer vom Server. Lokal nur Token, Last-Sync-Timestamps, UI-Praeferenzen die der Server nicht kennt.
- **HealthKit-Sync-Konfiguration:** lebt im Server, iOS spiegelt sie.

## HealthKit Anti-Duplikat

Bidirektional, aber kontrolliert:

- **Push (App → HK):** Beim Erfassen schreibt die App nach HK mit der Server-`measurement.id` als `HKMetadataKeyExternalUUID`.
- **Pull (HK → Server):** `HKObserverQuery` + `HKAnchoredObjectQuery`. Anchor pro Datentyp in Keychain. **Vor Upload:** Filter `sample.metadata?[HKMetadataKeyExternalUUID]` — wenn vorhanden + bekannt = von uns selbst, **skip**. Server hat zusaetzlich Idempotency-Key-Check.

## Networking-Layer

- `APIClient` Actor.
- Idempotency-Key (UUID) auf jedem POST/PUT, persistiert bis erfolgreich.
- Exponential Backoff mit Jitter bei 5xx + Network-Errors. Max 3 Retries.
- Reachability + Outbox-Queue.
- Request-Logging im Debug-Build, Sanitizer entfernt Token + PII.
- Certificate Pinning fuer Production (Public-Key-Pin).
- CF-Access-Header-Slots (`cf-access-client-id`/`cf-access-client-token`) optional, kommen aus Build-Config — Default leer (siehe ADR-003).

## Auth

- Passkey via `ASAuthorizationController` (Public-Key-Credentials, WebAuthn).
- Fallback: Email + Passwort.
- Token im Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- Re-Auth on 401.

## State

- `@Observable` (iOS 17 Observation framework), nicht `ObservableObject`.
- Keine Combine-Pipelines ausser wo Apple-APIs es erzwingen.

## Persistenz

- **SwiftData** fuer lokale Caches + Outbox.
- **Keychain** fuer Token, Server-URL, HK-Anchors.
- **UserDefaults** nur fuer non-secret UI-Prefs.

## Observability

- `Logger` aus `os.log`, Categories pro Subsystem.
- Keine PII oder Tokens in Logs.
- MetricKit fuer Crash + Hang-Reports, opt-in Server-Upload.

## Module Map (Build-Time)

`HealthLogCore` (SPM-Library, plattformfrei):
- Models, DTOs
- APIClient, KeychainStore, Logger, Reachability, IdempotencyKey, CertificatePinner
- Repositories
- Util

`HealthLog` (App-Target, iOS-only):
- App, DesignSystem, Screens, Stores
- HealthKitService, PasskeyService, NotificationService

Trennung erlaubt SPM-Build im CI ohne Xcode + faster Unit Tests fuer pure Logik.
