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
    ///
    /// U1 (#18) — the lookup ignores case and separators, so `heart_rate`,
    /// `heart-rate` and `HEART_RATE` are one key. `WORKOUTS` (the server's
    /// pseudo-type from `Workout` rows, `metric-freshness.ts`) has its own word.
    /// The fallback is no longer the raw identifier but a sentence-cased one
    /// („HEART_RATE" → „Heart rate"), so no row shouts or shows underscores.
    static func freshnessType(_ raw: String) -> String {
        let key = normalizedTypeKey(raw)
        switch key {
        case "WORKOUTS", "WORKOUT": return String(localized: "settings.hkdiag.freshness.workouts")
        case "BLOOD_PRESSURE_DIA": return MetricKind.bloodPressure.displayName
        default: break
        }
        guard let kind = MetricKind.allCases.first(where: { $0.availabilitySummaryKey == key }) else {
            return prettifiedTypeKey(key)
        }
        return kind.displayName
    }

    /// Upper case, every run of non-alphanumerics one underscore.
    static func normalizedTypeKey(_ raw: String) -> String {
        raw.uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "_")
    }

    /// „HEART_RATE" → „Heart rate". Empty input reads as „Unbekannt".
    static func prettifiedTypeKey(_ key: String) -> String {
        let words = key.split(separator: "_").map { $0.lowercased() }
        guard let first = words.first else { return unknown }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// U1 (#18) — the workout counters as a sentence: „710 gelesen,
    /// 710 gesendet, 710 angenommen, 0 abgelehnt". Workouts HealthKit handed
    /// over that could not be mapped are named only when there are any; the
    /// old „F · M · S · A · X" line needed a code comment to be read.
    static func workoutCounts(_ snapshot: HKSyncDiagnostics.WorkoutSnapshot) -> String {
        let read = snapshot.fetchedTotal
        let sent = snapshot.sentTotal
        let accepted = snapshot.acceptedTotal
        let rejected = snapshot.skippedTotal
        let sentence = String(localized: "settings.hkdiag.workout_counts \(read) \(sent) \(accepted) \(rejected)")
        let unmapped = snapshot.fetchedTotal - snapshot.mappedTotal
        guard unmapped > 0 else { return sentence }
        return sentence + String(localized: "settings.hkdiag.workout_counts_unmapped \(unmapped)")
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
