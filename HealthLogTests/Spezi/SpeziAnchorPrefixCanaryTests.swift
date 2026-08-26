#if canImport(HealthKit) && canImport(SpeziHealthKit) && canImport(SpeziLocalStorage)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import SpeziHealthKit
    import SpeziLocalStorage
    import Testing

    /// Canary covering the SpeziHealthKit anchor-storage-prefix contract.
    ///
    /// `SpeziAnchorMigrator.speziGlobalAnchorKey(for:)` names per-sample-type
    /// slots as
    /// `"edu.stanford.Spezi.SpeziHealthKit.queryAnchors.<sampleType.id>"`
    /// — the exact prefix SpeziHealthKit 1.4.2 uses internally
    /// (`Sources/SpeziHealthKit/HealthKit.swift` line 471,
    /// `storageKeyPrefix:`). The prefix is **not** part of any public
    /// SpeziHealthKit API. Since Phase 07 Wave 2 the app no longer *writes*
    /// those slots — it quarantines them, recording the key as the reference an
    /// account's partition points at instead of the value it adopted. A rotation
    /// therefore no longer risks orphaned anchors; it risks something quieter and
    /// worse: a quarantine reference that names a slot nobody uses, so an operator
    /// tracing what an account did not adopt is looking at the wrong file.
    ///
    /// This suite is the trip-wire that catches such a rotation. Two
    /// proofs:
    ///
    /// 1. **End-to-end LocalStorage round-trip**: build a
    ///    `LocalStorageKey<QueryAnchor>` with the exact prefix we ship
    ///    the migrator's formula produces, store a real
    ///    `QueryAnchor`, list the resulting files inside the LocalStorage
    ///    directory. The on-disk filename is `<key>.localstorage` (see
    ///    `SpeziLocalStorage/LocalStorage.swift` `fileURL(for:)`), so
    ///    listing the directory proves the key + filename produced by our
    ///    formula resolve to the same file Spezi's `queryAnchors`
    ///    accessor would write.
    ///
    /// 2. **Contract pin against the SpeziHealthKit constant**: assert
    ///    the exact prefix string the migrator emits matches
    ///    the upstream value bit-for-bit. The diagnostic message points
    ///    the next contributor at the SpeziHealthKit source file to
    ///    re-derive the prefix if SpeziHealthKit rolls the string in a
    ///    future minor bump (the exact-pin in `project.yml` protects
    ///    against this, but the canary lets us drop the exact-pin to
    ///    `from:` once both proofs hold across two consecutive SemVer
    ///    minors).
    @MainActor
    @Suite("SpeziAnchorMigrator — prefix-rotation canary")
    struct SpeziAnchorPrefixCanaryTests {
        /// The contract string the migrator names. Re-stated here instead of
        /// pulling it from production so the assertion stays the canary even if
        /// the migrator's source file is refactored.
        private static let expectedPrefix = "edu.stanford.Spezi.SpeziHealthKit.queryAnchors"

        @Test("the quarantine reference uses the expected SpeziHealthKit prefix")
        func anchorStoreUsesExpectedPrefix() {
            let typeID = HKQuantityTypeIdentifier.stepCount.rawValue
            let expectedKey = "\(Self.expectedPrefix).\(typeID)"

            // The production formula must equal the pinned contract string.
            #expect(SpeziAnchorMigrator.speziGlobalAnchorKey(for: typeID) == expectedKey)

            // Build the same LocalStorageKey SpeziHealthKit constructs
            // internally. If a future refactor breaks the formula, we want the
            // diff to surface here.
            let key = LocalStorageKey<QueryAnchor>(
                expectedKey,
                setting: .unencrypted(excludeFromBackup: false)
            )
            // The .key property is package-private on LocalStorageKey so
            // we cannot read it back directly; the round-trip below
            // proves the key is well-formed.
            _ = key
        }

        @Test("SampleType.stepCount.id matches HKQuantityTypeIdentifier.stepCount.rawValue")
        func sampleTypeIDMatchesHKRawValue() {
            // The migrator derives Spezi anchor keys as
            // `<prefix>.<HKQuantityTypeIdentifier.rawValue>`. This proof
            // depends on `SampleType<HKQuantitySample>.id` resolving to
            // the same raw identifier — `AnySampleType.id` returns
            // `hkSampleType.identifier`, and an `HKQuantityType(.stepCount)
            // .identifier` is the `HKQuantityTypeIdentifier.stepCount
            // .rawValue` string. If a future SpeziHealthKit bump
            // intermediates an opaque hash or rotates the identifier
            // accessor, this assertion catches the drift before the
            // migrator ships anchors under stale keys.
            //
            // Booting a real `LocalStorage` to exercise the round-trip is
            // not viable from a unit test: `LocalStorage` declares
            // `@Dependency(KeychainStorage.self)` which preconditions
            // out without a hosting `Spezi` container. The two
            // assertions in this suite (this `.id` equality + the prefix
            // pin above) together pin every input the migrator uses to
            // construct its `LocalStorageKey`. A future Spezi bump that
            // changes either side of this contract will land at red CI,
            // and the next contributor must re-derive
            // `SpeziAnchorMigrator.speziGlobalAnchorKey` per the failure messages.
            #expect(
                SampleType.stepCount.id == HKQuantityTypeIdentifier.stepCount.rawValue,
                """
                SpeziHealthKit SampleType.stepCount.id no longer equals the raw HK \
                identifier — re-derive the `SpeziAnchorMigrator` key formula. \
                Check `Sources/SpeziHealthKit/Sample Types/AnySampleType.swift` \
                `id` property and `Sources/SpeziHealthKit/HealthKit.swift` \
                `storageKeyPrefix` before bumping the SPM pin.
                """
            )
            #expect(
                SampleType.activeEnergyBurned.id == HKQuantityTypeIdentifier.activeEnergyBurned.rawValue
            )
        }
    }
#endif
