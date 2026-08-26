import Foundation

/// Initial-Backfill-Window fuer den ersten HK-Sync nach Onboarding. Steuert,
/// wie weit der erste HK-Sync pro Type in die Vergangenheit reicht.
///
/// **Default `.allTime` (v0.10.0, operator-decided):** der Operator will, dass
/// neue User per Default ihre komplette HK-History bekommen — keine still
/// abgeschnittenen Jahre. Der frueheres 30-Tage-Default (Perf-Tradeoff gegen
/// "Power-User mit 10 Jahren History pumpt 100k+ Samples beim ersten Wakeup")
/// ist damit umgedreht: First-Sync kann fuer Langzeit-Histories laenger +
/// schwerer sein. Das ist akzeptiert, weil der Initial-Backfill garantiert im
/// Hintergrund laeuft (`BGProcessingTask` — siehe `HealthKitService.activate
/// Background`), also das Onboarding nicht blockiert, und der Server idempotent
/// dedupliziert (`HKMetadataKeyExternalUUID` / Unique-Indizes). Der Picker
/// laesst dem User weiterhin die Wahl eines kuerzeren Fensters.
///
/// **Lifetime-Contract:** Das Window beeinflusst NUR den ersten Sync per Type
/// (kein Anchor → cutoff-Predicate). Sobald der erste Anchor persistiert ist,
/// uebernimmt der Anchor und das Window wird ignoriert. Der User sieht alle
/// neuen Samples ab Onboarding-Zeitpunkt + alle Samples bis zur Window-Cutoff
/// in der Vergangenheit.
///
/// **Persistierung:** Per-User in UserDefaults
/// (`hl.healthkit.backfillWindow.<userId>`). Re-Install mit restored Keychain
/// → fresh onboarding → neue Wahl. Bewusst kein Re-Use: ein Re-Install ist eine
/// gute Stelle, dem User die Wahl nochmal zu geben (vielleicht hat er beim
/// ersten Mal "Alle" gepickt und bereut es).
public enum HealthKitBackfillWindow: String, Codable, Sendable, CaseIterable, Equatable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case oneYear
    case allTime

    /// Default: `.allTime` (v0.10.0, operator-decided — siehe Type-Doc oben).
    /// Neue User bekommen ihre komplette HK-History; der Backfill laeuft im
    /// `BGProcessingTask`-Hintergrund und der Server dedupliziert idempotent.
    public static let `default`: HealthKitBackfillWindow = .allTime

    /// Lower-Bound-Date fuer den HK-Sample-Predicate. `.allTime` gibt
    /// `.distantPast` zurueck — HKQuery interpretiert das als "kein lower bound".
    /// Caller verwendet das als `HKQuery.predicateForSamples(withStart: ..., end: nil)`.
    public func lowerBound(now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .sevenDays:
            calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .thirtyDays:
            calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .ninetyDays:
            calendar.date(byAdding: .day, value: -90, to: now) ?? now
        case .oneYear:
            calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .allTime:
            .distantPast
        }
    }

    /// Reihenfolge fuer Picker-UI: kuerzeste zuerst, default in der Mitte
    /// (psychologisch: Default = Standard-Wahl, kuerzeres = "weniger ist mir
    /// lieber", laengeres = "ich will alles").
    public static let pickerOrder: [HealthKitBackfillWindow] = [
        .sevenDays,
        .thirtyDays,
        .ninetyDays,
        .oneYear,
        .allTime
    ]
}
