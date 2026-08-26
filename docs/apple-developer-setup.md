# Apple Developer Setup — HealthLog iOS

Schritt-fuer-Schritt-Guide vom Apple Developer Account zur ersten TestFlight-Auslieferung.
Stand: 2026-05-14. Voraussetzung: aktiver Apple Developer Program Account ($99/Jahr).

## 1. Team-ID raussuchen (5 min)

1. https://developer.apple.com/account einloggen
2. Linke Sidebar → **Membership Details**
3. Eintrag **Team ID** kopieren — 10-stelliger alphanumerischer Code (z.B. `A1B2C3D4E5`)
4. In `project.yml` eintragen:
   ```yaml
   settings:
     base:
       DEVELOPMENT_TEAM: "A1B2C3D4E5"
   ```
5. `xcodegen` neu laufen lassen — `.xcodeproj` regeneriert sich mit dem Team

## 2. App ID / Bundle Identifier registrieren (10 min)

1. https://developer.apple.com/account → **Certificates, Identifiers & Profiles** → **Identifiers**
2. **+** Button → **App IDs** → **App** → Continue
3. Form ausfuellen:
   - **Description**: `HealthLog`
   - **Bundle ID**: **Explicit** → `dev.healthlog.app` (genau wie in `project.yml` `PRODUCT_BUNDLE_IDENTIFIER`)
4. **Capabilities** anhaken (kritisch — diese bestimmen, welche Entitlements das Provisioning Profile signiert):
   - ☑ **HealthKit**
     - ☑ **HealthKit Background Delivery** (sub-capability — ohne diese funktioniert Background-Sync NICHT in Production)
   - ☑ **Push Notifications** (auch wenn Phase 8 — gleich anhaken, App-ID-Edits sind nervig)
   - ☑ **Sign In with Apple** (fuer Passkey-Faellback wenn benoetigt)
   - ☑ **Background Modes** (kommt aus `UIBackgroundModes` in Info.plist, kein expliziter Capability-Toggle hier)
   - ☐ Keychain Sharing — wir nutzen kein Cross-App-Sharing, nur App-spezifische Group
   - ☐ App Groups — erst noetig wenn Widget-Extension HK liest (Phase 8)
   - ☐ Associated Domains — erst noetig fuer Universal Links / WebAuthn-RP-Verification (spaeter)
5. **Continue** → **Register**

## 3. Provisioning Profile (automatisch via Xcode)

In `project.yml` ist `CODE_SIGN_STYLE: Automatic` gesetzt. Xcode managed Provisioning Profiles selbst, sobald:
- Team-ID korrekt
- App-ID + Capabilities online registriert (Schritt 2)
- iPhone fuer Development registriert (siehe Schritt 4)

Manuell pflegen ist nur noetig wenn CI signed (CI-Cert + Profile in Repo-Secrets) — fuer Solo-Dev erstmal nicht relevant.

## 4. Test-iPhone registrieren (5 min, einmalig pro Geraet)

1. iPhone via Kabel an Mac
2. Xcode → **Window → Devices and Simulators** → iPhone auswaehlen → **Use for Development**
3. Apple-ID einloggen → "Trust This Computer" am iPhone bestaetigen
4. Xcode registriert das Geraet automatisch in der Account-UDID-Liste

## 5. Erster Build aufs iPhone

```bash
cd healthlog-iOS
xcodegen   # falls project.yml geaendert wurde
open HealthLog.xcodeproj
```

In Xcode: Scheme **HealthLog** → Destination **dein iPhone** → ⌘R.

Beim ersten HealthKit-Permission-Prompt: **alle** angefragten Datentypen erlauben (sonst springen Tests fuer Background-Delivery falsch).

## 6. App Store Connect — App registrieren (15 min)

Sobald iPhone-Build laeuft + du TestFlight willst:

1. https://appstoreconnect.apple.com → **My Apps** → **+** → **New App**
2. Form:
   - **Platform**: iOS
   - **Name**: `HealthLog` (Display-Name im Store, max 30 Zeichen)
   - **Primary Language**: German (Germany)
   - **Bundle ID**: `dev.healthlog.app` (Dropdown — hier muss Schritt 2 abgeschlossen sein)
   - **SKU**: `healthlog-ios` (interner Identifier, frei waehlbar)
   - **User Access**: Full Access (Solo-Dev)
3. **Create**

## 7. App Privacy (kritisch fuer Health-Apps — sonst Rejection)

Nach App-Erstellung: linke Sidebar → **App Privacy** → **Get Started**

Apple verlangt vollstaendige Deklaration aller gesammelten Datentypen. Fuer HealthLog mindestens:

| Data Type | Linked to User | Used for Tracking | Purpose |
|---|---|---|---|
| **Health & Fitness → Health** | Yes | No | App Functionality |
| **Health & Fitness → Fitness** | Yes | No | App Functionality |
| **Identifiers → User ID** | Yes | No | App Functionality, Authentication |
| **Diagnostics → Crash Data** (falls MetricKit-Upload aktiv) | No | No | App Functionality |
| **Diagnostics → Performance Data** (falls MetricKit) | No | No | App Functionality |

**Tracking**: NEIN. Wir tracken nicht, wir teilen nicht mit Brokern, kein SDK macht's. Die Privacy-Nutrition-Labels muessen exakt das wiederspiegeln was im `PrivacyInfo.xcprivacy` steht — sonst wird's beim Review gerueckgewiesen.

## 8. TestFlight-Build hochladen

```bash
# In Xcode: Product → Archive
# Window → Organizer → neuestes Archive → Distribute App
#   → App Store Connect → Upload → Next-Next-Done
```

Alternative ohne Xcode-IDE (CI-Pattern):

```bash
xcodebuild -project HealthLog.xcodeproj \
  -scheme HealthLog \
  -archivePath build/HealthLog.xcarchive \
  -destination 'generic/platform=iOS' \
  archive

xcodebuild -exportArchive \
  -archivePath build/HealthLog.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist scripts/ExportOptions-AppStore.plist

xcrun altool --upload-app -t ios -f build/ipa/HealthLog.ipa \
  -u "$ASC_USER" -p "$ASC_APP_PASSWORD"
```

(`scripts/ExportOptions-AppStore.plist` hat `method = app-store`, `signingStyle = automatic`, dein Team-ID.)

## 9. TestFlight Internal Testing (sofort nutzbar)

1. App Store Connect → **TestFlight** Tab → Build erscheint nach Upload + Processing (~5-15 min)
2. Build hat zunaechst **Missing Compliance** Status (Encryption-Disclaimer):
   - Build → "Manage" → "Does your app use encryption?" → bei `ITSAppUsesNonExemptEncryption: false` (in Info.plist gesetzt) wird's automatisch gehandhabt → **Compliant**
3. **Internal Testing** Group erstellen → Tester (du selbst, evtl. Familie/Freunde mit Apple-IDs) hinzufuegen
4. Build der Group zuweisen → Tester bekommen TestFlight-Push, App per **TestFlight**-iPhone-App installierbar

Internal Testing braucht **kein** Beta App Review.

## 10. TestFlight External + spaeter App Store Submission

External Testing Groups (>100 Tester moeglich) brauchen einen einmaligen **Beta App Review** (Apple prueft 24-48h). Health-Apps haben hier folgende typische Stolperfallen:

- **Demo-Account / Demo-Mode**: Apple Reviewer brauchen Login. Dein App-Auth ist Server-basiert + Passkey — biete im Review-Notes einen Demo-Account oder Demo-Mode-Toggle (du hast bereits `Demo-Modus-Button` in Auth!).
- **Privacy Policy URL**: Pflicht. Muss vor Submission gehostet sein, z.B. `https://<managed-host>/privacy`. Inhalt: was wird gesammelt, wo gespeichert, kein Tracking, Loeschung, Kontakt. **Ohne Privacy-URL = sofort rejected.**
- **Health-Daten-Disclosure**: Du sammelst NSHealthShareUsageDescription-Daten — Reviewer prueft, dass die App-Beschreibung im Store ehrlich erklaert was passiert mit den Daten.
- **Keine Werbung mit Health-Daten**: GUIDELINE 5.1.3(i) — Health-Daten duerfen niemals fuer Ads, Marketing, Verkauf an Dritte oder zu Identifikation ausserhalb der primaeren App-Funktion benutzt werden.
- **Keine Speicherung von Health-Daten in iCloud (CloudKit)**: GUIDELINE 5.1.3(ii). Du speicherst auf eigenem Server (ok) und in HealthKit (ok). NICHT auf iCloud Drive / CloudKit / iCloud Documents.

## 11. Production-Submit Checkliste

> **Korrektur, 2026-08-25 (Legibility-Sweep, Phase 23).** `HL_LOCAL_CONFIG=1 xcodegen` bewirkt heute **nichts**: Commit `04130697` (2026-08-12) hat den `include:` fuer `Config/local.yml` aus `project.yml` entfernt; die Datei enthaelt gar kein `include:` mehr. Der Schritt unten kann nicht leisten, was er sagt. Fuer diese Korrektur wurde nichts neu verdrahtet.

- [ ] App Privacy vollstaendig (Schritt 7)
- [ ] Privacy Policy URL erreichbar
- [ ] App Store Screenshots (6.7"/6.5"/5.5" iPhone, jeweils 3-10 Stueck — `vabole-simulator-utils` kann helfen)
- [ ] App Description, Keywords, Subtitle (`rshankras-app-store` Skill nutzen)
- [ ] Age Rating Form ausgefuellt
- [ ] Falls Pinning gewuenscht: SPKI-Pins + Hosts in `Config/local.yml` (nicht eingecheckt) gesetzt und mit `HL_LOCAL_CONFIG=1 xcodegen` gezogen. Ohne Overlay baut die App ohne Pinning, ohne Passkeys und ohne Universal Links — gueltig, aber der Build-Time-Guard crasht bei einer *halben* Konfiguration
- [ ] APNs `.p8`-Key generiert + auf Server eingetragen (falls Phase 8 / Push aktiv)
- [ ] `CFBundleShortVersionString` auf Production-Version gehoben (z.B. `1.0.0`)
- [ ] `CFBundleVersion` monoton hoch (TestFlight verlangt das)

## 12. Was Apple Review besonders penibel prueft (Health-Apps)

| Was | Wie absichern |
|---|---|
| Permission-Prompt-Texte | Verstaendlich, Nutzen-orientiert, kein Marketing-Sprech. Aktuelle Strings in `project.yml` sind ok. |
| HealthKit-Daten in unangebrachte Felder | Z.B. `body fat percentage` als `body mass` schreiben = Reject. **Niemals** Read-Daten als Write-Daten in anderen HK-Typ persistieren. |
| Background-Modes ohne klaren Nutzen | Reviewer prueft: "Warum braucht die App Background?" → Antwort: HealthKit-Sync (legitim, dokumentiert) + remote-notification (Server-Push-Sync). |
| Crashes im ersten Permission-Sheet | Manche Reviewer denyen alle Permissions absichtlich. App muss mit allen-denied sauber leben. |
| Demo-Mode auf Produktion | OK solange als solcher gekennzeichnet, nicht heimlich Daten schickt. |

## 13. Nuetzliche Skills fuer diesen Schritt

- `rshankras-app-store` — Description, Keywords, Screenshot-Planning, Review-Response
- `rshankras-security` — Letzter Sec-Audit vor Submit
- `vabole-simulator-utils` — Screenshots fuer Store
- `199bio-swiftui-ux-review` — UX-Audit vor TestFlight-Upload
