import Foundation

/// **CU-21 (C1, Rest von #66)** — der Auslöser des gerade laufenden Sync-Sweeps.
///
/// Wire-Enum für das optionale Top-Level-Feld `syncTrigger` auf
/// `POST /api/measurements/batch` (Geschwister von `entries`, Server ≥ v1.32.31).
/// Die drei Werte sind exakt die, die der Server akzeptiert — ein vierter Wert
/// wäre ein 422, deshalb ist das hier bewusst ein **geschlossenes** Enum (anders
/// als bei den Decode-Pfaden, wo Toleranz gilt: wir *senden* nur, was der
/// Vertrag kennt).
///
/// Der Server persistiert den Wert und leitet daraus ab, ob ein Telefon
/// **selbstständig** liefert (`background` / `push`) oder nur bei geöffneter App
/// (`foreground`). Genau diese Unterscheidung fehlte in #66.
public enum SyncTrigger: String, Codable, Sendable, CaseIterable, Equatable {
    /// Die App lief im Vordergrund: Foreground-Revalidate, „Jetzt syncen",
    /// Onboarding-Connect, Adopt-Import.
    case foreground
    /// Ein `BGProcessingTask` / `BGAppRefreshTask`-Wake oder eine
    /// HK-Background-Delivery, während die App im Hintergrund war.
    case background
    /// Ein Silent-Push hat den Prozess geweckt.
    case push
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
/// - `begin(_:)` / `end(_:)` klammern ein Auslöser-Fenster. Verschachtelung ist
///   erlaubt (ein Push-Wake kann während eines BGTask laufen); der **innerste**
///   offene Scope gewinnt, weil er der spezifischere Auslöser ist.
/// - Ohne offenen Scope ist die Antwort `foreground`. Das ist keine Annahme,
///   sondern die Restmenge: jeder Hintergrund- und Push-Pfad der App klammert
///   sich (BGProcessing, BGAppRefresh, Silent-Push, HK-Background-Delivery), es
///   bleibt also nur der Fall „App läuft, User schaut zu".
///
/// `@unchecked Sendable` mit `NSLock` statt `actor`, weil der Uploader den Wert
/// **synchron** am POST braucht und ein `await` in einen Actor die Klammerung
/// aus `BGTask.expirationHandler` (läuft auf beliebigem Thread, `noasync`)
/// verkomplizieren würde. Die Sperre — nicht der Compiler — beweist hier die
/// Exklusivität; gleiches Muster wie `MockURLProtocol` / `OneShotCompletion`.
public final class SyncTriggerContext: @unchecked Sendable {
    /// Prozessweite Instanz. Der Auslöser ist eine Eigenschaft der *Laufzeit*,
    /// nicht einer Objektinstanz — ein BGTask-Wake gilt für jeden Upload, den er
    /// verursacht, egal welcher Uploader ihn absetzt.
    public static let shared = SyncTriggerContext()

    private let lock = NSLock()
    private var scopes: [SyncTrigger] = []

    /// `internal` statt `private`, damit Tests eine isolierte Instanz bauen
    /// können, ohne den prozessweiten Zustand anzufassen.
    init() {}

    /// Der Auslöser, der für einen JETZT abgesetzten Batch-POST gilt.
    public var current: SyncTrigger {
        lock.withLock { scopes.last } ?? .foreground
    }

    /// Öffnet ein Auslöser-Fenster. Muss von genau einem `end(_:)` geschlossen
    /// werden — nutze bevorzugt ``withTrigger(_:_:)``.
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
            }
        }
    }

    /// Führt `body` innerhalb eines Auslöser-Fensters aus. Das Fenster schließt
    /// auch bei Throw und bei Cancellation (`defer`).
    public func withTrigger<T>(
        _ trigger: SyncTrigger,
        _ body: () async throws -> T
    ) async rethrows -> T {
        begin(trigger)
        defer { end(trigger) }
        return try await body()
    }

    #if DEBUG
        /// Test-Introspektion: Tiefe der offenen Fenster. Kein Produktivpfad
        /// liest das.
        var openScopeCount: Int {
            lock.withLock { scopes.count }
        }
    #endif
}
