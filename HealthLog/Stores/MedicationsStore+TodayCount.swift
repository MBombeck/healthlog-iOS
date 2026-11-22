import Foundation

/// **1.7 — today's doses, counted from the confirmed today rows.**
///
/// The Home ring ("1/3, 2 still open"), the hero's medication fact and the
/// medication hints of the daily digest used to read the dashboard summary
/// and the digest, both server answers of their own age. They now count the
/// same rows the medication card shows, and only once the store has
/// confirmed them (``DoseStateConfirmation``); until then the surfaces stay
/// neutral, exactly like the card.
public struct MedicationTodayCount: Equatable, Sendable {
    public let scheduled: Int
    public let taken: Int
    /// Neither taken nor skipped.
    public let open: Int
    /// The medications with a dose still open today.
    public let openMedicationIds: Set<String>

    /// Pure: counts `intakes` without the medications kept as a record.
    public static func from(intakes: [MedicationIntake], medications: [Medication]) -> MedicationTodayCount {
        let rows = MedicationIntake.excludingUntrackedMedications(intakes, medications: medications)
        let open = rows.filter { $0.status != .taken && $0.status != .skipped }
        return MedicationTodayCount(
            scheduled: rows.count,
            taken: rows.count(where: { $0.status == .taken }),
            open: open.count,
            openMedicationIds: Set(open.map(\.medicationId))
        )
    }

    /// The ring's snapshot, in the summary's shape.
    public var snapshot: ComplianceSnapshot {
        ComplianceSnapshot(scheduledToday: scheduled, takenToday: taken)
    }
}

/// What the Home surfaces may say about today's doses.
public enum MedicationTodayState: Equatable, Sendable {
    /// Nothing loaded yet: the server's own figures stand (a cold start has
    /// just fetched them).
    case unknown
    /// Loaded but not confirmed: neutral.
    case unconfirmed(scheduled: Int)
    /// Confirmed rows.
    case confirmed(MedicationTodayCount)
}

public extension MedicationsStore {
    /// The today state the Home ring, the hero fact, the digest hints and the
    /// intake sheet read.
    var todayState: MedicationTodayState {
        let rows = derivedTodayIntakes
        guard hasLoadedMedications || !rows.isEmpty else { return .unknown }
        let count = MedicationTodayCount.from(intakes: rows, medications: medications)
        if isDoseStateUnconfirmed { return .unconfirmed(scheduled: count.scheduled) }
        guard doseConfirmation.asOf != nil else { return .unknown }
        return .confirmed(count)
    }
}

/// **1.7 — the digest's medication hints against the confirmed rows.**
public enum MedicationDigestFilter {
    /// Whether `item` speaks about a dose to take (`dose.log`, or a hint the
    /// medications module admitted that leads to the intake surface).
    static func isDoseHint(_ item: DailyPriorityItem) -> Bool {
        item.actions.contains { $0.intent == "dose.log" }
    }

    /// The medication a hint names (`/medications?highlight=<id>`), if any.
    static func medicationId(of item: DailyPriorityItem) -> String? {
        for action in item.actions {
            guard let href = action.href, let components = URLComponents(string: href) else { continue }
            if let id = components.queryItems?.first(where: { $0.name == "highlight" })?.value, !id.isEmpty { return id }
        }
        return nil
    }

    /// Pure: the hints Home shows. While the rows are unconfirmed no dose
    /// hint; once confirmed, only a hint whose dose is still open.
    public static func visible(_ items: [DailyPriorityItem], state: MedicationTodayState) -> [DailyPriorityItem] {
        items.filter { item in
            guard isDoseHint(item) else { return true }
            switch state {
            case .unknown:
                return true
            case .unconfirmed:
                return false
            case let .confirmed(count):
                if let id = medicationId(of: item) { return count.openMedicationIds.contains(id) }
                return count.open > 0
            }
        }
    }

    /// Pure: the hero's medication fact value. Confirmed rows give "2 of 3
    /// taken"; unconfirmed, the day's dose count only; unknown keeps the
    /// server's words.
    public static func factValue(server: String, state: MedicationTodayState) -> String {
        switch state {
        case .unknown:
            server
        case let .unconfirmed(scheduled):
            scheduled > 0 ? String(localized: "dashboard.compliance.dosesToday \(scheduled)") : server
        case let .confirmed(count):
            count.scheduled > 0
                ? String(format: String(localized: "med.compliance.caption.taken"), count.taken, count.scheduled)
                : server
        }
    }

    /// Whether a hero fact is the medication fact.
    static func isMedicationFact(_ fact: DailyDigest.TodayFact) -> Bool {
        fact.kind == "medication" || fact.kind == "medications" || fact.moduleKey == "medications"
    }
}
