import Foundation

/// **GH #47 — a HealthKit `HKUserAnnotatedMedication` projected into a plain,
/// `Sendable` value type.** The HealthKit read path (iOS 26+) maps the opaque
/// HK objects into these records so the importer + its tests never touch
/// HealthKit types directly (the concrete reader is the only HK-aware seam).
///
/// Field mapping (read-only mirror):
/// - ``conceptIdentifier`` ← the stable key derived from HK's
///   `medicationConceptIdentifier` (``AppleHealthConceptKey`` — SHA-256 hex over
///   the securely-archived identifier, 64 chars). This is the mirror's
///   `externalId` and the server's upsert key, so it MUST be identical across
///   process runs; see ``AppleHealthConceptKey`` for what happens when it is not.
/// - ``name`` ← `displayText`.
/// - ``deliveryForm`` ← `generalForm` (normalised to the server enum).
/// - ``rxNormCode`` ← the first RxNorm coding in `relatedCodings`.
/// - ``asNeeded`` ← `scheduleType == .asNeeded`.
/// - ``isArchived`` ← the Health app's archived state.
public struct AppleHealthMedicationRecord: Sendable, Equatable, Hashable {
    public let conceptIdentifier: String
    public let name: String
    public let deliveryForm: String?
    public let rxNormCode: String?
    public let asNeeded: Bool
    public let isArchived: Bool
    /// Optional human-readable strength/dose text if the reader can derive one
    /// (HealthKit does not always carry it). `nil` → the mirror upsert uses a
    /// neutral placeholder, since the server requires a non-empty dose.
    public let doseText: String?

    public init(
        conceptIdentifier: String,
        name: String,
        deliveryForm: String? = nil,
        rxNormCode: String? = nil,
        asNeeded: Bool = false,
        isArchived: Bool = false,
        doseText: String? = nil
    ) {
        self.conceptIdentifier = conceptIdentifier
        self.name = name
        self.deliveryForm = deliveryForm
        self.rxNormCode = rxNormCode
        self.asNeeded = asNeeded
        self.isArchived = isArchived
        self.doseText = doseText
    }

    /// Clamp the HK concept id to the server's `externalId` ceiling (≤128).
    public var externalId: String {
        String(conceptIdentifier.prefix(128))
    }

    public func withDoseText(_ doseText: String?) -> AppleHealthMedicationRecord {
        AppleHealthMedicationRecord(
            conceptIdentifier: conceptIdentifier,
            name: name,
            deliveryForm: deliveryForm,
            rxNormCode: rxNormCode,
            asNeeded: asNeeded,
            isArchived: isArchived,
            doseText: doseText
        )
    }
}

/// The disposition of a HealthKit `HKMedicationDoseEvent` we care about.
/// Only `taken` + `skipped` are imported; every other status (scheduled /
/// snoozed / notInterested / unknown) is deliberately NOT mirrored.
public enum AppleHealthDoseLogStatus: Sendable, Equatable, Hashable {
    case taken
    case skipped
    /// Any other HK log status — not imported.
    case other
}

/// **GH #47 — a HealthKit `HKMedicationDoseEvent` projected into a plain,
/// `Sendable` value type.**
///
/// - ``eventUUID`` ← HK dose-event `UUID` (the bulk-intake `externalId`, ≤128;
///   drives first-write-wins dedup so a re-sync is idempotent).
/// - ``conceptIdentifier`` ← the parent medication's concept id (targets the
///   mirrored med).
/// - ``logStatus`` → `taken`/`skipped`/`other`.
/// - ``takenAt`` ← the administration instant (present for `taken`).
public struct AppleHealthDoseRecord: Sendable, Equatable, Hashable {
    public let eventUUID: String
    public let conceptIdentifier: String
    public let logStatus: AppleHealthDoseLogStatus
    public let scheduledAt: Date
    public let takenAt: Date?
    /// When HealthKit recorded the sample. This is the cursor instant even for
    /// a scheduled dose logged after its nominal reminder time.
    public let recordedAt: Date
    public let doseQuantity: Double?
    public let doseUnit: String?

    public init(
        eventUUID: String,
        conceptIdentifier: String,
        logStatus: AppleHealthDoseLogStatus,
        scheduledAt: Date,
        takenAt: Date? = nil,
        recordedAt: Date? = nil,
        doseQuantity: Double? = nil,
        doseUnit: String? = nil
    ) {
        self.eventUUID = eventUUID
        self.conceptIdentifier = conceptIdentifier
        self.logStatus = logStatus
        self.scheduledAt = scheduledAt
        self.takenAt = takenAt
        self.recordedAt = recordedAt ?? takenAt ?? scheduledAt
        self.doseQuantity = doseQuantity
        self.doseUnit = doseUnit
    }

    /// Clamp the HK dose UUID to the server's `externalId` ceiling (≤128).
    public var externalId: String {
        String(eventUUID.prefix(128))
    }

    /// PRN events intentionally have no scheduled date. Their HealthKit sample
    /// start is the occurrence instant and must not be discarded.
    public static func occurrenceDate(scheduledDate: Date?, sampleStart: Date) -> Date {
        scheduledDate ?? sampleStart
    }

    public static func doseText(quantity: Double?, unit: String?) -> String? {
        guard let quantity, quantity.isFinite, quantity > 0 else { return nil }
        let normalizedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let quantityText = String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), quantity)
        return normalizedUnit.isEmpty ? quantityText : "\(quantityText) \(normalizedUnit)"
    }

    public var doseText: String? {
        Self.doseText(quantity: doseQuantity, unit: doseUnit)
    }
}

/// The HealthKit read dependency the ``AppleHealthMedicationImporter`` needs,
/// expressed as a protocol so it can be driven with synthetic records in tests
/// (over a real ``APIClient`` + `MockURLProtocol`). The concrete iOS 26+
/// implementation lives in `AppleHealthMedicationReader` behind
/// `#available(iOS 26.0, *)` + `#if canImport(HealthKit)`.
public protocol AppleHealthMedicationReading: Sendable {
    /// Whether HealthKit medication reading is available on this OS/device
    /// (iOS 26+ with the Medications data type). `false` short-circuits the
    /// whole importer so no auth prompt fires below the gate.
    var isAvailable: Bool { get }

    /// Request read authorization for the Medications + dose-event types.
    /// Called lazily the moment the opt-in toggle is switched on — never in
    /// the always-on onboarding sheet. Throws on denial / unavailability.
    func requestAuthorization() async throws

    /// The user's current annotated-medication list.
    func readMedications() async throws -> [AppleHealthMedicationRecord]

    /// Dose events recorded since `since` (nil → the full available history on
    /// first sync). Auto-granted with the parent med's per-object auth.
    func readDoseEvents(since: Date?) async throws -> [AppleHealthDoseRecord]
}
