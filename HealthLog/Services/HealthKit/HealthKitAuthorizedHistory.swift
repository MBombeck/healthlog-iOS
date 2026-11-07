import Foundation
#if canImport(HealthKit)
    import HealthKit
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

    /// The live answer, through the typed iOS 27 API.
    ///
    /// `HKHealthStore.earliestAuthorizedSampleDate(for:)` is the Swift async
    /// form of `getEarliestAuthorizedSampleDateForTypes:completion:`
    /// (`HKHealthStore.h`, `API_AVAILABLE(ios(27.0))`). It is an Objective-C
    /// method, so the call goes through `objc_msgSend` and links no HealthKit
    /// symbol; the compiler builds the completion block. `#available(iOS 27.0, *)`
    /// keeps every older system off it, where every type reads as unlimited,
    /// exactly as in 1.4.
    ///
    /// 1.4.0 (297) crashed at launch on iOS 27.0 inside a hand-made runtime
    /// cast of this method (`method(for:)` plus `unsafeBitCast`), built
    /// against the iOS 26 SDK. That adapter is gone. 1.5 calls only the typed,
    /// availability-guarded API.
    struct HealthKitAuthorizedHistory: HealthKitAuthorizedHistoryProviding {
        /// The question HealthKit answers, as a seam for tests.
        typealias TypedCall = @Sendable (Set<HKObjectType>) async throws -> [HKObjectType: Date]

        /// **Emergency brake (1.5 HK-LIMIT, rule 16, decision 17).** On
        /// because `HealthKitTypedHistorySimulatorTests` ran the real call on an
        /// iOS 27.2 simulator for every type group the app reads or writes,
        /// three runs in a row: no crash, an answer within 5 s, no error, no
        /// date after now (report HK-LIMIT.md). Off means every type reads as
        /// unlimited and Settings shows no line, exactly as 1.4. If a device
        /// pass finds a fault, set this to `false` and ship a new build.
        static let shipsTypedCall = true

        /// `true` on iOS 27 and later, the only systems with the method.
        static var systemHasTypedCall: Bool {
            if #available(iOS 27.0, *) { return true }
            return false
        }

        var usesTypedCall: Bool
        var systemHasTypedCall: Bool
        let typedCall: TypedCall

        init(
            store: HKHealthStore,
            usesTypedCall: Bool = Self.shipsTypedCall,
            systemHasTypedCall: Bool = Self.systemHasTypedCall
        ) {
            self.init(usesTypedCall: usesTypedCall, systemHasTypedCall: systemHasTypedCall, typedCall: Self.liveCall(store))
        }

        /// The seam: tests hand in the call and the system's answer to
        /// "is this iOS 27?".
        init(usesTypedCall: Bool, systemHasTypedCall: Bool, typedCall: @escaping TypedCall) {
            self.usesTypedCall = usesTypedCall
            self.systemHasTypedCall = systemHasTypedCall
            self.typedCall = typedCall
        }

        /// The real call. Before iOS 27 it never reaches HealthKit and answers
        /// "nothing limited"; `earliestAuthorizedSampleDates` does not even
        /// get that far there, because `systemHasTypedCall` is `false`.
        static func liveCall(_ store: HKHealthStore) -> TypedCall {
            { types in
                guard #available(iOS 27.0, *) else { return [:] }
                return try await store.earliestAuthorizedSampleDate(for: types)
            }
        }

        func earliestAuthorizedSampleDates(for types: Set<HKObjectType>) async -> [HKObjectType: Date]? {
            guard usesTypedCall, systemHasTypedCall, !types.isEmpty else { return [:] }
            do {
                return try await typedCall(types)
            } catch {
                HLLog.healthKit.error(
                    "HK-LIMIT earliest authorized date failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return nil
            }
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
