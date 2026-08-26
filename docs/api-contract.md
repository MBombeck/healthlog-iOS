# API-Contract

## Source-of-Truth

**OpenAPI-Spec im Server-Repo:** `docs/api/openapi.yaml` im Server-Repo

Die iOS-App referenziert die Spec. Drift-Schutz:

- Bei jedem Backend-Release validiert der Server-CI die Spec gegen die tatsaechlichen Routen.
- iOS-CI laedt die Spec aus dem Server-Repo (oder einem gepflegten Mirror) und fuehrt einen DTO-Diff gegen `HealthLog/Models/DTO/*.swift` durch — Drift bricht den Build.

> **TODO Phase 1:** DTO-Codegen via [openapi-generator](https://openapi-generator.tech/) oder [swift-openapi-generator](https://github.com/apple/swift-openapi-generator) verdrahten. Manuelle DTOs sind Zwischenstand.

## Authentifizierung

- **Bearer Token** im `Authorization`-Header.
- Token via Passkey-Login oder Email+Passwort erworben.
- Persistiert im Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- Re-Auth on `401`.

### Auth-endpoint exemption from the 401→refresh bridge

`APIClient.execute` honours a one-shot 401→refresh-and-retry bridge for every
authenticated route (`docs/security.md` + `17-error-handling.md §9`). The
following path prefixes are **explicitly exempt** from that bridge — they are
themselves part of the refresh-token flow, so 401 responses from them must
surface directly (`HLError.unauthorized`) instead of recursing back through the
refresh handler:

| Path prefix                  | Reason |
|------------------------------|--------|
| `/api/auth/login`            | Username/password login (`Invalid credentials` is terminal). |
| `/api/auth/refresh`          | Refresh-token rotation — recursion would loop. |
| `/api/auth/logout`           | Logout target; the user is already past the auth boundary. |
| `/api/auth/passkey/`         | WebAuthn challenge / register / verify — all part of the same handshake. |
| `/api/auth/register`         | New-account flow — 401 indicates a server-side policy refusal, not a token-rotation opportunity. |

**Contract for new auth routes:** Any new path under `/api/auth/...` that
participates in token acquisition / rotation MUST be added to
`APIClient.isAuthExempt(path:)` in the same change-set that introduces the
route on the server. The drift-test
`HealthLogTests/RefreshExemptionTest.swift` enumerates the active prefixes
and parameterises over the full route table — adding a new auth route without
updating the exemption list (or the test) will fail the build.

## Cloudflare Access

Optional. Slots im APIClient, default leer:
- `cf-access-client-id`
- `cf-access-client-token`

Werte kommen ueber `xcconfig` (Debug + Release Schemes), niemals hardcoded.

## Idempotency

Jeder `POST` / `PUT` traegt:
- `Idempotency-Key: <uuid>` (persistiert bis 2xx-Response oder permanenter Fehler)

Server haelt eine Idempotency-Map (24h TTL).

## Retries

- 5xx + Network-Errors: Exponential Backoff (Base 250ms, Cap 5s, Jitter ±20%), max 3 Retries.
- 4xx (ausser 408, 429): kein Retry.
- 429: Respect `Retry-After`-Header.

## Envelope

```json
{ "data": {...}, "error": null }
{ "data": null, "error": { "code": "...", "message": "..." } }
```

## Endpunkt-Inventar (iOS-relevant)

Vollstaendig in der OpenAPI-Spec. Hier nur die fuer P0/P1-Phasen kritischen Endpunkte:

| Domain | Methode | Path | Phase |
|--------|---------|------|-------|
| Auth | POST | `/api/auth/passkey/login-options` | 1 |
| Auth | POST | `/api/auth/passkey/login-verify` | 1 |
| Auth | POST | `/api/tokens` | 1 |
| Onboarding | GET/PATCH | `/api/onboarding` | 3 |
| HealthKit | GET/PATCH | `/api/integrations/healthkit` (TBD) | 3 |
| Dashboard | GET | `/api/dashboard/summary` | 4 |
| Measurements | GET/POST | `/api/measurements` | 5 |
| Measurements | GET | `/api/measurements/series` | 6 |
| Medications | GET | `/api/medications` | 5 |
| Medications | POST | `/api/medications/intake` | 5 |
| Mood | GET/POST | `/api/mood` | 5 |
| Insights | GET | `/api/insights/comprehensive` | 6 |
| Achievements | GET | `/api/gamification/achievements` | 6 |
| User | GET/PATCH | `/api/user/profile` | 7 |
| Settings | GET/PATCH | `/api/settings` | 7 |
| Doctor Report | POST | `/api/doctor-report` (JSON) | 7 |
| Doctor Report | POST | `/api/doctor-report/pdf` (PDF, server-rendered) | 7 |
| Devices | POST | `/api/devices` (TBD Phase 8) | 8 |
| Notifications | GET/PATCH | `/api/notifications/preferences` (channels + per-event toggles) | 8 |
| Notifications | GET/PATCH | `/api/auth/me/notification-prefs` (`mood.reminderHour` + `medication.clientManaged`) | 8 |

## Environments

| Env | Base-URL |
|-----|----------|
| Production | die im Onboarding eingetragene eigene Instanz (kein eingebauter Default) |
| Staging | tbd |
| Local | `http://localhost:3000` (Debug-Scheme only) |
