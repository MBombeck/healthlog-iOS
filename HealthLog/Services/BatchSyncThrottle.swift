import Foundation

/// Sliding-Window Rate-Limiter für den HK-Batch-Upload-Pfad.
/// Server-Limit: **60 Batches / Minute / User** (siehe `08-locked-contracts.md §2.1`).
/// Ohne Pacing würde der initiale Backfill (z. B. 100k+ Spot-HR-Samples eines Power-Users)
/// in ~30s 200+ Batches abfeuern und das Limit sofort sprengen — Server antwortet mit
/// 429 + `X-RateLimit-Reset`, der bestehende APIClient-Backoff läuft an, aber wir wollen
/// das Limit gar nicht erst hitten.
///
/// Algorithmus: jede `acquire()`-Aufruf trimmt das interne `Deque<Date>` aller Aufrufe
/// im aktuellen Window. Wenn die Anzahl `< maxPerWindow`, registriert sich der neue
/// Aufruf sofort. Sonst schläft der Caller bis das älteste Token aus dem Window
/// fällt (+ kleiner Jitter, damit mehrere parallele Aufrufer nicht zur gleichen
/// Millisekunde gleichzeitig wieder feuern).
///
/// Actor-isoliert — Calls seriellisieren sich automatisch.
public actor BatchSyncThrottle {
    public let maxPerWindow: Int
    public let window: TimeInterval
    public let jitter: ClosedRange<TimeInterval>

    /// `now` ist injizierbar für Tests — Production verwendet `Date.init` und
    /// `Task.sleep`, beide via Closures damit Tests einen virtuellen Clock einhängen
    /// können.
    private let nowProvider: @Sendable () -> Date
    private let sleepProvider: @Sendable (TimeInterval) async throws -> Void

    private var timestamps: [Date] = []

    public init(
        maxPerWindow: Int = 60,
        window: TimeInterval = 60.0,
        jitter: ClosedRange<TimeInterval> = 0.05 ... 0.4,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            let nanos = UInt64(max(0, interval) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
        }
    ) {
        self.maxPerWindow = maxPerWindow
        self.window = window
        self.jitter = jitter
        nowProvider = now
        sleepProvider = sleep
    }

    /// Blockiert bis das nächste Batch-Token frei ist. Garantiert maximal
    /// `maxPerWindow` Aufrufe in jedem `window`-langen Sliding-Fenster.
    public func acquire() async throws {
        let current = nowProvider()
        // Drop alle Timestamps außerhalb des Window — sliding semantics.
        let cutoff = current.addingTimeInterval(-window)
        timestamps.removeAll { $0 < cutoff }

        if timestamps.count < maxPerWindow {
            timestamps.append(current)
            return
        }

        // Window ist voll — schlafen bis das älteste Token herausfällt + Jitter.
        let oldest = timestamps.first ?? current
        let waitUntil = oldest.addingTimeInterval(window)
        let baseDelay = max(0, waitUntil.timeIntervalSince(current))
        let jitterDelay = Double.random(in: jitter)
        try await sleepProvider(baseDelay + jitterDelay)

        // Nach dem Sleep noch einmal sliden + Token registrieren.
        let after = nowProvider()
        let newCutoff = after.addingTimeInterval(-window)
        timestamps.removeAll { $0 < newCutoff }
        timestamps.append(after)
    }

    /// Anzahl Tokens die im aktuellen Sliding-Fenster registriert sind. Test-Hilfe.
    public var inFlightCount: Int {
        timestamps.count
    }
}
