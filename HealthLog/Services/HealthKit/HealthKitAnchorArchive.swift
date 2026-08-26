import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **W-HK-RELIABILITY H-2 — honest anchor (de)serialization.**
    ///
    /// Four HK importers (`WorkoutHealthKitImporter`, `MoodStateOfMindImporter`,
    /// `CycleHealthKitImporter`, `HeartHealthEventImporter`) each persist an
    /// `HKQueryAnchor` in UserDefaults (battery rationale — see PROJECT_GUIDE.md). The
    /// historical (de)serializers swallowed every archive failure with `try?`:
    ///
    ///   - A **decode** failure (garbled / format-drifted blob) returned `nil`
    ///     silently, which HealthKit interprets as "no anchor" → the next sweep
    ///     re-reads **everything** from the dawn of the store (a re-sweep storm),
    ///     and the user has no log line explaining why.
    ///   - An **encode** failure dropped the new anchor on the floor, so the
    ///     importer keeps re-reading the same window every wake forever.
    ///
    /// This helper centralizes both directions and surfaces the failure honestly
    /// via `HLLog` (no PHI — an `HKQueryAnchor` is an opaque cursor, the only
    /// logged context is the typed reason + the operator-grade label). A corrupt
    /// stored anchor is treated as a **deliberate, logged controlled reset**
    /// (return `nil` = start from the current stream position) rather than a
    /// silent swallow — and the corrupt blob is removed so the failure does not
    /// repeat every wake. Never crashes.
    enum HealthKitAnchorArchive {
        /// Load + decode an anchor blob from `defaults[key]`.
        ///
        /// - Returns: the decoded anchor, or `nil` when no blob is stored
        ///   (genuine first run) **or** when the stored blob fails to decode
        ///   (controlled reset — logged + the corrupt blob is purged so the
        ///   next save can write a fresh cursor and the storm doesn't recur).
        static func loadAnchor(
            forKey key: String,
            from defaults: UserDefaults,
            label: String
        ) -> HKQueryAnchor? {
            guard let data = defaults.data(forKey: key) else {
                return nil // genuine first run — no anchor persisted yet
            }
            do {
                // A correctly-archived anchor is never empty; an empty/garbled
                // blob throws or returns nil → both routed to the reset path.
                guard let anchor = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: HKQueryAnchor.self,
                    from: data
                ) else {
                    purgeCorruptAnchor(forKey: key, from: defaults, label: label, reason: "decoded to nil")
                    return nil
                }
                return anchor
            } catch {
                purgeCorruptAnchor(
                    forKey: key,
                    from: defaults,
                    label: label,
                    reason: error.localizedDescription
                )
                return nil
            }
        }

        /// Encode + persist an anchor blob to `defaults[key]`. A `nil` anchor is
        /// a no-op (nothing to persist yet). An encode failure is surfaced — it
        /// means the importer will keep re-reading the same window until the
        /// next successful save, which the operator must be able to see.
        static func saveAnchor(
            _ anchor: HKQueryAnchor?,
            forKey key: String,
            to defaults: UserDefaults,
            label: String
        ) {
            guard let anchor else { return }
            do {
                let data = try NSKeyedArchiver.archivedData(
                    withRootObject: anchor,
                    requiringSecureCoding: true
                )
                defaults.set(data, forKey: key)
            } catch {
                // No PHI — `label` is an operator-grade type tag, the reason is
                // the Foundation archiver error (an opaque cursor never carries
                // health data). Surfaced so a persistent re-read loop is
                // diagnosable instead of silently swallowed.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.error(
                    "HK anchor encode failed [\(label, privacy: .public)] — anchor NOT persisted, will re-read window next wake: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        /// Decode an anchor blob that the caller already holds (the ECG path
        /// persists its cursor through the platform-free
        /// ``EcgRecordingSource`` seam, so the blob arrives as `Data` rather
        /// than from `UserDefaults`). Same honest posture as
        /// ``loadAnchor(forKey:from:label:)``: an unreadable blob is a logged,
        /// controlled reset to "read from the beginning", never a crash and
        /// never a silent swallow.
        static func decodeAnchor(_ data: Data?, label: String) -> HKQueryAnchor? {
            guard let data else { return nil }
            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
            } catch {
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.error(
                    "HK anchor decode failed [\(label, privacy: .public)] — controlled reset: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        /// Encode an anchor to a blob the caller persists itself. `nil` in →
        /// `nil` out; an encode failure is logged and yields `nil`, which the
        /// ECG coordinator reads as "do not advance the cursor".
        static func encodeAnchor(_ anchor: HKQueryAnchor?, label: String) -> Data? {
            guard let anchor else { return nil }
            do {
                return try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
            } catch {
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.error(
                    "HK anchor encode failed [\(label, privacy: .public)] — cursor NOT advanced: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        /// Log the controlled reset + purge the unreadable blob so the storm
        /// does not repeat on every subsequent wake (the next successful sweep
        /// writes a fresh cursor).
        private static func purgeCorruptAnchor(
            forKey key: String,
            from defaults: UserDefaults,
            label: String,
            reason: String
        ) {
            defaults.removeObject(forKey: key)
            // No PHI — operator-grade type tag + Foundation archiver reason.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.error(
                "HK anchor decode failed [\(label, privacy: .public)] — controlled reset (re-reading from current stream position), corrupt blob purged: \(reason, privacy: .public)"
            )
        }
    }

#endif
