#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **W-HK-RELIABILITY G-7 — foreign-filter ownership.**
    ///
    /// The HK read foreign-filter must skip ONLY samples that are OURS (carry
    /// our `HKMetadataKeyExternalUUID` AND are authored by this app's own HK
    /// source), so:
    ///   - our own round-trip / mirror writes still don't echo back to the
    ///     server (anti-echo guarantee intact), and
    ///   - a legitimate third-party sample that happens to carry an
    ///     externalUUID flows in instead of being silently dropped.
    ///
    /// The pure predicate covers the four-quadrant truth table without needing
    /// a forged foreign-source `HKSample` (HealthKit does not let a test set
    /// another app's source revision). A complementary concrete-sample test
    /// pins the in-process case (a directly-constructed sample's source is this
    /// app's own `HKSource.default()`).
    @Suite("HealthKitSampleOwnership — G-7 foreign-filter ownership")
    struct HealthKitSampleOwnershipTests {
        // MARK: - Pure predicate (four quadrants)

        @Test("our UUID + from this app ⇒ own echo (skip) — anti-echo guarantee")
        func ownUUIDFromThisAppIsEcho() {
            #expect(HealthKitSampleOwnership.isOwnEcho(externalUUID: "abc-123", isFromThisApp: true))
        }

        @Test("our UUID but FOREIGN source ⇒ NOT echo (import third-party data)")
        func uuidFromForeignSourceIsImported() {
            // The G-7 fix: a third-party sample carrying an externalUUID is no
            // longer silently dropped — different source ⇒ flows in.
            #expect(!HealthKitSampleOwnership.isOwnEcho(externalUUID: "abc-123", isFromThisApp: false))
        }

        @Test("no UUID + foreign source ⇒ NOT echo (ordinary third-party sample)")
        func noUUIDForeignIsImported() {
            #expect(!HealthKitSampleOwnership.isOwnEcho(externalUUID: nil, isFromThisApp: false))
        }

        @Test("no UUID + from this app ⇒ NOT echo (defensive: we always set the UUID)")
        func noUUIDFromThisAppIsImported() {
            #expect(!HealthKitSampleOwnership.isOwnEcho(externalUUID: nil, isFromThisApp: true))
        }

        @Test("empty UUID string is treated as absent (not an echo)")
        func emptyUUIDIsNotEcho() {
            #expect(!HealthKitSampleOwnership.isOwnEcho(externalUUID: "", isFromThisApp: true))
        }

        // MARK: - Concrete sample (convenience over `HKSample`)

        // Note on the source signal: an *unsaved*, directly-constructed
        // `HKSample` does NOT report `HKSource.default()` as its authoring
        // source in a unit-test process — HealthKit only stamps the owning
        // source when a store *saves* the sample. So the test process cannot
        // forge either an own-source or a foreign-source sample; the
        // four-quadrant truth above (the pure predicate) is the real signal for
        // the source dimension. The concrete tests below pin the deterministic
        // dimension — the metadata (external-UUID) read — which the convenience
        // must wire correctly so the `guard` short-circuits a no-UUID sample
        // before the source is ever consulted.

        private func makeSample(externalUUID: String?) -> HKQuantitySample {
            var metadata: [String: Any] = [:]
            if let externalUUID {
                metadata[HKMetadataKeyExternalUUID] = externalUUID
            }
            let now = Date()
            return HKQuantitySample(
                type: HKQuantityType(.stepCount),
                quantity: HKQuantity(unit: .count(), doubleValue: 100),
                start: now.addingTimeInterval(-60),
                end: now,
                metadata: metadata.isEmpty ? nil : metadata
            )
        }

        @Test("concrete sample WITHOUT a UUID is never an echo (would import) — metadata short-circuit")
        func inProcessSampleWithoutUUIDIsNotEcho() {
            // No external UUID ⇒ the predicate's `guard` returns false BEFORE
            // touching the source, so this is deterministic regardless of the
            // sample's (unstamped) source. Proves the convenience reads the
            // metadata key, not merely the source.
            let foreignShaped = makeSample(externalUUID: nil)
            #expect(!HealthKitSampleOwnership.isOwnEcho(foreignShaped))
        }

        @Test("concrete sample WITH a UUID resolves the source dimension (anti-echo iff our source)")
        func inProcessSampleWithUUIDDefersToSource() {
            // A UUID-carrying sample's verdict is exactly the source match — the
            // convenience reads metadata + source and hands both to the pure
            // predicate. We assert the convenience agrees with the pure
            // predicate evaluated against the SAME source signal, so the wiring
            // (not a forged source) is what's under test.
            let sample = makeSample(externalUUID: "mine-1")
            let isFromThisApp = sample.sourceRevision.source == HKSource.default()
            #expect(
                HealthKitSampleOwnership.isOwnEcho(sample)
                    == HealthKitSampleOwnership.isOwnEcho(externalUUID: "mine-1", isFromThisApp: isFromThisApp)
            )
        }

        // MARK: - Deletion path

        // The deletion-path predicate that lived here (`isAppMintedDeletion`)
        // read our external UUID and origin marker from a deleted object, which
        // keeps neither. A6 (1.4) reads the sync identifier instead; its tests
        // are in `HealthKitMirrorTombstoneTests`.
    }
#endif
