#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **W-HK-RELIABILITY H-2 — honest anchor (de)serialization.**
    ///
    /// The historical importer (de)serializers swallowed every archive failure
    /// with `try?`, so a corrupt stored anchor silently decoded to `nil` and
    /// triggered a full re-sweep storm every wake, undiagnosable. The shared
    /// ``HealthKitAnchorArchive`` now treats a corrupt blob as a deliberate,
    /// logged controlled reset AND purges the unreadable blob so the storm does
    /// not repeat.
    @Suite("HealthKitAnchorArchive — H-2 controlled reset")
    struct HealthKitAnchorArchiveTests {
        /// Fresh, isolated UserDefaults suite per test so the persisted blobs
        /// don't bleed across cases.
        private func makeDefaults(_ name: String) throws -> UserDefaults {
            let suite = "hl.test.anchorarchive.\(name).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }

        @Test("round-trip: a saved anchor loads back equal")
        func roundTrip() throws {
            let defaults = try makeDefaults("roundtrip")
            let key = "anchor.key"
            let anchor = HKQueryAnchor(fromValue: 0)

            HealthKitAnchorArchive.saveAnchor(anchor, forKey: key, to: defaults, label: "test")
            let loaded = try #require(
                HealthKitAnchorArchive.loadAnchor(forKey: key, from: defaults, label: "test")
            )
            #expect(loaded == anchor)
        }

        @Test("no stored blob ⇒ nil (genuine first run, blob stays absent)")
        func firstRunReturnsNil() throws {
            let defaults = try makeDefaults("firstrun")
            let key = "anchor.key"
            #expect(HealthKitAnchorArchive.loadAnchor(forKey: key, from: defaults, label: "test") == nil)
            #expect(defaults.data(forKey: key) == nil)
        }

        @Test("corrupt blob ⇒ controlled reset (nil) AND the corrupt blob is purged")
        func corruptBlobIsControlledResetAndPurged() throws {
            let defaults = try makeDefaults("corrupt")
            let key = "anchor.key"
            // Garbage that is NOT a valid archived HKQueryAnchor.
            defaults.set(Data([0x00, 0x01, 0x02, 0xFF, 0x42]), forKey: key)

            // Controlled reset: returns nil rather than crashing or returning
            // a stale/garbled anchor.
            let loaded = HealthKitAnchorArchive.loadAnchor(forKey: key, from: defaults, label: "test")
            #expect(loaded == nil)

            // The corrupt blob must be purged so the re-sweep storm doesn't
            // recur on every subsequent wake.
            #expect(defaults.data(forKey: key) == nil)
        }

        @Test("after a controlled reset, the next save writes a fresh readable anchor")
        func resetThenSaveRecovers() throws {
            let defaults = try makeDefaults("recover")
            let key = "anchor.key"
            defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: key)

            // Reset clears the corrupt blob.
            #expect(HealthKitAnchorArchive.loadAnchor(forKey: key, from: defaults, label: "test") == nil)

            // A fresh save recovers — the next load returns the new cursor.
            let fresh = HKQueryAnchor(fromValue: 7)
            HealthKitAnchorArchive.saveAnchor(fresh, forKey: key, to: defaults, label: "test")
            let reloaded = try #require(
                HealthKitAnchorArchive.loadAnchor(forKey: key, from: defaults, label: "test")
            )
            #expect(reloaded == fresh)
        }

        @Test("saving a nil anchor is a no-op (leaves any existing value untouched)")
        func saveNilIsNoOp() throws {
            let defaults = try makeDefaults("savenil")
            let key = "anchor.key"
            let existing = HKQueryAnchor(fromValue: 3)
            HealthKitAnchorArchive.saveAnchor(existing, forKey: key, to: defaults, label: "test")

            // nil save must not clobber the persisted anchor.
            HealthKitAnchorArchive.saveAnchor(nil, forKey: key, to: defaults, label: "test")
            let loaded = try #require(
                HealthKitAnchorArchive.loadAnchor(forKey: key, from: defaults, label: "test")
            )
            #expect(loaded == existing)
        }
    }
#endif
