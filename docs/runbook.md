# Runbook — Erste Schritte

## Voraussetzungen

```bash
brew install xcodegen swiftlint swiftformat
xcode-select --install   # falls nicht da
```

Apple Developer Account: noch nicht vorhanden (in dieser Session). Sobald da:
- Team-ID kopieren (Apple Developer → Membership → Team ID, 10-Zeichen).
- In `project.yml` unter `settings.base.DEVELOPMENT_TEAM` eintragen.

## Erster Build

```bash
cd healthlog-iOS

# Erzeuge .xcodeproj aus project.yml
xcodegen

# Open in Xcode
open HealthLog.xcodeproj
```

In Xcode:
1. Scheme `HealthLog` waehlen, Destination `iPhone 15 Pro Simulator`.
2. ⌘B Build. Erwartung: gruen (oder ein paar Force-Cast/Privacy-Manifest-Warnungen — keine Errors).
3. ⌘R Run. App startet im Simulator, zeigt Onboarding.

## API-Konfiguration

**Es gibt keinen Default-Server.** Die App bringt keine eingebaute Adresse mit; der Nutzer traegt im Onboarding (`ServerURLStep`) die Adresse seiner eigenen Instanz ein, die im Keychain landet. Bis dahin ist `AppEnvironment.baseURL` `nil` und Requests werfen `HLError.serverNotConfigured`.

Fuer einen lokalen Dev-Server ohne Onboarding-Durchlauf: `Info.plist` Schluessel `HLBaseURL` setzen (xcodegen-Override via `Debug.xcconfig`):

```
HLBaseURL = http://localhost:3000
```

## Cloudflare Access (falls aktiviert)

Slots vorhanden, default leer. Werte ueber `xcconfig.local`:

```
CFAccess.ClientID = <id>
CFAccess.ClientToken = <token>
```

## Cert-Pinning

In Production aktivieren:

> **Korrektur, 2026-08-25 (Legibility-Sweep, Phase 23).** Das unten beschriebene `HL_LOCAL_CONFIG`-Overlay ist **derzeit nicht verdrahtet**. Commit `04130697` (*"fix(release): keep distributed builds operator-neutral"*, 2026-08-12) hat den Block `include: { path: Config/local.yml, enable: ${HL_LOCAL_CONFIG} }` aus `project.yml` entfernt, zusammen mit dem automatischen Export im Release-Skript. `project.yml` enthaelt heute gar kein `include:` mehr — `HL_LOCAL_CONFIG=1 xcodegen` bewirkt also **nichts**, und `Config/local.yml` wird nie gelesen. Verteilte Builds sind damit per Konstruktion betreiberneutral. Fuer diese Korrektur wurde nichts neu verdrahtet: der Mechanismus wurde gemessen, nicht wiederhergestellt. Wer Pinning, Passkeys oder Universal Links im eigenen Build braucht, setzt die Info.plist-Schluessel selbst, die `CertificatePinner` liest.

1. SPKI-Hash extrahieren: `scripts/extract-spki.sh <dein-host>`
2. Output (base64) in `Config/local.yml` unter `HLPinnedSPKIHashes` eintragen (Vorlage: `Config/local.example.yml`, Datei ist gitignoriert).
3. Eigenen Host unter `HLPinnedHosts` eintragen — ohne Host greift das Pin-Set nie.
4. Backup-Pin fuer Cert-Rotation einrichten (mindestens zwei Pins).
5. `HL_LOCAL_CONFIG=1 xcodegen` — ohne die Variable ignoriert XcodeGen das Overlay.

Ohne Overlay = kein Pinning, System-Trust-Validierung. Das ist gueltig und crasht nicht; nur eine halbe Konfiguration crasht den Release-Build.

## Login-Flow

iOS-App nutzt **Bearer-Tokens** (Server-Side Bearer-Auth wurde in dieser Session ergaenzt — siehe `docs/server-changes.md`).

Der Token-Erwerb geht (Phase 1):
1. User loggt sich initial in der PWA ein → Cookie-Session.
2. PWA-Settings: "API-Token erstellen" → liefert `hlk_*` Token.
3. iOS-App: in den Settings den Token einfuegen → Keychain.

> **TODO Phase 1:** dedicated `/api/auth/exchange` Endpoint, der Email+Passwort gegen einen `hlk_*` Token tauscht — damit der iOS-Login-Flow End-to-End nativ funktioniert ohne Web-Detour. Optionaler Phase-1-Aufwand.

## Tests

```bash
# Unit-Tests
xcodebuild test \
  -project HealthLog.xcodeproj \
  -scheme HealthLog \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  CODE_SIGNING_REQUIRED=NO

# SPM-Core-Tests (ohne Xcode)
swift test
```

## Lint + Format

```bash
swiftformat --lint .
bash scripts/lint-strict-baseline.sh --self-test
bash scripts/lint-strict-baseline.sh
```

CI-Pipeline `.github/workflows/ci.yml` macht das automatisch bei Push.

## Server-Aenderungen deployen

Siehe [`docs/server-changes.md`](server-changes.md). Zusammenfassung:

```bash
cd HealthLog   # das Server-Repo
git diff   # Review
git add .  # alle 4 modifizierten + 8 neue Files
git commit -m "feat: Bearer-Auth + Server-PDF + OpenAPI-Spec"
git push   # Coolify deployt automatisch
```

## Troubleshooting

- **`xcodegen` schlaegt fehl:** `project.yml` hat YAML-Syntax-Error → `yamllint project.yml`.
- **HealthKit-Permissions kommen nicht:** Privacy-Strings in `project.yml` pruefen, dann `xcodegen` neu.
- **Passkey-Login schlaegt fehl:** der `webcredentials:`-Eintrag in `associated-domains` muss vom Server via `/.well-known/apple-app-site-association` bestaetigt werden — Server-Side-Setup noch ausstehend (Phase 1 P0).
