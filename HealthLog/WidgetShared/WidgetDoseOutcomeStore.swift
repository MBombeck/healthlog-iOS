import Foundation

/// The last "Taken" outcome a widget button or the next-dose control saw,
/// shared through the App Group.
///
/// Only the app writes the widget snapshot, so after a confirmed tap the
/// widget kept showing the same dose as open until the app next ran. A second
/// and third tap followed. This marker lets the widget show what the tap did
/// (saved, queued or not saved) until the app has written a newer snapshot,
/// which then carries the server's answer. Carries the medication id and the
/// slot instant only, no name.
public struct WidgetDoseOutcomeStore: Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The server confirmed the intake.
        case recorded
        /// The intake sits in the outbox and syncs later.
        case queued
        /// Nothing was saved (signed out or a non-retriable failure).
        case notSaved

        /// The tap took care of the dose, so it is no longer open. A dose
        /// that was not saved still is.
        public var settlesDose: Bool {
            self == .recorded || self == .queued
        }
    }

    public struct Outcome: Codable, Sendable, Equatable {
        public let medicationId: String
        public let scheduledAt: Date
        public let kind: Kind
        public let at: Date

        public init(medicationId: String, scheduledAt: Date, kind: Kind, at: Date) {
            self.medicationId = medicationId
            self.scheduledAt = scheduledAt
            self.kind = kind
            self.at = at
        }
    }

    /// How long a "not saved" note stays next to the button. Long enough to
    /// be read, short enough that it does not outlive its cause.
    public static let notSavedWindow: TimeInterval = 10 * 60

    /// Upper bound for any outcome: the widget's own next-dose staleness.
    public static let maxAge: TimeInterval = 16 * 60 * 60

    private let url: URL?

    public init(url: URL? = WidgetAppGroup.doseOutcomeURL()) {
        self.url = url
    }

    public func record(
        medicationId: String,
        scheduledFor: Date,
        kind: Kind,
        now: Date = .now
    ) {
        guard let url else { return }
        let outcome = Outcome(medicationId: medicationId, scheduledAt: scheduledFor, kind: kind, at: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(outcome) else { return }
        // Same protection as the pending-confirm marker: readable by the widget
        // after first unlock, encrypted before it.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? SensitiveDataBackupExclusion.secureCreatedItem(at: url)
    }

    public func read() -> Outcome? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Outcome.self, from: data)
    }

    public func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The outcome that applies to the dose a snapshot shows, if any.
    public func kind(
        for dose: WidgetSnapshot.NextDose?,
        snapshotGeneratedAt: Date,
        now: Date = .now
    ) -> Kind? {
        Self.applicableKind(read(), to: dose, snapshotGeneratedAt: snapshotGeneratedAt, now: now)
    }

    /// Pure rule. An outcome applies to exactly its medication and slot, only
    /// while the snapshot predates it (a newer snapshot is the app's answer
    /// and wins), and only within its window.
    public static func applicableKind(
        _ outcome: Outcome?,
        to dose: WidgetSnapshot.NextDose?,
        snapshotGeneratedAt: Date,
        now: Date
    ) -> Kind? {
        guard let outcome, let dose else { return nil }
        guard outcome.medicationId == dose.medicationId,
              abs(outcome.scheduledAt.timeIntervalSince(dose.scheduledAt)) < 1 else { return nil }
        guard outcome.at > snapshotGeneratedAt else { return nil }
        let age = now.timeIntervalSince(outcome.at)
        guard age >= 0, age <= maxAge else { return nil }
        if outcome.kind == .notSaved, age > notSavedWindow { return nil }
        return outcome.kind
    }

    /// The outcome kind for a commit: a landed write is recorded, a durably
    /// queued one is queued, everything else saved nothing.
    public static func kind(signedIn: Bool, error: Error?) -> Kind {
        guard signedIn else { return .notSaved }
        guard let error else { return .recorded }
        // #189 (6): taken already, elsewhere — the dose is settled.
        if error is MedicationAlreadyTaken { return .recorded }
        if let hlError = error as? HLError, hlError.shouldPersistToOutbox { return .queued }
        return .notSaved
    }
}
