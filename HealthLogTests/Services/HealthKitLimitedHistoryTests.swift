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
    /// These pin the window vocabulary, the typed iOS 27 call that asks
    /// HealthKit for it (through its seam), and the server→Health
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

        // MARK: - The typed call

        /// A fake for the typed iOS 27 call that records what it was asked.
        private final class TypedCallRecorder: Sendable {
            private let answer: [HKObjectType: Date]
            private let error: (any Error)?
            private let asked = OSAllocatedUnfairLock<[Set<HKObjectType>]>(initialState: [])

            init(answer: [HKObjectType: Date], error: (any Error)? = nil) {
                self.answer = answer
                self.error = error
            }

            var questions: [Set<HKObjectType>] {
                asked.withLock { $0 }
            }

            var call: HealthKitAuthorizedHistory.TypedCall {
                { [self] types in
                    asked.withLock { $0.append(types) }
                    if let error { throw error }
                    return answer
                }
            }
        }

        private func history(
            _ recorder: TypedCallRecorder,
            usesTypedCall: Bool = true,
            systemHasTypedCall: Bool = true
        ) -> HealthKitAuthorizedHistory {
            HealthKitAuthorizedHistory(
                usesTypedCall: usesTypedCall,
                systemHasTypedCall: systemHasTypedCall,
                typedCall: recorder.call
            )
        }

        @Test("the typed call is asked once for all types and its answer kept")
        func typedCallIsAskedAndTyped() async throws {
            let weight = HKQuantityType(.bodyMass)
            let glucose = HKQuantityType(.bloodGlucose)
            let recorder = TypedCallRecorder(answer: [weight: Self.boundary])
            let dates = try #require(await history(recorder).earliestAuthorizedSampleDates(for: [weight, glucose]))
            #expect(dates[weight] == Self.boundary)
            #expect(dates[glucose] == nil)
            #expect(recorder.questions == [[weight, glucose]])
            #expect(await history(recorder).window(for: glucose) == .unlimited)
            #expect(await history(recorder).window(for: weight) == .limited(from: Self.boundary))
        }

        @Test("an error from HealthKit is unknown, never unlimited")
        func errorIsUnknown() async {
            let recorder = TypedCallRecorder(answer: [:], error: NSError(domain: HKErrorDomain, code: 6))
            #expect(await history(recorder).earliestAuthorizedSampleDates(for: [HKQuantityType(.bodyMass)]) == nil)
            #expect(await history(recorder).window(for: HKQuantityType(.bodyMass)) == .unknown)
        }

        @Test("an empty question is not sent")
        func emptyQuestionIsNotSent() async {
            let recorder = TypedCallRecorder(answer: [:])
            #expect(await history(recorder).earliestAuthorizedSampleDates(for: []) == [:])
            #expect(recorder.questions.isEmpty)
        }

        @Test("before iOS 27 the call is never made and nothing reads as limited")
        func olderSystemNeverCalls() async {
            let weight = HKQuantityType(.bodyMass)
            let recorder = TypedCallRecorder(answer: [weight: Self.boundary])
            let older = history(recorder, systemHasTypedCall: false)
            #expect(await older.earliestAuthorizedSampleDates(for: [weight]) == [:])
            #expect(await older.window(for: weight) == .unlimited)
            #expect(recorder.questions.isEmpty)
            // The live adapter on a real store, told it runs on an older system.
            let real = HealthKitAuthorizedHistory(store: HKHealthStore(), usesTypedCall: true, systemHasTypedCall: false)
            #expect(await real.earliestAuthorizedSampleDates(for: [weight]) == [:])
        }

        @Test("the availability seam follows the running system")
        func systemFlagFollowsTheOS() {
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            #expect(HealthKitAuthorizedHistory.systemHasTypedCall == (major >= 27))
            #expect(HealthKitAuthorizedHistory(store: HKHealthStore()).systemHasTypedCall == (major >= 27))
        }

        @Test("with the brake on, the call is never made")
        func brakeKeepsTheCallOff() async {
            let weight = HKQuantityType(.bodyMass)
            let recorder = TypedCallRecorder(answer: [weight: Self.boundary])
            let braked = history(recorder, usesTypedCall: false)
            #expect(await braked.earliestAuthorizedSampleDates(for: [weight]) == [:])
            #expect(await braked.window(for: weight) == .unlimited)
            #expect(recorder.questions.isEmpty)
        }

        /// HK-LIMIT (e): the shipped default is what the iOS 27.2 simulator
        /// run (`HealthKitTypedHistorySimulatorTests`, report HK-LIMIT.md)
        /// decided. Changing it means changing that evidence first.
        @Test("the shipped switch stands where the simulator evidence put it")
        func shippedDefault() {
            #expect(HealthKitAuthorizedHistory.shipsTypedCall == Self.shipsTypedCallDecision)
            #expect(HealthKitAuthorizedHistory(store: HKHealthStore()).usesTypedCall == Self.shipsTypedCallDecision)
        }

        private static let shipsTypedCallDecision = true

        @Test("the mirror leaves a row before the boundary the typed call reports")
        func mirrorFollowsTheTypedBoundary() async {
            let recorder = TypedCallRecorder(answer: [HKQuantityType(.bodyMass): Self.boundary])
            let typed = history(recorder)
            let plan = await HealthKitServerMirrorPlanner.plan(
                [
                    weight(id: "srv-old", at: Self.boundary.addingTimeInterval(-86400)),
                    weight(id: "srv-new", at: Self.boundary.addingTimeInterval(86400))
                ],
                excluding: [],
                probe: HealthKitServerMirrorProbe(
                    isShareAuthorized: { _ in true },
                    existsWithExternalIDs: { _, _ in false },
                    ownSamplesNear: { _, _ in [] },
                    earliestAuthorizedDates: { types in await typed.earliestAuthorizedSampleDates(for: types) }
                )
            )
            #expect(plan.linkageIDs == ["srv-new"])
            #expect(!recorder.questions.isEmpty)
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

#endif
