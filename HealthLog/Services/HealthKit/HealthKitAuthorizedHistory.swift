import Foundation
#if canImport(HealthKit)
    import HealthKit
    import os
#endif

#if canImport(HealthKit)

    /// **1.4 / iOS 27 — the earliest date a person lets HealthLog read.**
    ///
    /// iOS 27 adds a second page to the HealthKit permission sheet: the person
    /// grants either a recent limited window or the full history (iOS 27
    /// release notes, HealthKit, 172310874). HealthKit reports the window per
    /// type through `HKHealthStore.getEarliestAuthorizedSampleDate(for:completion:)`,
    /// Objective-C `getEarliestAuthorizedSampleDateForTypes:completion:`,
    /// introduced in iOS 27.0
    /// (developer.apple.com/documentation/healthkit/hkhealthstore/getearliestauthorizedsampledate(for:completion:)).
    /// Only limited types get an entry; full and denied access both come back
    /// without one, by design. The boundary is compared with a sample's END
    /// date.
    ///
    /// The seam is a protocol so the mirror planner and the readiness store can
    /// be driven with a fixed date in a unit test.
    protocol HealthKitAuthorizedHistoryProviding: Sendable {
        /// The earliest readable date for every limited type in `types`.
        ///
        /// `[:]` when no type is limited, including every system before
        /// iOS 27. `nil` when HealthKit could not answer: callers read that as
        /// "unknown", never as "unlimited".
        func earliestAuthorizedSampleDates(for types: Set<HKObjectType>) async -> [HKObjectType: Date]?
    }

    extension HealthKitAuthorizedHistoryProviding {
        /// The window for one type.
        func window(for type: HKObjectType) async -> HealthReadWindow {
            await HealthReadWindow(type, in: earliestAuthorizedSampleDates(for: [type]))
        }
    }

    extension HealthReadWindow {
        /// One type's window out of a batched answer: no answer is `unknown`,
        /// an entry is `limited`, no entry is `unlimited`.
        init(_ type: HKObjectType, in dates: [HKObjectType: Date]?) {
            guard let dates else {
                self = .unknown
                return
            }
            self = dates[type].map { HealthReadWindow.limited(from: $0) } ?? .unlimited
        }
    }

    /// The live answer, reached through the Objective-C runtime.
    ///
    /// **Why the runtime.** The app builds with Xcode 26.6 against the iOS 26
    /// SDK, which has no symbol for this method, so `#available(iOS 27, *)`
    /// alone cannot call it. The store is asked whether it responds to the
    /// selector, and the implementation comes from `method(for:)`. On iOS 26
    /// and older it does not respond, every type reads as unlimited, and the app
    /// behaves exactly as before.
    ///
    /// **Replace this type with the direct API** (`try await
    /// store.earliestAuthorizedSampleDate(for:)`) once the project builds with
    /// the iOS 27 SDK (1.4 plan, wave 0 / Z0). The protocol above stays.
    struct HealthKitAuthorizedHistory: HealthKitAuthorizedHistoryProviding {
        /// `- (void)getEarliestAuthorizedSampleDateForTypes:(NSSet<HKObjectType *> *)types
        /// completion:(void (^)(NSDictionary<HKObjectType *, NSDate *> *, NSError *))completion`
        static let selector = NSSelectorFromString("getEarliestAuthorizedSampleDateForTypes:completion:")

        /// **1.4.0 (297) crashed at launch on iOS 27.0 (24A437)** inside this
        /// call: the shipped method does not have the shape the runtime cast
        /// assumes, and the test double that does could not show it. Until the
        /// project builds with the iOS 27 SDK and calls the typed API, the
        /// shipped app never makes the call. Every type then reads as unlimited,
        /// exactly as on iOS 26 and in 1.3. Tests opt in to exercise the code.
        static let shipsRuntimeCall = false

        let store: HKHealthStore
        var usesRuntimeCall = Self.shipsRuntimeCall

        func earliestAuthorizedSampleDates(for types: Set<HKObjectType>) async -> [HKObjectType: Date]? {
            guard usesRuntimeCall, !types.isEmpty, store.responds(to: Self.selector) else { return [:] }
            typealias Completion = @convention(block) @Sendable (NSDictionary?, NSError?) -> Void
            typealias Method = @convention(c) (AnyObject, Selector, NSSet, Completion) -> Void
            let method = unsafeBitCast(store.method(for: Self.selector), to: Method.self)
            return await withCheckedContinuation { continuation in
                // HealthKit answers once. The guard keeps a second answer from
                // trapping the continuation all the same.
                let answered = OSAllocatedUnfairLock(initialState: false)
                method(store, Self.selector, types as NSSet) { dates, error in
                    let first = answered.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    continuation.resume(returning: error == nil ? Self.decode(dates) : nil)
                }
            }
        }

        /// The dictionary HealthKit hands back, typed. Entries of any other
        /// shape are dropped rather than trusted.
        static func decode(_ dates: NSDictionary?) -> [HKObjectType: Date] {
            var result: [HKObjectType: Date] = [:]
            for (key, value) in dates ?? [:] {
                guard let type = key as? HKObjectType, let date = value as? Date else { continue }
                result[type] = date
            }
            return result
        }
    }

    public extension HealthKitService {
        /// The earliest date Apple Health lets HealthLog read across the types
        /// it reads, or `nil` when nothing is limited (or HealthKit could not
        /// say). Settings › Apple Health shows one line for it.
        ///
        /// The earliest of the per-type dates is the person's chosen window: a
        /// type whose own data begins later reports that later date.
        nonisolated func limitedHistoryStart() async -> Date? {
            let types = defaultReadTypes().filter { $0 is HKSampleType }
            let dates = await HealthKitAuthorizedHistory(store: store).earliestAuthorizedSampleDates(for: types)
            return dates?.values.min()
        }
    }

#endif
