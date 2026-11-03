import Foundation

/// **B5 (1.4, from A4 / HealthLog#1247) — which kinds HealthLog may write
/// into Apple Health, by the person's per-type setting on the server.**
///
/// `GET /api/integrations/healthkit` carries one entry per Apple Health kind
/// with a direction (`bidirectional`, `readOnly`, `writeOnly`, `disabled`) and
/// an `enabled` switch. Up to 1.3 the app showed them and wrote anyway: the
/// server→Health mirror and the create-time write only asked for the Apple
/// Health share permission. The server's own rule for "this kind is written
/// back" is `healthKitWriteBackTypes` (`src/lib/integrations/
/// healthkit-type-sync.ts`, read at v1.43.10): the entry is enabled AND its
/// direction is `bidirectional` or `writeOnly`. This type applies exactly
/// that rule, per kind, and nothing else:
///
/// - A kind with no entry has no setting, so it keeps writing as before
///   (body fat, temperature, SpO2, resting pulse, HRV, VO2 max, BMI today).
/// - A kind with several entries writes when any of them allows it, the way
///   the server unions them.
/// - Pulse is `readOnly` in the server's defaults (`DEFAULT_HEALTHKIT_ENTRIES`),
///   so a default account no longer gets pulse readings written into Apple
///   Health. Nothing already there is touched: the mirror never deletes.
///
/// Platform-free, so a test decodes the exact configuration a 1.3.0 build
/// cached and checks the decision without HealthKit.
public struct HealthKitWriteBackPolicy: Sendable, Equatable {
    /// Per kind named by an entry: whether any of its entries lets the app write.
    let decisions: [MetricKind: Bool]

    /// No setting for any kind: every writable kind writes (no server, tests).
    public static let unrestricted = HealthKitWriteBackPolicy(decisions: [:])

    init(decisions: [MetricKind: Bool]) {
        self.decisions = decisions
    }

    /// The policy the server's resolved entries describe.
    public init(entries: [HealthKitSyncEntry]) {
        var decisions: [MetricKind: Bool] = [:]
        for entry in entries {
            guard let kind = Self.kindByEntryKind[entry.kind] else { continue }
            decisions[kind] = (decisions[kind] ?? false) || Self.entryWritesBack(entry)
        }
        self.init(decisions: decisions)
    }

    /// Whether HealthLog may write a reading of `kind` into Apple Health.
    public func allowsWrite(_ kind: MetricKind) -> Bool {
        decisions[kind] ?? true
    }

    /// The server's rule for one entry (`healthKitWriteBackTypes`).
    static func entryWritesBack(_ entry: HealthKitSyncEntry) -> Bool {
        entry.enabled && (entry.direction == .bidirectional || entry.direction == .writeOnly)
    }

    /// The entry `kind` words (the raw HealthKit names the server uses, see
    /// `HealthKitSyncEntry.kind`) of every kind the app writes into Apple
    /// Health (`HealthKitService.quantitySamples(for:metadata:)`).
    static let kindByEntryKind: [String: MetricKind] = [
        "bodyMass": .weight,
        "bloodPressure": .bloodPressure,
        "bloodGlucose": .glucose,
        "heartRate": .pulse,
        "bodyFatPercentage": .bodyFat,
        "bodyTemperature": .bodyTemperature,
        "oxygenSaturation": .spo2,
        "restingHeartRate": .restingHeartRate,
        "heartRateVariabilitySDNN": .hrv,
        "vo2Max": .vo2Max,
        "bodyMassIndex": .bmi
    ]
}
