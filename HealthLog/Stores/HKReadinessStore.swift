import Foundation
import SwiftUI

// Authorization state, persistence keys, and migration transaction stay atomic.
// swiftlint:disable file_length
#if canImport(HealthKit)
    import HealthKit
#endif

/// Self-check store für HealthKit-Authorisierung.
///
/// **Warum existiert dieser Store?** (F1-Diagnose §R1 + §R2)
/// Bis v0.4.0 hat die App KEINEN Pfad gehabt, post-Onboarding nochmal nach
/// HK-Berechtigung zu fragen. Wenn der User auf der Onboarding-Stelle "Später"
/// tappte oder im System-Sheet einzelne Types ablehnte, war es danach
/// unmöglich, das zu reparieren — Settings → Health zeigte zwar Toggles,
/// drehte aber nur Server-seitige Metadaten. Resultat: User glaubt "sync ist an",
/// hat aber faktisch keinen HK-Read.
///
/// `HKReadinessStore` lädt beim App-Start, beim Foreground-Restore und beim
/// Öffnen von Settings → Health den aktuellen Authorisierungs-Status (für jede
/// Write-Type — Read-Types geben Apple-Privacy-bedingt immer `.notDetermined`
/// zurück) und persistiert daneben einen `requestedAt`-Timestamp (gesetzt beim
/// ersten erfolgreichen `requestAuthorization`-Rücklauf), damit wir
/// `.notRequested` von `.partiallyGranted` unterscheiden können.
///
/// Surfacing:
/// - Dashboard zeigt `HealthKitConnectBanner` wenn `state.shouldShowBanner`.
/// - Settings → Health zeigt `connectionLabel` + "Mit Apple Health verbinden"
///   Row wenn `state != .fullyGranted`.
/// - `triggerManualSync()` ist der Power-User-Affordance zum sofortigen Sync.
@MainActor
@Observable
public final class HKReadinessStore {
    /// Aktueller Connection-State. UI bindet auf `connectionLabel` /
    /// `shouldShowBanner` / `isFullyGranted`.
    public private(set) var state: ConnectionState = .unknown

    /// Zuletzt erfolgreicher HK→Server Batch-Upload — angezeigt in Settings.
    /// Wird vom `MeasurementBatchUploader` nach jedem 2xx-Response via
    /// `noteSuccessfulSync()` aktualisiert.
    public private(set) var lastSyncedAt: Date?

    /// Wird gesetzt während `requestAuthorization()` läuft, damit die UI
    /// Spinner zeigen kann.
    public private(set) var isRequestingAuthorization: Bool = false

    /// Wird gesetzt während `triggerManualSync()` läuft.
    public private(set) var isSyncing: Bool = false

    /// Snapshot der zuletzt von ``refresh()`` gelesenen **Schreib**-Status,
    /// indiziert per HK-Identifier.
    ///
    /// Existiert, weil `state` die Information nur verdichtet: `.partiallyGranted`
    /// trägt zwar die fehlenden Identifier, unterscheidet aber nicht zwischen
    /// „abgelehnt“ und „nie gefragt“ — und die Transparenzfläche
    /// (`SettingsHealthAccessScreen`) muss genau das pro Typ sagen können,
    /// statt zu implizieren, alles Angefragte sei auch erteilt.
    ///
    /// **Nur Schreibtypen.** Apple gibt für Lesetypen keinen Status heraus
    /// (`authorizationStatus(for:)` liefert dort dauerhaft `.notDetermined`),
    /// deshalb steht hier kein einziger Lesetyp — ein fehlender Schlüssel heißt
    /// „die App weiß es nicht“, nicht „nicht erlaubt“.
    public private(set) var writeAuthorizationStatuses: [String: AuthStatus] = [:]

    /// Dismissal-Timestamp für den Dashboard-Banner. Re-erscheint nach 24h.
    public private(set) var bannerDismissedAt: Date?

    /// True iff der letzte `requestAuthorization()`-Lauf **keinen einzigen**
    /// HealthKit-Schreibstatus bewegt hat — iOS fragt nur nach Typen, über die
    /// es noch nie entschieden hat, und schließt den Sheet sonst sofort wieder
    /// („öffnet sich kurz und schließt sich automatisch wieder“).
    ///
    /// Das Flag trägt nur noch den **erklärenden Satz**. Der Ausweg (Deep-Link
    /// nach Apple Health) hängt bewusst nicht mehr daran: eine In-Memory-Flagge,
    /// die jeder Neustart und jeder frische Request löscht, war das Nadelöhr,
    /// durch das der einzige wirksame Weg nach draußen verschwand.
    /// Reset bei jedem neuen `requestAuthorization()`-Aufruf.
    public private(set) var lastAuthorizationWasNoOp: Bool = false

    private let healthKit: AnyHealthKitWriter?
    private let backgroundSync: BackgroundSyncCoordinatorProtocol
    private let keychain: KeychainStoring
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    /// **Phase 07 / plan 07-09** — the one orchestrated route, for the two
    /// `HealthSyncTrigger`s this store owns: `manual` ("Jetzt syncen") and
    /// `postAuthentication` (the Settings re-authorization). It replaces the
    /// split manual hook, which reached a different set of importers than the
    /// foreground and background paths did — the omission this phase exists to
    /// remove.
    private var healthSyncRoute: (@MainActor @Sendable (HealthSyncTrigger) async -> Void)?

    public init(
        healthKit: AnyHealthKitWriter?,
        backgroundSync: BackgroundSyncCoordinatorProtocol,
        keychain: KeychainStoring,
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.healthKit = healthKit
        self.backgroundSync = backgroundSync
        self.keychain = keychain
        self.defaults = defaults
        self.clock = clock
        bannerDismissedAt = loadDismissal()
        lastSyncedAt = Self.loadLastSyncedAt(keychain: keychain, defaults: defaults)
    }

    // MARK: - State

    /// Aggregierter HK-Authorisierungs-Status. Apple's Read-Only-Privacy-Design
    /// macht Read-Status unsichtbar; wir reportieren daher Write-Type-Status
    /// als Proxy + den `requestedAt`-Timestamp als Has-Onboarded-Signal.
    public enum ConnectionState: Equatable, Sendable {
        /// Vor dem ersten `refresh()` — UI zeigt keinen Banner.
        case unknown
        /// Der User hat das HK-System-Sheet NIE gesehen (kein `requestedAt`).
        case notRequested
        /// User hat den Sheet gesehen, aber mindestens ein Write-Type ist nicht
        /// `.sharingAuthorized`. `missingIdentifiers` listet die Identifier
        /// (HKQuantityTypeIdentifierBodyMass etc.) — die UI mappt sie auf
        /// User-lesbare Labels.
        case partiallyGranted(missing: [String])
        /// Alle Write-Types sind authorisiert. UI versteckt den Banner.
        case fullyGranted
        /// Alle Write-Types sind `.sharingDenied` — User hat aktiv abgelehnt.
        /// UI zeigt "Nicht verbunden" + bietet System-Settings-Deep-Link an.
        case denied

        /// Treiber für den Dashboard-Banner. Nur `.fullyGranted` und `.unknown`
        /// (Pre-Refresh, sonst Layout-Jump) verstecken den Banner.
        public var shouldShowBanner: Bool {
            switch self {
            case .unknown, .fullyGranted: false
            case .notRequested, .partiallyGranted, .denied: true
            }
        }

        /// True wenn der User komplett verbunden ist — Settings-Screen versteckt
        /// die "Mit Apple Health verbinden"-Row.
        public var isFullyGranted: Bool {
            if case .fullyGranted = self { return true }
            return false
        }
    }

    /// User-lesbares Connection-Label für Settings → Health.
    public var connectionLabel: String {
        switch state {
        case .unknown:
            String(localized: "Checking status…")
        case .notRequested:
            String(localized: "Not connected")
        case let .partiallyGranted(missing):
            String(localized: "Partially connected — \(missing.count) type(s) missing")
        case .fullyGranted:
            String(localized: "Connected")
        case .denied:
            String(localized: "Declined by the user")
        }
    }

    // MARK: - Banner Dismissal

    /// User hat den Dashboard-Banner über "Nicht jetzt" weggetappt. Wir merken
    /// uns das Datum und zeigen den Banner erst 24h später wieder.
    public func dismissBanner() {
        let now = clock()
        bannerDismissedAt = now
        defaults.set(now.timeIntervalSince1970, forKey: Self.bannerDismissedKey(for: currentUserID))
    }

    /// Treiber für die Dashboard-View. Kombiniert `state.shouldShowBanner` mit
    /// dem 24h-Cooldown nach Dismissal — UND der `isConnected`-Ableitung, damit
    /// ein read-only-User, dessen Daten faktisch syncen, NICHT "nicht
    /// verbunden" angezeigt bekommt (Apple macht READ-Auth unsichtbar, daher
    /// landet so ein User sonst dauerhaft in `.notRequested`/`.partiallyGranted`
    /// obwohl der HK→Server-Batch längst läuft). `.denied` bleibt ehrlich:
    /// `isConnected` ist dort per Definition `false`, der Banner zeigt den
    /// Deeplink.
    public var shouldShowDashboardBanner: Bool {
        guard state.shouldShowBanner else { return false }
        // Sync-truth override: if a real HK→server batch has landed (or the
        // user has been through the sheet and didn't decline), treat them as
        // connected and suppress the banner — the write-auth proxy lies for
        // read-only users.
        guard !isConnected else { return false }
        guard let dismissed = bannerDismissedAt else { return true }
        let elapsed = clock().timeIntervalSince(dismissed)
        return elapsed >= Self.dismissalCooldown
    }

    /// Single source of truth for "is HealthLog actually connected to Apple
    /// Health?" — used by the Dashboard banner + Settings pill instead of the
    /// raw WRITE-type `state`.
    ///
    /// **Why not `state.isFullyGranted`?** Apple's privacy design makes READ
    /// authorisation invisible: `authorizationStatus(for:)` returns
    /// `.notDetermined` for every read-only type forever. A user who granted
    /// READ access (the common case — most of our types are read-only) but no
    /// WRITE access therefore stays in `.notRequested` / `.partiallyGranted`
    /// permanently, and the old write-auth-derived banner showed "nicht
    /// verbunden" even while their data was streaming to the server every hour.
    ///
    /// **The truth signals that actually move for a read-only user:**
    ///   1. `lastSyncedAt != nil` — a real HK→server batch round-tripped
    ///      (set by `MeasurementBatchUploader.noteSuccessfulSync`). This is
    ///      the strongest possible proof of a live connection.
    ///   2. `hasEverRequestedAuthorization && state != .denied` — the user
    ///      went through the system sheet and did not decline everything;
    ///      even before the first batch lands this is a legitimate
    ///      "set up, give it a moment" state, not "not connected".
    ///
    /// `.denied` is honest: the user actively declined, so this returns
    /// `false` and the deeplink/Settings affordance stays visible.
    public var isConnected: Bool {
        // A real HK→server batch roundtrip is the strongest possible proof that
        // receiving works — it beats the write-derived `.denied`. Checking it
        // FIRST stops the permanent "you declined Apple Health" false alarm for a
        // read-granted / write-denied user whose data is demonstrably flowing.
        if lastSyncedAt != nil { return true }
        // No sync yet: `.denied` (all WRITE types declined) stays honest — show
        // the Settings deeplink — while any other post-sheet state is treated as
        // "set up, give it a moment".
        if case .denied = state { return false }
        return hasEverRequestedAuthorization
    }

    /// 24h Cooldown nach manuellem Dismiss.
    public static let dismissalCooldown: TimeInterval = 24 * 60 * 60

    // MARK: - Refresh

    /// Liest `HKHealthStore.authorizationStatus(for:)` für jede Write-Type aus
    /// dem Service-eigenen Default-Set und überträgt das Ergebnis in den
    /// `state`-Enum. Idempotent — kann beliebig oft aufgerufen werden.
    public func refresh() async {
        #if canImport(HealthKit)
            guard let service = healthKit as? any HealthKitServiceProtocol else {
                // Nicht-iOS-Build / Tests ohne echten HK → bleiben in `.unknown`.
                state = .unknown
                writeAuthorizationStatuses = [:]
                return
            }
            // Snapshot der Status pro Write-Type. Read-Types würden immer
            // `.notDetermined` zurückgeben (Apple-Privacy) — daher useless als
            // Signal.
            let statuses = service.authorizationStatuses(for: service.defaultWriteTypes())
            writeAuthorizationStatuses = statuses
            // Migration für bestehende User (pre-v0.4.1): Onboarding hat den
            // Sheet gezeigt aber den `requestedAt`-Flag nie gesetzt. Wenn auch
            // nur ein Write-Type `.sharingAuthorized` ist, wissen wir mit
            // 100%-iger Sicherheit, dass der Sheet schon einmal lief — markieren
            // wir das nachträglich, damit unsere `notRequested`-Heuristik nicht
            // bei jedem User-mit-Partial-Authorisierung Falsch-Positive feuert.
            if statuses.values.contains(.sharingAuthorized), !hasEverRequestedAuthorization {
                markAuthorizationRequested()
            }
            let requested = hasEverRequestedAuthorization

            state = Self.computeState(
                statuses: statuses,
                hasRequestedAuthorization: requested
            )
        #else
            state = .unknown
            writeAuthorizationStatuses = [:]
        #endif
    }

    /// Pure State-Computation — als `static` extrahiert damit Tests sie ohne
    /// echten HKHealthStore aufrufen können. `nonisolated` damit der Test ohne
    /// `@MainActor`-Annotation am Tests-Type laufen kann.
    public nonisolated static func computeState(
        statuses: [String: AuthStatus],
        hasRequestedAuthorization: Bool
    ) -> ConnectionState {
        // Pre-onboarding → `.notRequested`, egal was die Statuses sagen.
        guard hasRequestedAuthorization else { return .notRequested }
        guard !statuses.isEmpty else { return .unknown }

        let denied = statuses.filter { $0.value == .sharingDenied }
        let authorized = statuses.filter { $0.value == .sharingAuthorized }

        // Komplett abgelehnt → eigenes Bucket (UI-Hint Richtung System-Settings).
        if denied.count == statuses.count {
            return .denied
        }
        if authorized.count == statuses.count {
            return .fullyGranted
        }
        let missing = statuses
            .filter { $0.value != .sharingAuthorized }
            .keys
            .sorted()
        return .partiallyGranted(missing: Array(missing))
    }

    /// Wrapper-Enum so we can test computeState ohne `HKAuthorizationStatus` zu
    /// importieren (das ist iOS-only). Bridged 1:1 von HK.
    public enum AuthStatus: Sendable, Equatable {
        case notDetermined
        case sharingDenied
        case sharingAuthorized

        #if canImport(HealthKit)
            init(_ status: HKAuthorizationStatus) {
                switch status {
                case .notDetermined: self = .notDetermined
                case .sharingDenied: self = .sharingDenied
                case .sharingAuthorized: self = .sharingAuthorized
                @unknown default: self = .notDetermined
                }
            }
        #endif
    }

    // MARK: - Request Authorization

    /// Triggert `HKHealthStore.requestAuthorization` für die Default-Read+Write-
    /// Sets und persistiert anschließend einen `requestedAt`-Timestamp (damit
    /// wir bei zukünftigen Cold-Starts `.notRequested` von `.partiallyGranted`
    /// unterscheiden können). Bei Erfolg aktiviert sie Background-Deliveries
    /// und stößt einen einmaligen Anchor-Sweep an.
    ///
    /// Wirft NICHT — Fehler werden geloggt; die UI bekommt den neuen State über
    /// `refresh()` mit. Onboarding ruft direkt `HealthKitServiceProtocol.requestAuthorization`
    /// (mit Backfill-Window-Pick davor); dieser Pfad ist der Return-User-Recovery-Path.
    public func requestAuthorization() async {
        #if canImport(HealthKit)
            guard let service = healthKit as? any HealthKitServiceProtocol else { return }
            guard !isRequestingAuthorization else { return }
            isRequestingAuthorization = true
            lastAuthorizationWasNoOp = false
            defer { isRequestingAuthorization = false }

            // Snapshot die **echten HealthKit-Status** vor dem Sheet, nicht
            // unseren abgeleiteten `state`. Der abgeleitete Zustand faltet die
            // `requestedAt`-Buchführung mit ein — und `markAuthorizationRequested()`
            // kippt die genau hier, mitten in dieser Methode. Ein Aufruf aus
            // `.unknown` oder `.notRequested` heraus sah deshalb *immer* wie
            // Fortschritt aus (`.unknown` → `.partiallyGranted`), obwohl
            // HealthKit gar nichts geändert hatte, und die No-Op-Erkennung
            // schwieg. Der Status-Vergleich kennt diese Buchführung nicht.
            let statusesBeforeRequest = service.authorizationStatuses(for: service.defaultWriteTypes())

            do {
                try await service.requestAuthorization(
                    read: service.defaultReadTypes(),
                    write: service.defaultWriteTypes()
                )
                markAuthorizationRequested()
                // F8 hotfix v0.4.1.1: nach erneutem Authorize muessen vorher
                // disable-gelistete Types wieder versucht werden — sonst
                // bleiben Observer fuer abgelehnte-und-dann-erlaubte Types
                // bis zum naechsten Cold-Start aus.
                await service.resetAuthDisabledTypes()
                // Background-Deliveries scharf schalten + Banner zurücksetzen,
                // damit ein erneutes Antippen direkt Resync triggert.
                await backgroundSync.activateHealthKitBackgroundDeliveries()
                // **Phase 07 / plan 07-09** — dies ist der `postAuthentication`
                // Trigger, und er heißt jetzt so. Vorher fuhr
                // `activateHealthKitBackgroundDeliveries` selbst einen
                // `.foreground`-Pass plus einen detached Aggregat-Sweep, also
                // einen Pass unter falschem Namen und ein zweites Fan-out
                // daneben. Der Pass läuft best-effort im Hintergrund, damit die
                // Berechtigungsfläche nicht auf einem Backfill hängt — genau die
                // v0.14.1-Regel, die der detached Sweep hatte.
                let route = healthSyncRoute
                Task { @MainActor in
                    await route?(HealthSyncTrigger.postAuthentication)
                }
                await refresh()
                // No-Op-Erkennung: kein einziger Schreibstatus hat sich bewegt
                // und es ist weiterhin nicht alles erteilt → iOS hat den Sheet
                // still wieder geschlossen. Das passiert, sobald jeder fehlende
                // Typ bereits entschieden ist (abgelehnt oder erteilt) — Apple
                // fragt nie zweimal nach demselben Typ. Der Betreiber sieht das
                // als „öffnet sich kurz und schließt sich automatisch wieder“.
                //
                // Die Erkennung steuert nur noch den *erklärenden* Satz. Der
                // Ausweg selbst (Deep-Link nach Apple Health) hängt nicht mehr
                // an ihr: solange nicht alles erteilt ist, ist er die einzige
                // Handlung, die überhaupt etwas bewirken kann, und steht
                // deshalb bedingungslos auf der Fläche.
                if !state.isFullyGranted, writeAuthorizationStatuses == statusesBeforeRequest {
                    lastAuthorizationWasNoOp = true
                }
            } catch {
                HLLog.healthKit.error("HK-Re-Authorization fehlgeschlagen: \(error.localizedDescription, privacy: .private)")
                // Auch bei Fehler refreshen — der User kann den Sheet abgebrochen
                // haben, wir bleiben dann auf `.notRequested`.
                await refresh()
            }
        #endif
    }

    /// Öffnet die Health-App. **Nicht mehr und nicht weniger.**
    ///
    /// **H1 — was hier vorher behauptet wurde und nicht stimmt (R7).** Der alte
    /// Kommentar versprach, `x-apple-health://` lande auf der Quellen-Detailseite
    /// von HealthLog, sobald die Bundle-ID als Quelle registriert ist. Das ist
    /// falsch und auf iOS 26 nachprüfbar: das URL-Routing der Health-App
    /// (`HealthAppServices.URLType`) kennt Hosts wie `summary`, `browse`,
    /// `AuthorizationManagement` — ein Schema **ohne** Host trifft keinen davon,
    /// die App startet also schlicht in ihrem letzten Zustand (in der Regel
    /// „Übersicht“). Einen `Sources`-Host gibt es nicht; die kursierende Form
    /// `x-apple-health://Sources/…` stammt aus einem Forenbeitrag ohne
    /// Apple-Antwort.
    ///
    /// Den passenden Deep-Link gäbe es
    /// (`x-apple-health://AuthorizationManagement/<bundle-id>`), aber die
    /// Health-App prüft die **aufrufende** Bundle-ID gegen eine fest verdrahtete
    /// Vierer-Liste (installcoordinationd, Siri, Journal, …). Für Drittanbieter
    /// ist er nicht erreichbar und wäre Private API (App-Review 2.5.1). Apples
    /// eigene Anleitung für abgelehnte Share-Typen lautet deshalb: den Zustand
    /// erkennen und dem Nutzer **den Weg aufschreiben** („Authorizing access to
    /// health data“).
    ///
    /// Genau so ist es hier verdrahtet: der Absprung öffnet Apple Health, und der
    /// Text daneben nennt den Pfad, statt eine Landung zu versprechen, die das
    /// System nicht hergibt. `open(_:)` braucht — anders als `canOpenURL(_:)` —
    /// keinen `LSApplicationQueriesSchemes`-Eintrag.
    public nonisolated static var healthAppDeepLink: URL? {
        URL(string: "x-apple-health://")
    }

    // MARK: - Manual Sync

    /// Installs the one composition-root route this store starts work through.
    ///
    /// It used to be `attachManualSyncHook`, an enumeration of the HealthKit
    /// paths that do not live inside Spezi's collector graph — direct workouts,
    /// aggregate statistics, ECG, and the explicitly enabled mood/medication
    /// mirrors. That enumeration was the defect: "sync everything" meant whichever
    /// importers this list happened to name, and it named a different set than
    /// the foreground and background paths did. The route now takes a
    /// `HealthSyncTrigger` and the orchestrator resolves the plan.
    ///
    /// Internal rather than `public` because `HealthSyncTrigger` is: the
    /// vocabulary is module-internal on purpose (07-05's carrier trick), and the
    /// composition root is the only thing that ever installs a route.
    func attachHealthSyncRoute(
        _ route: @escaping @MainActor @Sendable (HealthSyncTrigger) async -> Void
    ) {
        healthSyncRoute = route
    }

    /// Power-User-Affordance: Settings → Health → "Jetzt syncen". Aktiviert
    /// erneut Background-Deliveries (Apple's enableBackgroundDelivery ist
    /// idempotent) und fährt danach **genau einen** benannten Pass. Tippt der
    /// User das ohne erteilte HK-Permission, ist's ein No-Op — kein Schaden.
    ///
    /// **Phase 07 / plan 07-09.** Vorher liefen hier zwei Dinge hintereinander:
    /// ein `.manual` Collection-Trigger (der seinerseits den orchestrierten Pass
    /// startete) **und** der alte Split-Hook, der Workouts, Aggregate, ECG, Mood
    /// und Medikamente noch einmal einzeln anstieß. Beides zusammen war ein
    /// doppelter Lauf pro Tap — idempotent, aber real. Jetzt ist es ein Pass,
    /// dessen Plan jede Capability nennt.
    public func triggerManualSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        await backgroundSync.reactivateHealthKitBackgroundDeliveries()
        await healthSyncRoute?(HealthSyncTrigger.manual)
    }

    // MARK: - lastSyncedAt write-through

    /// Wird vom `MeasurementBatchUploader` nach jedem erfolgreichen POST
    /// aufgerufen, damit Settings → Health die "Zuletzt synchronisiert"-Zeit
    /// anzeigen kann. Per-User partitioniert wie Anchors + Backfill-Window.
    public func noteSuccessfulSync(at date: Date? = nil) {
        let timestamp = date ?? clock()
        lastSyncedAt = timestamp
        defaults.set(timestamp.timeIntervalSince1970, forKey: Self.lastSyncedKey(for: currentUserID))
    }

    /// Logout-Cleanup. Wird vom `AppContainer.handleLocalLogout` + 401-Bridge
    /// aufgerufen — sonst zeigt der nächste User die Sync-Zeit des vorigen.
    public func clearOnLogout() {
        state = .unknown
        lastSyncedAt = nil
        bannerDismissedAt = nil
        isRequestingAuthorization = false
        isSyncing = false
        lastAuthorizationWasNoOp = false
        writeAuthorizationStatuses = [:]
    }

    /// Per-User-partitionierter Wipe. Wird mit der vorigen User-ID aus dem
    /// AuthStore-Hook aufgerufen, BEVOR die Keychain gewiped wird (Pattern
    /// mirror von `HealthKitService.clearAnchors` + `HealthKitBackfillWindowStore.clear`).
    public nonisolated static func clearPersisted(
        for userId: String?,
        in defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: lastSyncedKey(for: userId))
        defaults.removeObject(forKey: requestedKey(for: userId))
        defaults.removeObject(forKey: bannerDismissedKey(for: userId))
        defaults.removeObject(forKey: workoutReadMigratedKey(for: userId))
        defaults.removeObject(forKey: workoutReadRearmPendingKey(for: userId))
    }

    // MARK: - Persistence

    /// Wurde `requestAuthorization` jemals erfolgreich abgeschickt? Per-User
    /// partitioniert — Re-Login mit anderem Account fängt sauber bei
    /// `.notRequested` an. Zur Migration: alter Code hatte das nicht; bestehende
    /// User mit gesetzten Anchors gelten implizit als requested (Self-Heal in
    /// `markAuthorizationRequestedIfAnchorsExist`).
    public var hasEverRequestedAuthorization: Bool {
        defaults.bool(forKey: Self.requestedKey(for: currentUserID))
    }

    /// Markiert den User als "Hat den HK-Sheet gesehen". Wird automatisch von
    /// `requestAuthorization()` aufgerufen UND extern vom OnboardingFlow nach
    /// dem ersten Sheet — damit die Migration für bestehende User funktioniert,
    /// die Onboarding bereits durchhatten (sonst zeigte der Banner auch bei
    /// fullyGranted, weil der Flag noch nicht gesetzt war).
    public func markAuthorizationRequested() {
        defaults.set(true, forKey: Self.requestedKey(for: currentUserID))
    }

    // MARK: - Workout-read re-auth migration (W-B182 / AUDIT-WORKOUTS-RCA fix #2)

    /// One-shot per-user re-authorization for the workout READ type.
    ///
    /// `HKObjectType.workoutType()` joined `defaultReadTypes` only in b171/v1.15.
    /// A user who finished HK onboarding before that already has
    /// `requestedAt` set, so the normal cold-start path never re-prompts — and
    /// Apple never reports read grants, so the denial is invisible. Net effect:
    /// the workout importer's anchored sweep returns an empty set forever and no
    /// workout history ever flows.
    ///
    /// This migration forces exactly ONE `requestAuthorization()` pass (which
    /// already includes `workoutType()` in `defaultReadTypes`) for returning
    /// users whose `requestedAt` predates the workout-read addition. Apple shows
    /// the sheet for genuinely-new read types even when others are already
    /// determined; users who already granted/denied workout read see no UI. New
    /// users (who never requested) are skipped here — their first onboarding
    /// request already includes workout read — but the flag is still marked so
    /// the migration never runs twice. Idempotent + per-user partitioned.
    ///
    /// **Returns `true`** when it actually ran a re-auth pass for a returning
    /// user (i.e. the caller should now force a FULL workout re-sweep). The
    /// re-prompt alone is not enough: a pre-b182 build may have already advanced
    /// the workout anchor over an empty sweep (the silent history mask). Once
    /// auth lands, an incremental sweep from that masked anchor would still see
    /// nothing, so the caller MUST reset the workout import anchor to backfill
    /// history. Returns `false` when no re-auth was needed (new user / already
    /// migrated / no HK service), so the caller skips the (costly) reset.
    @discardableResult
    public func requestWorkoutReadAuthorizationMigrationIfNeeded() async -> Bool {
        #if canImport(HealthKit)
            let ownerUserID = currentUserID
            if defaults.bool(forKey: Self.workoutReadRearmPendingKey(for: ownerUserID)) {
                return true
            }
            if defaults.bool(forKey: Self.workoutReadMigratedKey(for: ownerUserID)) {
                return false
            }
            // Only returning users (who requested before b182) need the forced
            // re-prompt. A user who has never requested will get workout read in
            // their normal first onboarding request; just mark + return.
            guard hasEverRequestedAuthorization else {
                defaults.set(true, forKey: Self.workoutReadMigratedKey(for: ownerUserID))
                return false
            }
            guard let service = healthKit as? any HealthKitServiceProtocol else {
                // No HK service (tests / non-HK build): mark so we don't spin.
                defaults.set(true, forKey: Self.workoutReadMigratedKey(for: ownerUserID))
                return false
            }
            guard let ownerUserID,
                  !ownerUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let bearer = keychain.getString(forKey: KeychainKey.authToken),
                  !bearer.isEmpty,
                  !Task.isCancelled else { return false }
            do {
                try await service.requestAuthorization(
                    read: service.defaultReadTypes(),
                    write: service.defaultWriteTypes()
                )
                guard !Task.isCancelled,
                      currentUserID == ownerUserID,
                      keychain.getString(forKey: KeychainKey.authToken) == bearer else { return false }
                guard !Task.isCancelled else { return false }
                // Pending first: a crash between these writes must retry the
                // durable service-side rearm, never strand a migrated user.
                defaults.set(true, forKey: Self.workoutReadRearmPendingKey(for: ownerUserID))
                defaults.set(true, forKey: Self.workoutReadMigratedKey(for: ownerUserID))
                HLLog.healthKit.info("Workout-read re-auth migration ran (returning user)")
            } catch {
                HLLog.healthKit.error(
                    "Workout-read re-auth migration failed: \(error.localizedDescription, privacy: .private)"
                )
                return false
            }
            return true
        #else
            return false
        #endif
    }

    private var currentUserID: String? {
        keychain.getString(forKey: KeychainKey.userID)
    }

    private func loadDismissal() -> Date? {
        let value = defaults.double(forKey: Self.bannerDismissedKey(for: currentUserID))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// Load der persistierten lastSyncedAt. Per-User. Pre-Login: leer.
    /// `nonisolated` damit `init` (sich selbst MainActor-isoliert) den Call
    /// machen kann ohne self-hop.
    public nonisolated static func loadLastSyncedAt(
        keychain: KeychainStoring,
        defaults: UserDefaults = .standard
    ) -> Date? {
        let userId = keychain.getString(forKey: KeychainKey.userID)
        let value = defaults.double(forKey: lastSyncedKey(for: userId))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    // MARK: - Keys

    /// Prefix für UserDefaults-Keys — geteilt mit `HealthKitService.anchorDefaultsKeyPrefix`-Pattern.
    /// `nonisolated` damit die Key-Helper aus nonisolated-Kontexten (Logout-Hook
    /// im AuthStore-Closure) ohne `await MainActor.run`-Hop arbeiten können.
    public nonisolated static let lastSyncedKeyPrefix = "hl.healthkit.lastSyncedAt."
    public nonisolated static let requestedKeyPrefix = "hl.healthkit.requestedAt."
    public nonisolated static let bannerDismissedKeyPrefix = "hl.healthkit.bannerDismissedAt."
    /// W-B182 — one-shot per-user flag: has the workout-read re-auth migration run?
    public nonisolated static let workoutReadMigratedKeyPrefix = "hl.healthkit.workoutReadMigrated."
    public nonisolated static let workoutReadRearmPendingKeyPrefix = "hl.healthkit.workoutReadRearmPending."

    /// Public for test introspection.
    public nonisolated static func lastSyncedKey(for userId: String?) -> String {
        lastSyncedKeyPrefix + partitionToken(for: userId)
    }

    public nonisolated static func requestedKey(for userId: String?) -> String {
        requestedKeyPrefix + partitionToken(for: userId)
    }

    public nonisolated static func bannerDismissedKey(for userId: String?) -> String {
        bannerDismissedKeyPrefix + partitionToken(for: userId)
    }

    public nonisolated static func workoutReadMigratedKey(for userId: String?) -> String {
        workoutReadMigratedKeyPrefix + partitionToken(for: userId)
    }

    public nonisolated static func workoutReadRearmPendingKey(for userId: String?) -> String {
        workoutReadRearmPendingKeyPrefix + partitionToken(for: userId)
    }

    public nonisolated static func clearWorkoutReadRearmPending(
        for userId: String?,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: workoutReadRearmPendingKey(for: userId))
    }

    /// Mirror der `HealthKitService.partitionToken`-Logik (dupliziert für
    /// HealthLogCore-Frei-Build — diese Klasse darf nur im App-Target leben).
    ///
    /// **v0.6.2.3 F3-SEC (A-SEC M-6 reconcile + A-CODE M-3 drift fix):** the
    /// legacy implementation only replaced dots with underscores, so an
    /// id containing `/`, `..`, or unicode look-alikes would have survived
    /// into the UserDefaults key (`hl.healthkit.requested.<token>`, etc.).
    /// `HealthKitService.partitionToken` + `HealthKitBackfillWindowStore.
    /// partitionToken` adopted a strict `[A-Za-z0-9_-]` allowlist + 64-char
    /// cap in v0.6.2.0 (commit 4fd1a0e6); this site was missed in that
    /// landing and is brought in line here. The three implementations are
    /// pinned aligned by `PartitionTokenHardeningTests`.
    ///
    /// **Migration safety:** the new allowlist differs from the legacy
    /// `replacingOccurrences(of: ".", with: "_")` mapping (legacy: a
    /// dotted id like `anna.fischer` produced `anna_fischer`; the
    /// allowlist drops disallowed chars instead → `annafischer`). For
    /// the readiness-store partitions specifically:
    ///   * `requested.<token>` — set on first authorisation request,
    ///     unset on logout; a re-sign-in under a different token simply
    ///     re-requests authorisation. Worst case: the next-launch
    ///     surface re-asks the user "Grant HealthKit?" once. No data
    ///     loss.
    ///   * `lastSynced.<token>` — used for the readiness banner; a
    ///     missed-key reads as "never synced" and the banner repaints.
    ///     No data loss.
    ///   * `bannerDismissed.<token>` — UI hygiene only; a missed-key
    ///     re-shows the dismissal banner once. No data loss.
    /// Production userIds are `usr_<cuid>`-shaped today, so this migration
    /// is a no-op for every existing TestFlight install. If a dotted
    /// userId ever lands on prod, the three above-listed surfaces will
    /// self-heal on next launch.
    private nonisolated static func partitionToken(for userId: String?) -> String {
        guard let raw = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "_anonymous"
        }
        let filtered = raw.unicodeScalars.lazy.filter { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar.value == 0x5F // _
                || scalar.value == 0x2D // -
        }
        let sanitized = String(String.UnicodeScalarView(filtered))
        guard !sanitized.isEmpty else { return "_anonymous" }
        return String(sanitized.prefix(64))
    }
}

// MARK: - BackgroundSyncCoordinator Protocol (test-seam)

/// Test-Seam für den `BackgroundSyncCoordinator` — damit Unit-Tests die HK-
/// Pipeline ohne BGTaskScheduler-Registrierung (= ohne Crash) bauen können.
public protocol BackgroundSyncCoordinatorProtocol: Sendable {
    func activateHealthKitBackgroundDeliveries() async
    func reactivateHealthKitBackgroundDeliveries() async
}

public extension BackgroundSyncCoordinatorProtocol {
    func reactivateHealthKitBackgroundDeliveries() async {
        await activateHealthKitBackgroundDeliveries()
    }
}

extension BackgroundSyncCoordinator: BackgroundSyncCoordinatorProtocol {}

// MARK: - HealthKitService extension: status-batch query

#if canImport(HealthKit)
    public extension HealthKitService {
        /// Liefert den `HKAuthorizationStatus` für jede Sample-Type aus `types`,
        /// indiziert per Identifier (`HKQuantityTypeIdentifierBodyMass` etc.).
        /// Wrapped in `HKReadinessStore.AuthStatus` damit Caller nicht HK
        /// importieren müssen.
        ///
        /// `nonisolated` — gleiches Pattern wie `authorizationStatus(for:)`:
        /// `HKHealthStore.authorizationStatus(for:)` ist von Apple als
        /// thread-safe dokumentiert, kein Actor-Hop nötig.
        nonisolated func authorizationStatuses(
            for types: Set<HKSampleType>
        ) -> [String: HKReadinessStore.AuthStatus] {
            var result: [String: HKReadinessStore.AuthStatus] = [:]
            for type in types {
                let status = store.authorizationStatus(for: type)
                result[type.identifier] = HKReadinessStore.AuthStatus(status)
            }
            return result
        }
    }
#endif
