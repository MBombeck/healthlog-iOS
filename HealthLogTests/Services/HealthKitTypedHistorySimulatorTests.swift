#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import os
    import Testing

    /// **1.5 HK-LIMIT (f) — the real typed call on the iOS 27.2 simulator.**
    ///
    /// Decides `HealthKitAuthorizedHistory.shipsTypedCall` (rule 16, decision
    /// 17). Runs in the app host against a real `HKHealthStore`, through the
    /// shipping adapter with the brake released, for every type group the app
    /// reads or writes. It passes when the call does not crash, answers within
    /// 5 s, reports no error, and names no date after now. On any other system
    /// it is skipped, which counts as "not proven", never as proof.
    @Suite("Typed limited-history call on the iOS 27.2 simulator")
    struct HealthKitTypedHistorySimulatorTests {
        static var runsOnTheProvingSystem: Bool {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return version.majorVersion == 27 && version.minorVersion == 2
        }

        enum Group: String, CaseIterable, Sendable {
            // The app reads no correlation and no characteristic types, so
            // neither is a group here (an empty group is a failure below).
            case quantity, category, workout, otherSamples
            case events, writes, medicationDoseEvents, allSampleReads

            var types: Set<HKObjectType> {
                let reads = HealthKitService.defaultReadTypes
                switch self {
                case .quantity: return reads.filter { $0 is HKQuantityType }
                case .category: return reads.filter { $0 is HKCategoryType }
                case .workout: return reads.filter { $0 is HKWorkoutType || $0 is HKSeriesType }
                case .otherSamples:
                    return reads.filter {
                        $0 is HKSampleType && !($0 is HKQuantityType) && !($0 is HKCategoryType)
                            && !($0 is HKCorrelationType) && !($0 is HKWorkoutType) && !($0 is HKSeriesType)
                    }
                case .events: return HealthKitService.eventReadTypes
                case .writes: return Set(HealthKitService.defaultWriteTypes.map { $0 as HKObjectType })
                case .medicationDoseEvents:
                    guard #available(iOS 26.0, *) else { return [] }
                    return [HKObjectType.medicationDoseEventType()]
                case .allSampleReads: return reads.filter { $0 is HKSampleType }
                }
            }
        }

        enum Outcome: Sendable, Equatable {
            case answered([HKObjectType: Date]?)
            case timedOut
        }

        /// The adapter's answer, or `.timedOut` after `seconds`. The call
        /// keeps running in the background if HealthKit never answers; the
        /// test reports that instead of hanging.
        static func answer(_ types: Set<HKObjectType>, within seconds: Double) async -> Outcome {
            let history = HealthKitAuthorizedHistory(store: HKHealthStore(), usesTypedCall: true)
            let settled = OSAllocatedUnfairLock(initialState: false)
            return await withCheckedContinuation { continuation in
                @Sendable func settle(_ outcome: Outcome) {
                    let first = settled.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume(returning: outcome) }
                }
                Task.detached {
                    await settle(.answered(history.earliestAuthorizedSampleDates(for: types)))
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(seconds))
                    settle(.timedOut)
                }
            }
        }

        @Test(
            "the real typed call answers for every type group",
            .enabled(if: Self.runsOnTheProvingSystem, "proves the switch only on iOS 27.2"),
            arguments: Group.allCases
        )
        func realCallAnswers(group: Group) async throws {
            let types = group.types
            try #require(!types.isEmpty, "group \(group.rawValue) has no types on this system")
            let now = Date()
            let outcome = await Self.answer(types, within: 5)
            print(
                "HK-LIMIT-EVIDENCE group=\(group.rawValue) types=\(types.count) "
                    + "seconds=\(String(format: "%.3f", Date().timeIntervalSince(now))) outcome=\(outcome)"
            )
            guard case let .answered(dates) = outcome else {
                Issue.record("group \(group.rawValue): no answer within 5 s")
                return
            }
            let answered = try #require(dates, "group \(group.rawValue): HealthKit reported an error")
            for (type, date) in answered {
                #expect(types.contains(type), "group \(group.rawValue): answer for a type not asked")
                #expect(date <= now, "group \(group.rawValue): \(type) limited from the future")
            }
        }

        @Test(
            "Settings asks the same question and gets no future date",
            .enabled(if: Self.runsOnTheProvingSystem, "proves the switch only on iOS 27.2")
        )
        func settingsQuestionAnswers() async {
            let types = Group.allSampleReads.types
            let outcome = await Self.answer(types, within: 5)
            guard case let .answered(dates) = outcome else {
                Issue.record("no answer within 5 s")
                return
            }
            #expect(dates != nil)
            #expect((dates?.values.min() ?? .distantPast) <= Date())
        }
    }

#endif
