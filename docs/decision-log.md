# Decision Log

Architecture Decision Records. Format: ADR-NNN.

---

## ADR-001: Toolchain — SwiftUI / SPM / XcodeGen

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** Need a reproducible iOS toolchain ohne `.xcodeproj` im Git, mit minimalen Dependencies.
- **Optionen:**
  - (A) Klassisches Xcode-Projekt, `.xcodeproj` committed → Merge-Konflikte, viele unsichtbare Settings.
  - (B) Swift Package Manager nur → klappt nicht fuer App-Target mit Entitlements / Resources / Multi-Target.
  - (C) Tuist → maechtig, aber zusaetzliche DSL und Toolchain-Pflege.
  - (D) **XcodeGen** + SPM-Manifest fuer Plattform-unabhaengigen Core.
- **Entscheidung:** (D). Klein, deklarativ in YAML, Standard im iOS-Oekosystem, generiert reproduzierbare `.xcodeproj`. SPM-Manifest deckt Pure-Logic-Tests im CI ohne Xcode.
- **Konsequenzen:**
  - `.xcodeproj` ist gitignored.
  - Setup-Schritt `brew install xcodegen && xcodegen` vor erstem Build.
  - Code-Strukturierung muss SPM-Target-Boundaries respektieren (Models/Services/Repos = SPM, UI/HK/Passkey = App-Target).

---

## ADR-002: Doctor Report — Server-rendered PDF

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** Die PWA rendert PDFs client-side via `jspdf`. iOS koennte denselben Weg gehen (PDFKit) oder vom Server ein fertiges PDF holen.
- **Optionen:**
  - (A) PDFKit clientseitig — Layout 1:1 nachbauen, doppelte Pflege, Drift-Risiko.
  - (B) **Server-rendered PDF** ueber neuen Endpoint `/api/doctor-report/pdf`. iOS lädt + teilt nur.
- **Entscheidung:** (B). Eine Layout-Quelle, garantierte Konsistenz mit der PWA, keine `jspdf`-Pflege im iOS-Code.
- **Konsequenzen:**
  - Server-Implementierung notwendig (parallel im HealthLog-Repo gebaut).
  - iOS-Code: einfacher Download + `UIActivityViewController` zum Teilen.
  - Performance-Hit auf dem Server (jspdf in Node, nicht trivial). Acceptable bei 10/h Rate-Limit.

---

## ADR-003: Cloudflare Access Header-Slots — optional, Build-Config-driven

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** Die HealthLog-API ist aktuell **nicht** durch Cloudflare Access geschuetzt — Auth ist Bearer-Token. Das kann sich aendern.
- **Optionen:**
  - (A) Header-Slots erst einbauen, wenn benoetigt → App-Update beim Wechsel.
  - (B) **Header-Slots immer mitliefern**, default leer, befuellbar via xcconfig — App-Update vermeidbar.
- **Entscheidung:** (B). Praeventive Resilienz mit minimalem Aufwand.
- **Konsequenzen:**
  - `APIClient` liest `cf-access-client-id` und `cf-access-client-token` aus `Bundle.main.infoDictionary["CFAccess"]`.
  - Standard-Werte leer; nur bei Aktivierung werden Header gesetzt.
  - xcconfig-Variante: `CF_ACCESS_CLIENT_ID` und `CF_ACCESS_CLIENT_TOKEN`, default `""`.

---

## ADR-004: Concurrency — Swift Concurrency strict, kein Combine

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** iOS 17+ erlaubt `SWIFT_STRICT_CONCURRENCY=complete`. Combine ist Legacy fuer reaktive Pipelines.
- **Entscheidung:** Nur `async/await`, `actor`, `@MainActor`, `@Observable`. Combine nur wenn Apple-API es erzwingt.
- **Konsequenzen:**
  - Stores sind `@MainActor @Observable`-Klassen.
  - Services sind Actors.
  - Modelle sind `Sendable`.
  - Alle Asynchronizitaet via Tasks, keine `assign(to:)`-Pipelines.

---

## ADR-005: Persistenz — SwiftData fuer Caches + Outbox

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** Lokale Caches und Outbox-Queue brauchen schnelle, getypte Persistenz.
- **Optionen:** Core Data, SwiftData, GRDB, simple JSON-Files, SQLite.swift.
- **Entscheidung:** **SwiftData**. Apple-First-Party, native fuer iOS 17+, type-safe via `@Model`, integriert mit `@Observable`.
- **Konsequenzen:**
  - Cache-Modelle (`MeasurementCache`, `MedicationCache`, `OutboxOperation`) sind `@Model`.
  - InMemory-`ModelContainer` fuer Tests.
  - Migration via `MigrationPlan` ab erstem Schema-Bump.

---

## ADR-006: Bundle-ID `dev.healthlog.app`

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** App-ID-Wahl bestimmt Keychain-Group, Provisioning, Universal Links.
- **Entscheidung:** `dev.healthlog.app`. Reverse-DNS der `healthlog.dev`-Domain (User besitzt diese, hostet `healthlog-landing`).
- **Konsequenzen:**
  - Keychain-Group: `$(AppIdentifierPrefix)dev.healthlog.app`.
  - Universal Links: `webcredentials:` + `applinks:` auf den Managed-Host (Live-PWA).
  - Apple Developer Team-ID (noch nicht vorhanden) wird vor erstem Device-Build in `project.yml` ergaenzt.

---

## ADR-007: Testing-Stack — Swift Testing primary, XCTest fuer UI

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** Swift Testing ist seit Swift 6/Xcode 16 der neue Standard, XCTest bleibt fuer UI-Tests + perf-`measure`-Bloecke.
- **Entscheidung:** Neuer Code in Swift Testing (`@Test`, `#expect`). UI-Tests in XCTest. Snapshot-Tests in XCTest (Library-Constraint).
- **Konsequenzen:**
  - Test-Target laedt beide Frameworks.
  - Unit-Tests sind kompakter und parallel-fest.

---

## ADR-008: HealthKit Anti-Duplikat — ExternalUUID + Source-Filter

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** Bidirektionale Sync zwischen HK und Server kann Duplikate erzeugen.
- **Entscheidung:**
  - Push (App→HK): Sample wird mit `HKMetadataKeyExternalUUID = server-measurement-id` getaggt.
  - Pull (HK→Server): Skip wenn `metadata[ExternalUUID]` vorhanden + bekannt.
  - Server hat Idempotency-Key-Check als Defense-in-Depth.
- **Konsequenzen:**
  - HKAnchoredObjectQuery-Anchor pro Datentyp persistiert in Keychain.
  - Pro Sync-Run wird das Anchor-Delta geprueft; Re-Push verhindert.
  - Test: 24h-Lauf 0 Doppel-Samples auf physischem Geraet (DoD).

---

---

## ADR-009: SPKI-Pinning via TrustKit-Pattern

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** Erste Implementierung hashte den von `SecKeyCopyExternalRepresentation` gelieferten Raw-Public-Key, was nie zum Hash aus `openssl x509 -pubkey | openssl pkey -outform DER | sha256` passt — Production wuerde mit Pinning den Server abweisen.
- **Optionen:**
  - (A) Volle ASN.1-Parser-Implementation (cert DER → SPKI-Substruktur).
  - (B) `SecCertificateCopyData` + manueller Offset-basierter Extract.
  - (C) **TrustKit-Pattern**: bekannten ASN.1-Header pro Key-Type prependen.
- **Entscheidung:** (C). Klein, deterministisch, gleicher Output wie openssl.
- **Konsequenzen:**
  - Pin-Lookup-Tabelle muss neue Key-Shapes (z. B. ECDSA-P521, RSA-3072) bei Rotation erweitert werden.
  - Lookup-Tabelle in `Services/CertificatePinner.swift` `SPKIHeader.lookup`.
  - Bei unbekannter Kombination → `validate` returned false → connection denied. Acceptable Fail-Closed.

---

## ADR-010: 401-Handler-Bridge via UnauthorizedHandlerRef

- **Datum:** 2026-05-03
- **Status:** Accepted
- **Kontext:** APIClient muss bei 401 die UI-Schicht (AuthStore) informieren, wird aber initialisiert *bevor* AuthStore existiert. Init-Order kann nicht umgekehrt werden, weil AuthStore die APIClient-Reference braucht.
- **Optionen:**
  - (A) AuthStore vor APIClient initialisieren, APIClient ueber Setter nachreichen → Mutable Reference, Mehrfach-Init-Risiko.
  - (B) **Sendable-Box-Pattern**: `UnauthorizedHandlerRef` mit thread-safer `set/invoke`. APIClient haelt die Box, AuthStore wird im Init-Tail in die Box gesetzt.
  - (C) Notification-Center-Broadcast → loose coupling, aber nicht typed.
- **Entscheidung:** (B). Sauber typed, init-deterministisch, kein Mutable-State-Leak.
- **Konsequenzen:**
  - `AppContainer` haelt private `unauthorizedRef`. Nicht extern exposed.
  - Test-Hook: `unauthorizedRef.set(_:)` ist intern, in Tests via Reflection oder durch Composition auf einen separaten APIClient zugreifbar.

---

## ADR-011: Outbox-to-SwiftData migration drops in-flight ops on first A5 launch

- **Datum:** 2026-05-15
- **Status:** Accepted
- **Kontext:** Audit-v021 C-2 — die in-memory `OutboxQueue` verliert
  Operationen beim App-Kill. SwiftData-Migration soll persistieren, aber
  pre-A5-Operationen leben nur im RAM und sind beim A5-Update
  unrettbar.
- **Optionen:**
  - (A) Auf `applicationWillTerminate` die alte Queue serialisieren und
    beim ersten A5-Start einlesen. Fehleranfaellig (will-terminate ist
    nicht garantiert), Bootstrapping-Race in `AppContainer.init`,
    Migrations-Code muss eine ganze Release zurueck unterstuetzt werden.
  - (B) Akzeptieren, dass pre-A5-Operationen einmalig verloren gehen —
    gleiches Verhalten wie heute jeder App-Kill — und keine
    Migrations-Logik schreiben.
- **Entscheidung:** (B). Risiko-Nutzen-Verhaeltnis ist eindeutig, der Fall
  ist fresh-install-equivalent. Pre-A5 hatten User keine
  Persistenz-Erwartung; ein einmaliger Drop beim Upgrade ist nicht
  schlechter als das, was sie ohnehin schon hatten.
- **Konsequenzen:**
  - Release-Notes von v0.3.0 erwaehnen den einmaligen Verlust fuer
    Power-User mit gequeuten Offline-Eintraegen — UI-mässig nicht
    sichtbar.
  - Ab A5: `OutboxOperation`-Rows ueberleben App-Kill, Reboot, OS-Update.
    Replay laeuft cold-boot-getriggered via Reachability-Stream
    (`currentlyOnline = true` bei Subscribe → `runOnce()` feuert).
  - PROJECT_GUIDE.md "Idempotency-Keys: Ueberlebt App-Restarts" ist jetzt
    faktisch korrekt statt aspirational.

---

## ADR-012: Outbox-File-Protection auf completeUntilFirstUserAuthentication

- **Datum:** 2026-05-15
- **Status:** Accepted
- **Kontext:** Der SwiftData-Outbox-Store (siehe ADR-011) liegt unter
  `Library/Application Support/HealthLog/Outbox/outbox.sqlite`. iOS
  unterstuetzt vier Data-Protection-Klassen
  (`FileProtectionType.complete`, `…UntilFirstUserAuthentication`,
  `…WhenUserInactive`, `none`). Die Outbox enthaelt encoded JSON-Payloads
  fuer Measurements / MoodEntries / MedicationIntakes — also Health-Daten
  in nicht-encrypted Form auf Disk-Filesystem.
  - `BGProcessingTask dev.healthlog.app.healthkit-sync` weckt die App
    waehrend das Geraet locked sein kann. `.complete` wuerde den
    SQLite-Store dann unleserlich machen → BG-Sync laeuft im falschen
    Moment ins Leere.
  - `.completeUntilFirstUserAuthentication` matcht die Semantik von
    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (was wir fuer den
    Bearer-Token im Keychain bereits nutzen): nach Reboot bis zum ersten
    User-Unlock unleserlich, danach leerlaufzeit-tolerant.
- **Entscheidung:** `completeUntilFirstUserAuthentication`, applied via
  `FileManager.setAttributes` post-first-save auf
  `outbox.sqlite + -shm + -wal`.
- **Konsequenzen:**
  - Outbox-Inhalt ist nach Reboot bis zum ersten Unlock unzugaenglich;
    danach lesbar fuer alle Background-Wakeups. Symmetrisch mit der
    Token-Speicherung.
  - Wenn der User das Geraet kurz nach dem Reboot in einen
    BGProcessingTask-Wakeup geraten laesst (vor dem ersten Unlock),
    schluckt der Wakeup einen Outbox-Replay — `runOnce()` faellt durch
    weil der Store nicht lesbar ist. Naechster App-Foreground oder
    naechster BG-Wakeup nach Unlock holt es nach.
  - Der Helper im `OutboxStore` ist best-effort: wenn die Datei beim
    ersten Aufruf noch nicht existiert (SwiftData laed't lazy beim
    ersten Save), skipt der Helper und wird beim Folge-Aufruf erfolgreich
    durchlaufen.

---

## ADR-013: Coach-Chat-Verlauf nicht ueber iOS-Sandbox hinaus verschluesseln

- **Datum:** 2026-05-22
- **Status:** Accepted
- **Kontext (B3-M4 / Wave-B Security):** Der `CoachConversationStore` persistiert den Ask-Coach-Chatverlauf via SwiftData (`CoachChatStore`, partition-keyed auf `userIDProvider()`). Die SwiftData-Datei liegt im App-Sandbox-Container unter `Library/Application Support/.../coach-chat.sqlite`. Diskussion: muessen wir den Inhalt zusaetzlich mit CryptoKit at-rest verschluesseln?
  - Threat-Model 1 — Diebstahl + kein Passcode: iOS-Filesystem ist unverschluesselt → SQLite-File ist mit `strings(1)` lesbar. Aber: in dem Modell ist ALLES kompromittiert (Tokens im Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` setzt mindestens Passcode voraus; Health-Daten in der Health-App genauso). Ein Passcode-loses Geraet ist auch sonst nicht schuetzbar — Apple-Threat-Model.
  - Threat-Model 2 — Diebstahl + Passcode + Biometrie: Data Protection-Klasse `NSFileProtectionCompleteUntilFirstUserAuthentication` greift (SwiftData-Default). Match zum Mail-/Messages-Verhalten von Apple selbst. Vor dem ersten Unlock unleserlich; danach bis zum naechsten Reboot lesbar fuer App-Prozesse.
  - Threat-Model 3 — Jailbreak + Forensik mit App-Process-Hooking: Wenn die App laeuft, ist der Decryption-Key materialisiert. Ein at-rest-Encrypt-Layer mit Key-im-Keychain hebt die Schwelle nicht — der Angreifer kann den Key beim naechsten App-Foreground mitlesen.
- **Optionen:**
  - (A) **Status quo** — auf SwiftData-Default + iOS Data Protection vertrauen. Symmetrisch zur Tokens-Strategie + zur Mail-/Messages-Lib.
  - (B) Keychain als Storage. Nicht skalierbar — Keychain ist nicht fuer Chat-Verlauf-Volumen designed (kSec-Items haben Soft-Limits + sind nicht JOIN-bar).
  - (C) CryptoKit-`AES.GCM` Layer ueber den persistierten SwiftData-Rows mit Key im Keychain. Plus: theoretisch schuetzt es vor dem File-Read-Vektor im Threat-Model 2 NACH-Unlock. Minus: Komplexitaet (Key-Rotation? Multi-Device-Sync? Key-Loss = Verlust-aller-Chats?), Performance (Per-Row-Decrypt bei jedem SwiftUI-Repaint), und der Threat-Model-3-Angreifer extrahiert den Schluessel ohnehin aus dem In-Memory-Prozess.
- **Entscheidung:** (A). Wir lassen den SwiftData-Default plus iOS-Sandbox-Schutz stehen, ergaenzen das `clearOnLogout`-Wipe via `AppContainer+Logout.wipeCoachChatOnLogout()` (bereits eingebaut) und dokumentieren die Begruendung hier.
- **Konsequenzen:**
  - Coach-Chat-Verlauf ist genauso geschuetzt wie Mail/Messages — `NSFileProtectionCompleteUntilFirstUserAuthentication`. Klasse C im NIST-Sinn (First-Unlock).
  - Logout/401/Account-Delete sweep den Verlauf ohne neue Keys.
  - Wenn sich das Threat-Model aendert (shared-Geraete in Klinik, regulatorische Anforderung wie z. B. HIPAA-`Encryption-at-Rest`-Audit, BYOD-Compliance), revisit. Konkreter Trigger: User-Profiles in einer App-Instanz (Multi-Tenant) oder Klinik-iPad-Sharing-Mode.
  - Cross-Reference: `HealthLog/Services/AI/CoachConversationStore.swift` (Doc-Header), `HealthLog/Stores/AppContainer+Logout.swift::wipeCoachChatOnLogout`.

---

## ADR-014: v0.8.5 Fix-Wave — Reorder-Hoehe, Live-Activity-Design, Per-Med-Opt-in
- **Datum:** 2026-05-30
- **Status:** Accepted
- **Kontext:** Operator-Feedback nach v0.8.4 (Real-Device): (1) Dashboard-Kacheln komplett unsichtbar; (2) Live Activity in fremdem "Dracula"-Look statt unserem dokumentierten Design-System; (3) Live Activity global fuer jedes Medikament statt opt-in fuer zeitkritische; (4) der "⋯"-Bearbeiten-Knopf dauerhaft sichtbar (Platzkosten).
- **Entscheidungen:**
  - **(1) Reorder-Grid-Hoehe — observed-height statt `sizeThatFits`.** Die v0.8.4-`ReorderableTileCollection` (UICollectionView + `UIHostingConfiguration`) meldete ihre Hoehe via `UIViewRepresentable.sizeThatFits` → `intrinsicContentSize`. SwiftUI re-queried `sizeThatFits` nach `invalidateIntrinsicContentSize` NIE, und die Erstmessung lief gegen 0-Hoehe-Bounds, wo Self-Sizing-Cells nicht aufloesen → Hoehe 0 → Grid kollabiert, alle Kacheln weg. **Fix:** kanonisches observed-height-Pattern — der Coordinator misst gegen reale (hohe) Probe-Bounds und schreibt die gesettelte `contentSize.height` in ein SwiftUI-`@State`, das als explizites `.frame(height:)` angewandt wird. `@State`-Write erzwingt SwiftUI-Re-Layout. Greift fuer Dashboard- UND Insights-Ziele-Grid (gemischte Spans). Regression-Tests: `ReorderableTileCollectionHeightTests` (Hoehe > 0, item-proportional).
  - **(2) Live-Activity-/Widget-Design = Tonal-Mono-Doctrine (kein Dracula).** Die Extension kann die Asset-Catalog-Farben der App nicht aufloesen (eigener Bundle, kein Asset-Katalog), darum die fruehere extension-lokale Dracula-Palette (`#BD93F9` Purpur, `#282A36` BG). Ersetzt durch `HealthLog/DesignSystem/LiveActivityTokens.swift` (Source-Membership in App + Widget): code-level dynamische Light/Dark-Farben, die die dokumentierten Tonal-Mono-Tokens 1:1 aus `Tokens.swift` replizieren. **Regel:** Widget/Live-Activity-Chrome ist monochrom (Accent = Primary-Text, kein Hue); Farbe nur als Status-Signal (`statusOK`/`statusWarn`). Gilt fortan fuer jede neue Widget-Surface.
  - **(3) Per-Medikament Live-Activity opt-in.** Server-Contract hat (noch) kein `liveActivityEnabled`-Feld (gegen `Medication.swift`/`MedicationsRepository` verifiziert). Loesung: lokaler `LiveActivityPreferences`-Store (UserDefaults, keyed auf Medication-Id), **Default AUS**; reine `isLiveActivityEnabled`-Predicate in `MedicationLiveActivityPlan.doseToSurface` gefaedelt, sodass nur opt-in-Meds eine Activity starten. Toggle in `EditMedicationSheet`. **Server-Follow-up SB-LA-1:** Feld serverseitig nachziehen, dann auf server-first migrieren (lokaler Store wird Fallback/Cache).
  - **(4) "⋯"-Edit-Menue nur im Wackel-/Edit-Mode.** Add-Tiles + Anordnen sind hinter einem einzigen "⋯"-Menue zusammengefasst, das NUR im Edit-Mode erscheint (Einstieg: Long-Press auf eine Kachel; Ausstieg: Done-Pille). Nicht-Edit-Ansicht bleibt frei von Top-Trailing-Chrome.
- **Konsequenzen:**
  - Kacheln koennen strukturell nicht mehr unsichtbar werden; Reorder-Verhalten (Lift/Drop/Halb-Voll/Wackeln/Tap) unveraendert.
  - Live Activity + Widgets sind design-konsistent mit der App in Light & Dark; `LiveActivityTokens` ist die single source fuer extension-seitige Farben.
  - Bestehende Meds zeigen KEINE Live Activity, bis der Operator sie pro Med aktiviert (gewollt: nur zeitkritische).
  - Cross-Reference: `ReorderableTileCollection.swift`, `ReorderableCollectionCoordinator.swift`, `LiveActivityTokens.swift`, `LiveActivityPreferences.swift`, `MedicationLiveActivityPlan.swift`, `EditMedicationSheet.swift`, `DashboardScreen.swift`, `InsightsScreen.swift`.

---

## ADR-015: v0.10.0 — Server-co-evolution, mood client-compute, standalone deferred
- Datum: 2026-05-31
- Status: Accepted
- Kontext: v0.10.0 lief parallel zum Server-v1.7.0-Zyklus (eigenes Repo/Team). Koordination über die geteilte Austauschplattform `.planning/ios-coord/`. Zusätzlich Operator-Wunsch nach Mood-Ausbau + die Frage nach server-losem Standalone.
- Entscheidungen:
  - **(1) Forward-compatible field-presence gating statt Server-Tag-Blockade.** iOS konsumiert den v1.7.0-Contract (`scheduleType`/`asNeeded`/`cycleWeeks*`, `nextDueAt`, cadence-canonical Compliance `due`/`expectedCount`, `liveActivityEnabled`/`criticalAlarmEnabled`) über Feld-Präsenz-Gates: korrekt gegen den alten UND den neuen Server, ohne zweites Release. Nach Server-Live Pin-Cleanup in W10 (`scheduleType` als Diskriminator, Widget-Workarounds entfernt).
  - **(2) Medication-Recurrence-Engine als pure-Swift Server-Spiegel.** Port der Server-`recurrence.ts` 1:1 (27 Test-Vektoren verbatim) inkl. Rolling-State-Machine. `nextDueAt` wird konsumiert wenn vorhanden, sonst lokale Engine — beseitigt Zwei-Engine-Parity-Risiko live.
  - **(3) Mood-Insights client-computed (offline-first).** Heatmap/Stabilität/Tag-Deltas/Korrelations-Detektoren rechnen on-device aus der Entry-Liste (Port von MoodLog `statistics-compute.ts`); `/api/mood/analytics` nur Anreicherung. Erfassen unangetastet. Apple-Health-State-of-Mind-Sync bidirektional hinter Toggle (off default), kein Server-Work.
  - **(4) Standalone/server-los → v0.11-Milestone, nicht v0.10.** Audit (`R-Standalone-serverless-audit.md`): blockiert durch Release-Onboarding-Server-Zwang, fehlende lokale SwiftData-Source-of-Truth (offline-Writes verschwinden), ~9 server-derived Surfaces ohne Pair-Platzhalter. W-Sync **right-sized** auf Groundwork (`BackendAvailability` + 401-Cascade-Gating + `HLCloudDerivedPlaceholder`); voller `/api/sync/changes`-Consumer + lokale Daten-Schicht = v0.11.
  - **(5) Monochrom-Doktrin verschärft.** Mood/Insights/LiveActivity/Onboarding voll monochrom (Heatmap single-hue, ≤2 Glass-Surfaces, +/- via Glyph+Gewicht statt Rot/Grün). Onboarding-BrandMark wurde monochrom (Abweichung von Handbook §7 — Operator-Entscheidung offen).
- Konsequenzen:
  - v0.10.0 shippt grün gegen aktuellen UND v1.7.0-Server; Features schalten sich am Feld auto-scharf.
  - v0.11-Roadmap: `.planning/v0110-marathon/v0.11-BACKLOG.md` + `v0.11-standalone-technical-spec.md` (Routen-Inventar, On-device-vs-Disable-Matrix, lokale Daten/Auth-Schicht).
  - Server-Koordination: `.planning/ios-coord/` stehender bidirektionaler Kanal; finales Handover `v1.7.0-ios-to-server-FINAL-handover.md`.

---

## ADR-Template

```
## ADR-NNN: <Titel>
- Datum: YYYY-MM-DD
- Status: Proposed | Accepted | Superseded
- Kontext: ...
- Optionen: ...
- Entscheidung: ...
- Konsequenzen: ...
```
