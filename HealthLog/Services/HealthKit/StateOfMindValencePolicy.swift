import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// HK-NEW (1.5) — which State of Mind samples go up as `STATE_OF_MIND_VALENCE`.
///
/// **Two ways in, one per sample.** Since v0.10 the mood import
/// (`MoodStateOfMindImporter`, the "Mit Apple Health synchronisieren" toggle)
/// turns every foreign State of Mind sample into a HealthLog mood entry. The
/// server (v1.44) also maps the sample's valence as its own measurement, and
/// it does not reconcile the two: `MoodEntry` and the valence row are separate
/// records, and the only server rule about the overlap is that correlation
/// discovery puts `STATE_OF_MIND_VALENCE` into the `MOOD` family
/// (`correlation-discovery.ts` `metricFamily`, "pairing it with the logged mood
/// would correlate one feeling with itself"). It never forms a mood from a
/// valence row, and it never drops one for the other. Sending both would
/// therefore count the same feeling twice, once in the mood log and once as a
/// measurement. So the rule is:
///
/// * a sample HealthLog wrote itself (its own source, or the app's metadata)
///   never goes up as valence: that is the mood the person logged in the app,
///   already on the server as a mood entry, coming back from Apple Health;
/// * while the mood import is on, a foreign sample becomes a mood entry as
///   before, and is not sent as valence;
/// * while the mood import is off, a foreign sample goes up as valence and
///   nowhere else.
///
/// The anchored collector consumes every sample either way, so a sample that
/// went one way is never offered the other way later.
enum StateOfMindValencePolicy {
    /// The mood toggle's preference key (`MoodHealthSyncStore.prefKey`, pinned
    /// equal by a test). Per installation, `UserDefaults.standard`.
    static let moodImportPreferenceKey = "hl.mood.syncWithAppleHealth"

    /// `true` when the sample was written by HealthLog: the app's private origin
    /// marker, or a source bundle that is this app or one of its extensions
    /// (the watch app included). An external UUID alone proves nothing: other
    /// apps may set one.
    static func isHealthLogAuthored(
        sourceBundleIdentifier: String?,
        appBundleIdentifier: String?,
        originMarker: String?
    ) -> Bool {
        if originMarker == HealthKitSampleOwnership.appOriginMetadataValue { return true }
        guard let source = sourceBundleIdentifier, let app = appBundleIdentifier, !app.isEmpty else { return false }
        return source == app || source.hasPrefix(app + ".")
    }

    /// The whole rule as a pure function.
    static func sendsValence(isHealthLogAuthored: Bool, moodImportOn: Bool) -> Bool {
        !isHealthLogAuthored && !moodImportOn
    }

    static func moodImportIsOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: moodImportPreferenceKey)
    }

    #if canImport(HealthKit)
        /// The batch row for one State of Mind sample, or `nil` when the rule
        /// keeps it back. Valence is HealthKit's −1…1 as is; the server stores
        /// it unscaled and refuses anything outside the closed range.
        static func entry(
            for sample: HKStateOfMind,
            appBundleIdentifier: String? = Bundle.main.bundleIdentifier,
            moodImportOn: Bool = moodImportIsOn()
        ) -> HealthKitBatchEntryDTO? {
            let authored = isHealthLogAuthored(
                sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                appBundleIdentifier: appBundleIdentifier,
                originMarker: sample.metadata?[HealthKitSampleOwnership.appOriginMetadataKey] as? String
            )
            guard sendsValence(isHealthLogAuthored: authored, moodImportOn: moodImportOn) else { return nil }
            return HealthKitBatchEntryDTO(
                hkIdentifier: HealthKitServer144Types.stateOfMindWireIdentifier,
                value: sample.valence,
                unit: "valence",
                startDate: sample.startDate,
                endDate: sample.endDate,
                externalId: sample.uuid.uuidString,
                externalSourceVersion: sample.sourceRevision.productType,
                deviceType: HealthKitWireConverter.deviceType(for: sample.device)
            )
        }
    #endif
}
