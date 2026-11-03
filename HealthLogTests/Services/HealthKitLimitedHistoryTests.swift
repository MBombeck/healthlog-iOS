#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import os
    import Testing

    /// **1.4 / iOS 27 — limited Health history.**
    ///
    /// A person can grant a recent window instead of the whole history. Apple:
    /// "Treat all data before that date as unknown, not an absence of data."
    /// These pin the window vocabulary, the runtime call that asks HealthKit
    /// for it (the iOS 26 SDK has no symbol for it), and the server→Health
    /// mirror, which must not write rows it can no longer see a second time.
    @Suite("Limited Health history (iOS 27)")
    struct HealthKitLimitedHistoryTests {
        private static let boundary = Date(timeIntervalSince1970: 1_790_000_000)

        // MARK: - The window

        @Test("an unlimited window proves every absence, a limited one only after its boundary")
        func windowJudgesAbsence() {
            let before = Self.boundary.addingTimeInterval(-60)
            let after = Self.boundary.addingTimeInterval(60)
            #expect(!HealthReadWindow.unlimited.hidesAbsence(endingAt: before))
            #expect(HealthReadWindow.limited(from: Self.boundary).hidesAbsence(endingAt: before))
            #expect(!HealthReadWindow.limited(from: Self.boundary).hidesAbsence(endingAt: after))
            // HealthKit compares the END date: a sample ending on the boundary is readable.
            #expect(!HealthReadWindow.limited(from: Self.boundary).hidesAbsence(endingAt: Self.boundary))
            #expect(HealthReadWindow.unknown.hidesAbsence(endingAt: after))
        }

        @Test("a read starts no earlier than a limited window")
        func clampUsesTheLaterStart() {
            let early = Self.boundary.addingTimeInterval(-86400)
            let late = Self.boundary.addingTimeInterval(86400)
            let limited = HealthReadWindow.limited(from: Self.boundary)
            #expect(limited.clamp(nil) == Self.boundary)
            #expect(limited.clamp(early) == Self.boundary)
            #expect(limited.clamp(late) == late)
            #expect(HealthReadWindow.unlimited.clamp(early) == early)
            #expect(HealthReadWindow.unlimited.clamp(nil) == nil)
            #expect(HealthReadWindow.unknown.clamp(early) == early)
        }

        @Test("no answer is unknown, an entry is limited, no entry is unlimited")
        func windowFromABatchedAnswer() {
            let weight = HKQuantityType(.bodyMass)
            let glucose = HKQuantityType(.bloodGlucose)
            let answer: [HKObjectType: Date] = [weight: Self.boundary]
            #expect(HealthReadWindow(weight, in: answer) == .limited(from: Self.boundary))
            #expect(HealthReadWindow(glucose, in: answer) == .unlimited)
            #expect(HealthReadWindow(weight, in: nil) == .unknown)
        }

        // MARK: - The runtime call

        @Test("the selector is the one Apple documents for iOS 27")
        func selectorMatchesTheDocumentation() {
            #expect(NSStringFromSelector(HealthKitAuthorizedHistory.selector)
                == "getEarliestAuthorizedSampleDateForTypes:completion:")
        }

        @Test(
            "a system without the iOS 27 method reads as nothing limited",
            .enabled(if: !HKHealthStore.instancesRespond(to: HealthKitAuthorizedHistory.selector))
        )
        func olderSystemsAreUnlimited() async {
            let dates = await HealthKitAuthorizedHistory(store: HKHealthStore())
                .earliestAuthorizedSampleDates(for: [HKQuantityType(.bodyMass)])
            #expect(dates == [:])
        }

        @Test("the runtime call reaches the method and types its answer")
        func runtimeCallIsTyped() async throws {
            let weight = HKQuantityType(.bodyMass)
            let store = EarliestDateAnsweringStore(answer: [weight: Self.boundary], error: nil)
            let dates = try #require(
                await HealthKitAuthorizedHistory(store: store, usesRuntimeCall: true).earliestAuthorizedSampleDates(for: [weight])
            )
            #expect(dates[weight] == Self.boundary)
            #expect(store.askedTypes == [weight])
        }

        @Test("an error from HealthKit is unknown, never unlimited")
        func errorIsUnknown() async {
            let store = EarliestDateAnsweringStore(answer: [:], error: NSError(domain: HKErrorDomain, code: 6))
            let dates = await HealthKitAuthorizedHistory(store: store, usesRuntimeCall: true)
                .earliestAuthorizedSampleDates(for: [HKQuantityType(.bodyMass)])
            #expect(dates == nil)
            #expect(await HealthKitAuthorizedHistory(store: store, usesRuntimeCall: true)
                .window(for: HKQuantityType(.bodyMass)) == .unknown)
        }

        @Test("the shipped app never makes the runtime call, even where the method exists")
        func shippedAppNeverCalls() async {
            let weight = HKQuantityType(.bodyMass)
            let store = EarliestDateAnsweringStore(answer: [weight: Self.boundary], error: nil)
            #expect(HealthKitAuthorizedHistory.shipsRuntimeCall == false)
            let dates = await HealthKitAuthorizedHistory(store: store).earliestAuthorizedSampleDates(for: [weight])
            #expect(dates == [:])
            #expect(store.askedTypes == nil)
            #expect(await HealthKitAuthorizedHistory(store: store).window(for: weight) == .unlimited)
        }

        @Test("an empty question is not sent")
        func emptyQuestionIsNotSent() async {
            let store = EarliestDateAnsweringStore(answer: [:], error: nil)
            let dates = await HealthKitAuthorizedHistory(store: store, usesRuntimeCall: true).earliestAuthorizedSampleDates(for: [])
            #expect(dates == [:])
            #expect(store.askedTypes == nil)
        }

        // MARK: - The server → Apple Health mirror

        private func weight(id: String, at instant: Date) -> HealthLog.Measurement {
            HealthLog.Measurement(id: id, kind: .weight, recordedAt: instant, value: .scalar(80), source: .manual)
        }

        /// Nothing in Health, writes authorized, and a fixed readable window.
        private func probe(_ dates: [HKObjectType: Date]?) -> HealthKitServerMirrorProbe {
            HealthKitServerMirrorProbe(
                isShareAuthorized: { _ in true },
                existsWithExternalIDs: { _, _ in false },
                ownSamplesNear: { _, _ in [] },
                earliestAuthorizedDates: { _ in dates }
            )
        }

        @Test("a row older than the readable window is not written again")
        func olderRowIsLeftAlone() async {
            let old = weight(id: "srv-old", at: Self.boundary.addingTimeInterval(-86400))
            let recent = weight(id: "srv-new", at: Self.boundary.addingTimeInterval(86400))
            let plan = await HealthKitServerMirrorPlanner.plan(
                [old, recent],
                excluding: [],
                probe: probe([HKQuantityType(.bodyMass): Self.boundary])
            )
            #expect(plan.linkageIDs == ["srv-new"])
        }

        @Test("a row on the boundary is still readable and written")
        func rowOnTheBoundaryIsWritten() async {
            let plan = await HealthKitServerMirrorPlanner.plan(
                [weight(id: "srv-edge", at: Self.boundary)],
                excluding: [],
                probe: probe([HKQuantityType(.bodyMass): Self.boundary])
            )
            #expect(plan.linkageIDs == ["srv-edge"])
        }

        @Test("full access writes as before")
        func fullAccessWritesAsBefore() async {
            let plan = await HealthKitServerMirrorPlanner.plan(
                [weight(id: "srv-old", at: Self.boundary.addingTimeInterval(-86400 * 400))],
                excluding: [],
                probe: probe([:])
            )
            #expect(plan.linkageIDs == ["srv-old"])
        }

        @Test("when HealthKit cannot say, the pass writes nothing")
        func unknownWindowWritesNothing() async {
            let plan = await HealthKitServerMirrorPlanner.plan(
                [weight(id: "srv-new", at: Self.boundary.addingTimeInterval(86400))],
                excluding: [],
                probe: probe(nil)
            )
            #expect(plan.samples.isEmpty)
        }

        @Test("a blood pressure is skipped when either of its types is limited past it")
        func bloodPressureNeedsBothTypesReadable() async {
            let reading = HealthLog.Measurement(
                id: "srv-bp",
                kind: .bloodPressure,
                recordedAt: Self.boundary.addingTimeInterval(-60),
                value: .bloodPressure(systolic: 120, diastolic: 80),
                source: .manual,
                bloodPressureDiastolicId: "srv-bp-dia"
            )
            let plan = await HealthKitServerMirrorPlanner.plan(
                [reading],
                excluding: [],
                probe: probe([HKQuantityType(.bloodPressureDiastolic): Self.boundary])
            )
            #expect(plan.samples.isEmpty)
        }
    }

    /// An `HKHealthStore` that answers the iOS 27 selector itself, so the
    /// runtime path (`responds(to:)`, `method(for:)`, the block, the typed
    /// dictionary) runs end to end on an iOS 26 simulator.
    private final class EarliestDateAnsweringStore: HKHealthStore, @unchecked Sendable {
        private let answer: NSDictionary
        private let error: NSError?
        private let asked = OSAllocatedUnfairLock<Set<HKObjectType>?>(initialState: nil)

        init(answer: [HKObjectType: Date], error: NSError?) {
            self.answer = answer as NSDictionary
            self.error = error
            super.init()
        }

        var askedTypes: Set<HKObjectType>? {
            asked.withLock { $0 }
        }

        @objc(getEarliestAuthorizedSampleDateForTypes:completion:)
        func earliestDates(_ types: NSSet, completion: @escaping @Sendable (NSDictionary?, NSError?) -> Void) {
            let typed = Set(types.compactMap { $0 as? HKObjectType })
            asked.withLock { $0 = typed }
            completion(error == nil ? answer : nil, error)
        }
    }
#endif
