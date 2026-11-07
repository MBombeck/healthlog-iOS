import Foundation

/// **CU-21 (C1, Rest von #66)** — der Auslöser des gerade laufenden Sync-Sweeps.
///
/// Wire-Enum für das optionale Top-Level-Feld `syncTrigger` auf
/// `POST /api/measurements/batch` (Geschwister von `entries`, Server ≥ v1.32.31).
/// Bewusst ein **geschlossenes** Enum: wir *senden* nur, was der Vertrag kennt.
///
/// **V1 (1.2)** — `manual` kam mit Server v1.42.0 dazu (#123, HealthLog#1173):
/// ein vom Nutzer gestartetes „Alle synchronisieren". Ältere Server lehnen den
/// Wert mit 400 für den ganzen Batch ab (`z.enum` ohne `manual`), deshalb geht
/// er nur auf den Draht, wenn der Server ihn nachweislich kennt
/// (``SyncTriggerContext/wireValue``); sonst wird er als `foreground` gesendet,
/// was er vor 1.2 auch war.
public enum SyncTrigger: String, Codable, Sendable, CaseIterable, Equatable {
    /// Die App lief im Vordergrund: Foreground-Revalidate, Ziehen zum
    /// Aktualisieren, Onboarding-Connect, Adopt-Import.
    case foreground
    /// Ein `BGProcessingTask` / `BGAppRefreshTask`-Wake oder eine
    /// HK-Background-Delivery, während die App im Hintergrund war.
    case background
    /// Ein Silent-Push hat den Prozess geweckt.
    case push
    /// Der Nutzer hat „Alle synchronisieren" / „Jetzt syncen" gedrückt
    /// (Server ≥ v1.42.0).
    case manual
    /// **X4 (1.3, #138 / #77)** — ein Verlaufs-Nachtrag (der stündliche
    /// 30-Tage-Backfill der Summentypen). Bewegt beim Server nur
    /// `syncProgress` und `lastBackfillAt`, nie `lastReceivedAt` oder
    /// `lastTrigger`. Nie aus einem Pass abgeleitet: nur die Markierung am
    /// Upload (``SyncTriggerContext/wireValue(backfill:)``) setzt ihn, und auf
    /// den Draht geht er nur, wenn der Server `features.syncTriggerBackfill`
    /// meldet.
    case backfill

    /// The first server release whose batch route accepts `manual`.
    public static let manualMinimumServerVersion = "1.42.0"
    /// X4 — the first server release that can carry `backfill` and the hourly
    /// `stats:` rows. Necessary, not sufficient: the `/api/auth/me` feature
    /// flag decides (``KnownServerVersion/supports(_:defaults:)``).
    public static let backfillMinimumServerVersion = "1.43.0"
}

/// Prozessweiter Träger des **tatsächlichen** Auslösers des laufenden Sweeps.
///
/// ## Warum ein ambienter Kontext statt eines Parameters
///
/// Die Batch-POSTs entstehen tief in der Pipeline (SpeziHealthKit-Observer,
/// Stats-Coordinator, HR-Bucket-Coordinator, Device-Forwarder, Outbox). Keiner
/// dieser Aufrufer *weiß*, warum er gerade läuft — das weiß nur die Stelle, die
/// den Sweep angestoßen hat (BGTask-Handler, Push-Handler, Foreground-Pfad).
/// Einen Parameter durch fünf Ebenen zu fädeln hieße, ihn an jeder Verzweigung
/// erneut zu raten. Stattdessen markiert **der Auslöser selbst** sein Fenster,
/// und der Uploader liest am POST ab, in welchem Fenster er steht.
///
/// ## Semantik
///
/// - ``withTrigger(_:_:)`` bindet den Auslöser an die **Task** (Task-Local) und
///   öffnet zusätzlich ein prozessweites Fenster. Die Task-Bindung gewinnt: sie
///   folgt der Arbeit in jede `Task { }`, die darin entsteht (ein angestoßener
///   Tageswerte- oder Herzfrequenz-Lauf), auch wenn das Fenster längst zu ist,
///   und sie färbt keine fremde, gleichzeitig laufende Arbeit ein.
/// - `begin(_:)` / `end(_:)` klammern nur das prozessweite Fenster.
///   Verschachtelung ist erlaubt; der **innerste** offene Scope gewinnt.
/// - **V1 (1.2)** — ohne Bindung und ohne offenes Fenster entscheidet der
///   zuletzt gemeldete App-Zustand (``noteApplicationState(backgrounded:)``):
///   im Hintergrund `background`, sonst `foreground`. Bis 1.1.1 hieß die
///   Restmenge immer `foreground`, und ein Lauf, der nach dem Schließen eines
///   Hintergrund-Fensters postete (der Herzfrequenz-Lauf aus einer
///   Zustellung), kam als `foreground` beim Server an (#66, Serverlog 8./9.10.).
/// - **W5 (1.3, #126 1.2)** — ein geschlossenes Fenster wird nicht mehr
///   zu `foreground`. Ist der App-Zustand unbekannt, gilt der Auslöser des
///   zuletzt geschlossenen Fensters; liegt die App im Hintergrund und das
///   letzte Fenster war ein Push (später geschlossen als der Zustand gemeldet
///   wurde), bleibt die Nacharbeit `push` statt `background`. `foreground`
///   sagt der Rückfall nur noch, wenn die App nachweislich vorne ist oder es
///   nie ein Fenster gab.
///
/// `@unchecked Sendable` mit `NSLock` statt `actor`, weil der Uploader den Wert
/// **synchron** am POST braucht. Die Sperre, nicht der Compiler, beweist hier
/// die Exklusivität; gleiches Muster wie `MockURLProtocol` / `OneShotCompletion`.
public final class SyncTriggerContext: @unchecked Sendable {
    /// Prozessweite Instanz. Der Auslöser ist eine Eigenschaft der *Laufzeit*,
    /// nicht einer Objektinstanz.
    public static let shared = SyncTriggerContext(defaults: .standard)

    /// The per-task bindings, keyed by context instance so an isolated test
    /// context never leaks into ``shared`` (and the other way round).
    @TaskLocal private static var bindings: [ObjectIdentifier: SyncTrigger] = [:]

    private let lock = NSLock()
    private var scopes: [SyncTrigger] = []
    private var applicationBackgrounded: Bool?
    /// W5 — a counter, not a clock: which of "app state noted" and "last
    /// window closed" happened later.
    private var sequence: UInt64 = 0
    private var applicationStateSequence: UInt64 = 0
    /// W5 — the trigger of the window that closed last, with its sequence.
    private var lastClosedScope: (trigger: SyncTrigger, sequence: UInt64)?
    /// Nur ohne `defaults` (isolierte Testinstanz): die gemerkte Version im Speicher.
    private var inMemoryServerVersion: ServerVersionInfo?
    /// X4 — nur ohne `defaults`: die gemerkten Server-Funktionen im Speicher.
    private var inMemoryFeatures: Set<KnownServerVersion.Feature> = []
    private let defaults: UserDefaults?

    /// `internal` statt `private`, damit Tests eine isolierte Instanz bauen
    /// können, ohne den prozessweiten Zustand anzufassen. Ohne `defaults`
    /// bleibt die Server-Version nur im Speicher.
    ///
    /// **INT-N (1.2)** — mit `defaults` liest der Kontext die eine gemerkte
    /// Server-Version (``KnownServerVersion``), die auch
    /// `HealthKitServerTypeGate` (RMSSD, V4) liest. Die App schreibt sie an
    /// genau einer Stelle (`refreshMedicationSlotGate`) und vergisst sie an
    /// genau einer (`reloadEnvironment`); `manual` und RMSSD können sich also
    /// nie über den Server uneinig sein.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    /// Ob der Server `manual` kennt, aus der einen gemerkten Server-Version.
    private var serverAcceptsManual: Bool {
        let minimum = SyncTrigger.manualMinimumServerVersion
        if let defaults {
            return KnownServerVersion.isAtLeast(minimum, defaults: defaults)
        }
        return lock.withLock { inMemoryServerVersion }?.isAtLeast(minimum) ?? false
    }

    /// X4 — ob der Server `syncTrigger: backfill` annimmt (v1.43-Flag).
    private var serverAcceptsBackfill: Bool {
        if let defaults {
            return KnownServerVersion.supports(.syncTriggerBackfill, defaults: defaults)
        }
        return lock.withLock { inMemoryFeatures.contains(.syncTriggerBackfill) }
            && (lock.withLock { inMemoryServerVersion }?.isAtLeast(SyncTrigger.backfillMinimumServerVersion) ?? false)
    }

    /// Der Auslöser, der für einen JETZT abgesetzten Batch-POST gilt.
    public var current: SyncTrigger {
        if let bound = Self.bindings[ObjectIdentifier(self)] { return bound }
        return lock.withLock {
            if let scope = scopes.last { return scope }
            return fallbackLocked
        }
    }

    /// W5 — the answer with no binding and no open window. Caller holds `lock`.
    private var fallbackLocked: SyncTrigger {
        switch applicationBackgrounded {
        case false?:
            // The app is in front: whatever posts now, a person has it open.
            return .foreground
        case true?:
            // A push window that closed after the app went to the background
            // keeps its word for the work it started; anything else is
            // background work.
            if let closed = lastClosedScope, closed.trigger == .push,
               closed.sequence > applicationStateSequence
            {
                return .push
            }
            return .background
        case nil:
            // Unknown state (a launch nobody reported yet): the window that
            // just closed is the best evidence there is. Only with no window at
            // all does the old rest value stand.
            return lastClosedScope?.trigger ?? .foreground
        }
    }

    /// Was auf den Draht geht: ``current``, außer `manual` gegenüber einem
    /// Server, der den Wert (noch) nicht kennt. Dann `foreground`, wie vor 1.2.
    public var wireValue: SyncTrigger {
        wireValue(backfill: false)
    }

    /// **SYNC-TRIG (1.5, #138)** — what a batch carries when the caller
    /// says whether it is a history catch-up. The mark is an argument of the
    /// one upload, not a task-local: a task-local followed the work into every
    /// `Task { }` started under it (a heart-rate sweep a page kicks, a stamp
    /// the upload hands off), and those are live work. A marked batch goes as
    /// `backfill` where the server takes it; otherwise under the trigger it
    /// would have had without the mark, so an older server sees exactly what
    /// it saw before 1.3.
    public func wireValue(backfill: Bool) -> SyncTrigger {
        if backfill, serverAcceptsBackfill { return .backfill }
        return accepted(current)
    }

    /// **SYNC-TRIG** — the word a parked batch replays under. The outbox keeps
    /// the trigger the batch was posted with; the server it replays against
    /// may no longer take it (a self-hosted rollback, an older server after a
    /// change of address). `manual` and `backfill` fall back to `foreground`
    /// there, because an unknown value refuses the whole batch with 422 and
    /// the replay would split good rows into the refusal register. `nil` (a
    /// row from 1.3.0 or older) stays `nil`, byte for byte.
    public func replayValue(_ stored: SyncTrigger?) -> SyncTrigger? {
        stored.map(accepted)
    }

    private func accepted(_ trigger: SyncTrigger) -> SyncTrigger {
        switch trigger {
        case .manual: serverAcceptsManual ? .manual : .foreground
        case .backfill: serverAcceptsBackfill ? .backfill : .foreground
        case .foreground, .background, .push: trigger
        }
    }

    /// Öffnet ein prozessweites Auslöser-Fenster. Muss von genau einem
    /// `end(_:)` geschlossen werden — nutze bevorzugt ``withTrigger(_:_:)``.
    public func begin(_ trigger: SyncTrigger) {
        lock.withLock { scopes.append(trigger) }
    }

    /// Schließt das zuletzt geöffnete Fenster dieses Auslösers. Entfernt gezielt
    /// den letzten passenden Eintrag (statt blind `removeLast`), damit sich
    /// überlappende Fenster unterschiedlicher Auslöser nicht gegenseitig
    /// abräumen.
    public func end(_ trigger: SyncTrigger) {
        lock.withLock {
            if let index = scopes.lastIndex(of: trigger) {
                scopes.remove(at: index)
                sequence &+= 1
                lastClosedScope = (trigger, sequence)
            }
        }
    }

    /// Führt `body` mit `trigger` aus: an die Task gebunden und als
    /// prozessweites Fenster. Beides endet auch bei Throw und Cancellation.
    public func withTrigger<T>(
        _ trigger: SyncTrigger,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        begin(trigger)
        defer { end(trigger) }
        return try await bind(trigger, body)
    }

    /// **V1** — bindet `trigger` nur an die Task, ohne prozessweites Fenster.
    /// Für einen Pass, der seinen Auslöser kennt: alles, was er (auch in
    /// eigenen Tasks) postet, trägt ihn, und gleichzeitige fremde Arbeit
    /// bleibt unberührt.
    public func bind<T>(
        _ trigger: SyncTrigger,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        var bound = Self.bindings
        bound[ObjectIdentifier(self)] = trigger
        return try await Self.$bindings.withValue(bound) {
            try await body()
        }
    }

    /// **V1** — der zuletzt beobachtete App-Zustand, für Arbeit ohne Bindung.
    /// `RootView` meldet `.active` / `.background`; `nil` heißt unbekannt.
    public func noteApplicationState(backgrounded: Bool?) {
        lock.withLock {
            applicationBackgrounded = backgrounded
            sequence &+= 1
            applicationStateSequence = sequence
        }
    }

    /// **V1** — merkt sich die Antwort des `/api/version`-Probes. Mit
    /// `defaults` ist das genau ``KnownServerVersion/record(_:defaults:)``.
    /// Ein Wechsel der Server-Adresse vergisst sie (``forgetServer()``).
    public func noteServerVersion(_ info: ServerVersionInfo) {
        if let defaults {
            KnownServerVersion.record(info, defaults: defaults)
        } else {
            lock.withLock { inMemoryServerVersion = info }
        }
    }

    public func forgetServer() {
        if let defaults {
            KnownServerVersion.forget(defaults: defaults)
        } else {
            lock.withLock {
                inMemoryServerVersion = nil
                inMemoryFeatures = []
            }
        }
    }

    /// X4 — merkt sich `features` aus `GET /api/auth/me`. Mit `defaults` ist
    /// das ``KnownServerVersion/recordFeatures(_:defaults:)``.
    func noteServerFeatures(_ features: Set<KnownServerVersion.Feature>) {
        if let defaults {
            KnownServerVersion.recordFeatures(features, defaults: defaults)
        } else {
            lock.withLock { inMemoryFeatures = features }
        }
    }

    #if DEBUG
        /// Test-Introspektion: Tiefe der offenen Fenster. Kein Produktivpfad
        /// liest das.
        var openScopeCount: Int {
            lock.withLock { scopes.count }
        }
    #endif
}

/// **INT-N (1.2)** — the last answer of `GET /api/version` for the configured
/// server, kept once for every client-side capability gate that depends on
/// it: V1's `syncTrigger: manual` (``SyncTriggerContext``) and V4's RMSSD
/// collection (`HealthKitServerTypeGate`). Before INT-N each kept its own copy
/// under its own key, so the two could disagree about the same server.
///
/// A capability fact about a host, not health data, so `UserDefaults`.
/// Unknown (never probed, or forgotten after a server change) answers `false`
/// to every minimum: fail closed. Lives next to `SyncTriggerContext` because
/// every target that compiles the context (the widget extension included)
/// must compile this too.
enum KnownServerVersion {
    /// Kept from V4 so the RMSSD gate's stored answer survives the merge.
    static let defaultsKey = "hl.healthkit.serverVersion"

    static func record(_ info: ServerVersionInfo, defaults: UserDefaults = .standard) {
        defaults.set(info.version, forKey: defaultsKey)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: featuresDefaultsKey)
    }

    /// **X4 (1.3, #138)** — what `GET /api/auth/me` `features` says this
    /// server understands. The server publishes the flags so a client released
    /// apart from it never sends a form an older server would misread (a v1.42
    /// server stores every hourly row as its own measurement and inflates the
    /// day total; it refuses `backfill` with 422 for the whole batch).
    enum Feature: String, CaseIterable, Sendable {
        case cumulativeHourBuckets
        case syncTriggerBackfill
    }

    static let featuresDefaultsKey = "hl.server.features"

    /// Replaces the remembered set. An answer without `features` (an older
    /// server) records the empty set: absent means "does not have it".
    static func recordFeatures(_ features: Set<Feature>, defaults: UserDefaults = .standard) {
        defaults.set(features.map(\.rawValue).sorted(), forKey: featuresDefaultsKey)
    }

    /// `true` only when the server reported the flag AND the remembered
    /// version is at least 1.43.0. Unknown answers `false`: fail closed.
    static func supports(_ feature: Feature, defaults: UserDefaults = .standard) -> Bool {
        guard isAtLeast(SyncTrigger.backfillMinimumServerVersion, defaults: defaults) else { return false }
        let raw = defaults.stringArray(forKey: featuresDefaultsKey) ?? []
        return raw.contains(feature.rawValue)
    }

    /// `true` only when a version is known and is at least `minimum`.
    static func isAtLeast(_ minimum: String, defaults: UserDefaults = .standard) -> Bool {
        guard let version = defaults.string(forKey: defaultsKey) else { return false }
        return ServerVersionInfo(version: version).isAtLeast(minimum)
    }
}
