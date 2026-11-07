#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **HK-NEW (1.5) — loop guard for State of Mind.**
    ///
    /// A mood logged in HealthLog is mirrored into Apple Health as a State of
    /// Mind sample. The next sync must not send that sample back up as
    /// `STATE_OF_MIND_VALENCE`, and a foreign sample the mood import already
    /// turned into a mood entry must not be counted a second time as valence.
    /// The server keeps both records apart and never reconciles them
    /// (`correlation-discovery.ts` only puts the valence in the `MOOD` family).
    @Suite("HK-NEW — State of Mind valence loop guard")
    struct StateOfMindValencePolicyTests {
        private static let start = Date(timeIntervalSince1970: 1_790_000_000)

        @Test("round trip: a mood written to Apple Health the way the app writes it never comes back as valence")
        func roundTrip() {
            // Exactly what `HealthKitService.writeMood` saves for a score-4 entry.
            let mirrored = HKStateOfMind(
                date: Self.start,
                kind: .dailyMood,
                valence: MoodStateOfMindMapping.valence(forScore: 4),
                labels: [],
                associations: [],
                // The three keys `HealthKitService.writeMood` stamps since 1.5.
                metadata: [
                    HKMetadataKeyExternalUUID: "mood-entry-1",
                    HKMetadataKeyWasUserEntered: true,
                    HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue
                ]
            )
            // Mood import off, foreign bundle: the app's marker alone decides.
            #expect(StateOfMindValencePolicy.entry(
                for: mirrored,
                appBundleIdentifier: "com.example.another.app",
                moodImportOn: false
            ) == nil)
            // The real converter and the real page gate send nothing for it.
            #expect(HealthKitWireConverter.entries(from: mirrored).isEmpty)
            let page = HealthSampleWireGate(dailyStatsEnabled: true, hrBucketGate: nil).map([mirrored])
            #expect(page.entries.isEmpty)
        }

        @Test("the mood mirror stamps the origin marker the guard reads")
        func writeSiteStampsTheMarker() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent("HealthLog/Services/HealthKitService.swift"), encoding: .utf8)
            #expect(source.contains("HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue"))
        }

        @Test("HealthLog's own HealthKit source passes the bundle check, so its samples never go up, marker or not")
        func ownSource() {
            // A saved sample of this app carries `HKSource.default()`; an unsaved
            // one in a test has no source to read, so the check is pinned on the
            // source itself.
            #expect(StateOfMindValencePolicy.isHealthLogAuthored(
                sourceBundleIdentifier: HKSource.default().bundleIdentifier,
                appBundleIdentifier: Bundle.main.bundleIdentifier,
                originMarker: nil
            ))
        }

        @Test("ownership: the marker, the app's bundle or one of its extensions; an external UUID alone is foreign")
        func ownership() {
            let app = "dev.healthlog.app"
            #expect(StateOfMindValencePolicy.isHealthLogAuthored(
                sourceBundleIdentifier: "com.other", appBundleIdentifier: app, originMarker: "healthlog"
            ))
            #expect(StateOfMindValencePolicy.isHealthLogAuthored(
                sourceBundleIdentifier: app, appBundleIdentifier: app, originMarker: nil
            ))
            #expect(StateOfMindValencePolicy.isHealthLogAuthored(
                sourceBundleIdentifier: app + ".watchkitapp", appBundleIdentifier: app, originMarker: nil
            ))
            #expect(!StateOfMindValencePolicy.isHealthLogAuthored(
                sourceBundleIdentifier: "dev.healthlog.application", appBundleIdentifier: app, originMarker: nil
            ))
            #expect(!StateOfMindValencePolicy.isHealthLogAuthored(
                sourceBundleIdentifier: "com.apple.Health", appBundleIdentifier: app, originMarker: nil
            ))
        }

        @Test("a foreign sample goes up as valence only while the mood import is off")
        func moodImportDecides() {
            #expect(StateOfMindValencePolicy.sendsValence(isHealthLogAuthored: false, moodImportOn: false))
            #expect(!StateOfMindValencePolicy.sendsValence(isHealthLogAuthored: false, moodImportOn: true))
            #expect(!StateOfMindValencePolicy.sendsValence(isHealthLogAuthored: true, moodImportOn: false))
            #expect(!StateOfMindValencePolicy.sendsValence(isHealthLogAuthored: true, moodImportOn: true))

            let foreign = HKStateOfMind(
                date: Self.start,
                kind: .momentaryEmotion,
                valence: 0.25,
                labels: [],
                associations: []
            )
            #expect(StateOfMindValencePolicy.entry(for: foreign, appBundleIdentifier: "x.y", moodImportOn: true) == nil)
            #expect(StateOfMindValencePolicy.entry(for: foreign, appBundleIdentifier: "x.y", moodImportOn: false) != nil)
        }

        @MainActor
        @Test("the policy reads the mood toggle's own preference key")
        func preferenceKey() throws {
            #expect(StateOfMindValencePolicy.moodImportPreferenceKey == MoodHealthSyncStore.prefKey)
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.hknew.mood.\(UUID().uuidString)"))
            #expect(!StateOfMindValencePolicy.moodImportIsOn(defaults: defaults))
            defaults.set(true, forKey: MoodHealthSyncStore.prefKey)
            #expect(StateOfMindValencePolicy.moodImportIsOn(defaults: defaults))
        }
    }
#endif
