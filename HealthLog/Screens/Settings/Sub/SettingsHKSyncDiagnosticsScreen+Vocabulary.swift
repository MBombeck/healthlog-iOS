import Foundation

/// **K1 — words, not identifiers, on the Sync-Diagnose screen.**
///
/// H2 photographed this screen showing Swift enum spellings to the user:
/// „foreground", „healthKitQuery", „failed", „coldActivation". Every internal
/// value the screen renders now passes through one of these functions, and a
/// value none of them knows reads as the neutral „Unbekannt" rather than as
/// the identifier. Pure, so `HKSyncDiagnosticsVocabularyTests`
/// can pin every case without a view.
enum HKSyncDiagnosticsVocabulary {
    /// The heartbeat word `SpeziCollectionTrigger.run` records: either a
    /// `SpeziCollectionTrigger.Source` raw value or, for triggers that have no
    /// member there, the `HealthSyncTrigger` raw value. Persisted as a string,
    /// so an older build's word can come back from `UserDefaults`.
    static func collectionTrigger(_ raw: String) -> String {
        switch raw {
        case "background", "processing":
            String(localized: "settings.hkdiag.value.trigger.background")
        case "appRefresh":
            String(localized: "settings.hkdiag.value.trigger.appRefresh")
        case "foreground":
            String(localized: "settings.hkdiag.value.trigger.foreground")
        case "manual":
            String(localized: "settings.hkdiag.value.trigger.manual")
        case "push", "silentPush":
            String(localized: "settings.hkdiag.value.trigger.push")
        case "coldActivation":
            String(localized: "settings.hkdiag.value.trigger.coldActivation")
        case "postAuthentication":
            String(localized: "settings.hkdiag.value.trigger.postAuthentication")
        case "observer":
            String(localized: "settings.hkdiag.value.trigger.observer")
        case "accountTeardown":
            String(localized: "settings.hkdiag.value.trigger.accountTeardown")
        default:
            unknown
        }
    }

    /// The source of the last direct-workout pass. `nil` = no pass yet.
    static func workoutSource(_ source: WorkoutSyncSource?) -> String {
        guard let source else { return "—" }
        return switch source {
        case .registration: String(localized: "settings.hkdiag.value.trigger.registration")
        case .observer: collectionTrigger("observer")
        case .processing: collectionTrigger("processing")
        case .appRefresh: collectionTrigger("appRefresh")
        case .push: collectionTrigger("push")
        case .foreground: collectionTrigger("foreground")
        case .manual: collectionTrigger("manual")
        }
    }

    static func workoutFailure(_ failure: HKSyncDiagnostics.WorkoutFailureClass) -> String {
        switch failure {
        case .registration: String(localized: "settings.hkdiag.value.failure.registration")
        case .healthKitQuery: String(localized: "settings.hkdiag.value.failure.healthKitQuery")
        case .transport: String(localized: "settings.hkdiag.value.failure.transport")
        case .serverRejected: String(localized: "settings.hkdiag.value.failure.serverRejected")
        case .persistence: String(localized: "settings.hkdiag.value.failure.persistence")
        case .cancelled: String(localized: "settings.hkdiag.value.failure.cancelled")
        case .unknown: String(localized: "settings.hkdiag.value.failure.unknown")
        }
    }

    static func workoutBackfill(_ state: HKSyncDiagnostics.WorkoutBackfillState) -> String {
        switch state {
        case .idle: String(localized: "settings.hkdiag.status_idle")
        case .running: String(localized: "settings.hkdiag.value.backfill.running")
        case .progressed: String(localized: "settings.hkdiag.value.backfill.progressed")
        case .finished: String(localized: "settings.hkdiag.value.backfill.finished")
        case .authorizationPending: String(localized: "settings.hkdiag.value.backfill.authorizationPending")
        case .failed: String(localized: "settings.hkdiag.value.backfill.failed")
        case .serverUnsupported: String(localized: "settings.hkdiag.value.backfill.serverUnsupported")
        }
    }

    /// A server `MeasurementType` from `metricFreshness` („PULSE",
    /// „RESPIRATORY_RATE") as the metric's own name. A type this build has no
    /// metric for keeps its server word: the row is a list entry, and ten rows
    /// all titled „Unbekannt" would say less than the word itself.
    static func freshnessType(_ raw: String) -> String {
        if raw == "BLOOD_PRESSURE_DIA" { return MetricKind.bloodPressure.displayName }
        guard let kind = MetricKind.allCases.first(where: { $0.availabilitySummaryKey == raw }) else {
            return raw
        }
        return kind.displayName
    }

    /// #12 — the gate that decided the heart-rate bucket path's last outcome,
    /// in words, followed by its identifier in parentheses. The identifier is
    /// what a tester quotes back and what Console prints after `gate=`.
    static func heartRateBucketGate(_ gate: HRBucketGate) -> String {
        let words = switch gate {
        case .uploaded: String(localized: "settings.hkdiag.hrbuckets.gate.uploaded")
        case .upToDate: String(localized: "settings.hkdiag.hrbuckets.gate.upToDate")
        case .standalone: String(localized: "settings.hkdiag.hrbuckets.gate.standalone")
        case .noAuthToken: String(localized: "settings.hkdiag.hrbuckets.gate.noAuthToken")
        case .flagOff: String(localized: "settings.hkdiag.hrbuckets.gate.flagOff")
        case .cutoverPending: String(localized: "settings.hkdiag.hrbuckets.gate.cutoverPending")
        case .healthDataLocked: String(localized: "settings.hkdiag.hrbuckets.gate.healthDataLocked")
        case .queryFailed: String(localized: "settings.hkdiag.hrbuckets.gate.queryFailed")
        case .uploadDeferred: String(localized: "settings.hkdiag.hrbuckets.gate.uploadDeferred")
        case .uploadFailed: String(localized: "settings.hkdiag.hrbuckets.gate.uploadFailed")
        case .rawFallbackSweepFailed: String(localized: "settings.hkdiag.hrbuckets.gate.rawFallbackSweepFailed")
        case .rawFallbackSweepStarved: String(localized: "settings.hkdiag.hrbuckets.gate.rawFallbackSweepStarved")
        }
        return "\(words) (\(gate.rawValue))"
    }

    /// The neutral word for a value this build cannot name.
    static var unknown: String {
        String(localized: "settings.hkdiag.verdict_unknown")
    }
}
