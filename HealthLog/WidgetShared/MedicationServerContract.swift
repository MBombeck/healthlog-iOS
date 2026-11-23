import Foundation

// **Server 1.49.0 medication contract (#188, #189, #191) — capabilities.**
//
// Foundation-only and shared by the app, the widget extension and the
// Notification Service Extension. The server gates on capability keys only,
// never on version numbers (#190 §5, #191): `GET /api/version` carries a
// public `features: string[]`. A key is present or absent; unknown keys are
// ignored; a server without `features` is older than 1.49.0. Every 1.49.0
// behaviour of the medication contract opens on its key and on nothing else.

/// The medication keys of `GET /api/version` `features`, as #191 fixes them.
public enum MedicationCapability: String, CaseIterable, Sendable {
    /// `MEDICATION_INTAKE_RECORDED` is sent (every writer, bulk included).
    case intakeRecordedPush = "medication.intake-recorded-push"
    /// `alreadyTaken` and `takenVia` on the single and ingest routes, and
    /// `takenVia` on today rows.
    case alreadyTaken = "medication.already-taken"
    /// The bulk route's per-entry `alreadyTaken` (`intake`, `takenAt`,
    /// `takenVia`). The app then skips its own re-read before a take.
    case bulkAlreadyTaken = "medication.bulk-already-taken"
    /// `expectedSyncVersion` / `expectedIdempotencyKey` on the intake DELETE
    /// and `409 medications.intake.changedSinceSeen`.
    case undoPrecondition = "medication.undo-precondition"
    /// `medications.lastUpdatedAt` in `/api/sync/state`.
    case medicationsLastUpdated = "sync.medications-last-updated"
    /// `liveActivityTokens` on `POST /api/devices`, one end push per Activity.
    case liveActivityTokensPerActivity = "medication.live-activity-tokens"
    /// The resolved dose `state` on today rows.
    case doseState = "medication.dose-state"
    /// The per-user snooze span (`snoozeMinutes`, default 30).
    case snoozeSetting = "medication.snooze-setting"
    /// `syncVersion` on every today row, on each bulk `entries[].intake` and
    /// on the full rows the single, status and ingest routes answer.
    case intakeSyncVersion = "medication.intake-sync-version"
    /// `complianceDisplay.currentDose` names the earliest open slot (due or
    /// overdue) before any upcoming one.
    case currentDoseOpenSlot = "medication.current-dose-open-slot"
}

/// Where the reported keys are kept: the App Group, because the extension
/// and the widget cannot ask the server. A capability fact about the host, not
/// health data. Unknown (never probed, or forgotten on a server change) is
/// closed.
public enum MedicationCapabilities {
    static let defaultsKey = "hl.server.medicationCapabilities"
    /// The 1.7 pre-contract gate (`serverConfirmsIntakes`, opened by server
    /// version). Removed on the first record so an update cannot keep it open.
    static let legacyVersionGateKey = "hl.medications.serverConfirmsIntakes"

    /// ``WidgetAppGroup/identifier``, spelled out because this file is also
    /// part of the platform-free `HealthLogCore` package, which does not
    /// compile `WidgetShared/` (same lock-step constant as `OutboxStore`).
    static let appGroupIdentifier = "group.dev.healthlog.app"

    public static var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    /// Replaces the remembered set with what `/api/version` `features` said.
    /// An answer without `features` (an older server) records the empty set.
    public static func record(_ flags: Set<MedicationCapability>, defaults: UserDefaults? = appGroupDefaults) {
        defaults?.set(flags.map(\.rawValue).sorted(), forKey: defaultsKey)
        defaults?.removeObject(forKey: legacyVersionGateKey)
    }

    public static func forget(defaults: UserDefaults? = appGroupDefaults) {
        defaults?.removeObject(forKey: defaultsKey)
        defaults?.removeObject(forKey: legacyVersionGateKey)
    }

    public static func isOpen(_ capability: MedicationCapability, defaults: UserDefaults? = appGroupDefaults) -> Bool {
        let raw = defaults?.stringArray(forKey: defaultsKey) ?? []
        return raw.contains(capability.rawValue)
    }

    /// The medication keys in a `features` list. Unknown keys are ignored.
    public static func flags(inFeatures features: [String]) -> Set<MedicationCapability> {
        Set(features.compactMap(MedicationCapability.init(rawValue:)))
    }
}

/// `takenVia` on today rows, on `alreadyTaken` answers and in the
/// `MEDICATION_INTAKE_RECORDED` payload (#191, final): who recorded the take.
/// An unknown value reads as ``other`` ("another device").
public enum MedicationTakenVia: Sendable, Equatable {
    case web
    /// The iOS app (`APP`; rows written before 1.49.0 may say `IOS`).
    case app
    /// Pill box and `/api/ingest/medication`.
    case integration
    case telegram
    case appleHealth
    case importer
    case auto
    case other

    public init?(wire: String?) {
        guard let wire, !wire.isEmpty else { return nil }
        switch wire.uppercased() {
        case "WEB": self = .web
        case "APP", "IOS": self = .app
        case "INTEGRATION": self = .integration
        case "TELEGRAM": self = .telegram
        case "APPLE_HEALTH": self = .appleHealth
        case "IMPORT": self = .importer
        case "AUTO": self = .auto
        default: self = .other
        }
    }
}

/// The outcome of a dose a `MEDICATION_INTAKE_RECORDED` push confirms.
public enum MedicationIntakeOutcome: String, Codable, Sendable {
    case taken
    case skipped
}
