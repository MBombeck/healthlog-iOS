import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

// MARK: - Read types added after the first sheet (1.2 / V4 RMSSD, 1.4 / B5 waist)

/// Moved out of `HKReadinessStore.swift` in B5 (1.4) so the store's own file
/// does not grow; it reads the store's `healthKit`, `defaults` and
/// `currentUserID`, which are internal for that reason.
public extension HKReadinessStore {
    /// One-shot per-user flag: has the RMSSD read request run?
    nonisolated static let rmssdReadRequestedKeyPrefix = "hl.healthkit.rmssdReadRequested."

    nonisolated static func rmssdReadRequestedKey(for userId: String?) -> String {
        rmssdReadRequestedKeyPrefix + partitionToken(for: userId)
    }

    /// B5 (1.4) — one-shot per-user flag: has the waist read request run?
    nonisolated static let waistReadRequestedKeyPrefix = "hl.healthkit.waistReadRequested."

    nonisolated static func waistReadRequestedKey(for userId: String?) -> String {
        waistReadRequestedKeyPrefix + partitionToken(for: userId)
    }

    /// One short authorization sheet for the read types that joined HealthLog
    /// after this installation went through the HealthKit sheet: HRV as RMSSD
    /// (iOS 27, 1.2) and waist circumference (1.4).
    ///
    /// An install onboarded earlier has `requestedAt` set and is never asked
    /// again by the normal paths, and Apple never reports a read grant, so a
    /// new read type would stay unasked forever. This asks for exactly the
    /// new types still open, in ONE sheet, so it lists nothing else and every
    /// earlier decision stays as it was. A denial affects those types alone.
    ///
    /// Each type has its own per-user flag, so a person who already answered
    /// the RMSSD request is still asked once for waist circumference. A type
    /// is asked only when all of this holds: the system resolves it (RMSSD
    /// needs iOS 27), the user has been through the sheet before (a new user
    /// gets every type in the onboarding sheet), the configured server stores
    /// it (otherwise the question waits for a later foreground), and the
    /// system itself says its sheet is still unanswered (`.shouldRequest`).
    /// Grant and deny both turn that into `.unnecessary`, and the flags are set
    /// after the one attempt, so a declined request never comes back.
    ///
    /// - Returns: `true` when the sheet was requested.
    @discardableResult
    func requestLateReadAuthorizationIfNeeded() async -> Bool {
        #if canImport(HealthKit)
            await requestLateReadAuthorizationIfNeeded(lateReadTypes())
        #else
            false
        #endif
    }

    #if canImport(HealthKit)
        /// A read type that joined after the first sheet, with its flag and
        /// whether the configured server stores it yet.
        internal struct LateReadType {
            /// The resolved type; `nil` where the system does not have it.
            let type: HKObjectType?
            let flagPrefix: String
            let serverAccepts: Bool
        }

        /// The types this build adds after the first sheet, as this system and
        /// the configured server see them.
        internal func lateReadTypes() -> [LateReadType] {
            [
                LateReadType(
                    type: HeartRateVariabilityRMSSD.sampleType,
                    flagPrefix: Self.rmssdReadRequestedKeyPrefix,
                    serverAccepts: HealthKitServerTypeGate.serverAccepts(HeartRateVariabilityRMSSD.identifier, defaults: defaults)
                ),
                // B5 (1.4) — every server the app supports maps it (v1.25.0).
                LateReadType(
                    type: HKQuantityType(.waistCircumference),
                    flagPrefix: Self.waistReadRequestedKeyPrefix,
                    serverAccepts: HealthKitServerTypeGate.serverAccepts(
                        HKQuantityTypeIdentifier.waistCircumference.rawValue,
                        defaults: defaults
                    )
                )
            ]
        }

        /// The RMSSD half of the rule on its own, with its two platform facts
        /// as parameters, so a test can pin the iOS 27 path on an older
        /// simulator.
        /// - Parameters:
        ///   - type: the resolved RMSSD type; `nil` before iOS 27.
        ///   - serverAccepts: whether the configured server stores the type.
        internal func requestRMSSDReadAuthorizationIfNeeded(type: HKObjectType?, serverAccepts: Bool) async -> Bool {
            await requestLateReadAuthorizationIfNeeded([
                LateReadType(type: type, flagPrefix: Self.rmssdReadRequestedKeyPrefix, serverAccepts: serverAccepts)
            ])
        }

        /// The rule behind ``requestLateReadAuthorizationIfNeeded()``.
        internal func requestLateReadAuthorizationIfNeeded(_ candidates: [LateReadType]) async -> Bool {
            let ownerUserID = currentUserID
            let open = openLateReadTypes(candidates, token: Self.partitionToken(for: ownerUserID))
            guard !open.isEmpty,
                  let service = healthKit as? any HealthKitServiceProtocol,
                  let ownerUserID,
                  !ownerUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !Task.isCancelled else { return false }
            let ask = await unansweredLateReadTypes(open, service: service)
            guard !ask.isEmpty, currentUserID == ownerUserID, !Task.isCancelled else { return false }
            do {
                try await service.requestAuthorization(read: Set(ask.map(\.type)), write: [])
                for entry in ask {
                    defaults.set(true, forKey: entry.flag)
                }
                // A count only: no type name, no user.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.info("late read request ran for \(ask.count, privacy: .public) type(s) (returning user)")
                return true
            } catch {
                HLLog.healthKit.error(
                    "late read request failed: \(error.localizedDescription, privacy: .private)"
                )
                return false
            }
        }

        /// The candidates still to ask: resolved on this system, flag not set,
        /// stored by the server. A user who never saw the first sheet gets the
        /// types in onboarding, so their flags are set here without asking.
        private func openLateReadTypes(_ candidates: [LateReadType], token: String) -> [(type: HKObjectType, flag: String)] {
            var open: [(type: HKObjectType, flag: String)] = []
            for candidate in candidates {
                guard let type = candidate.type else { continue }
                let flag = candidate.flagPrefix + token
                guard !defaults.bool(forKey: flag) else { continue }
                guard hasEverRequestedAuthorization else {
                    defaults.set(true, forKey: flag)
                    continue
                }
                if candidate.serverAccepts { open.append((type, flag)) }
            }
            return open
        }

        /// Of `open`, the types whose sheet the system still calls unanswered.
        /// An answered one (granted or denied) is flagged without asking; a
        /// status the system cannot give leaves it for a later foreground.
        private func unansweredLateReadTypes(
            _ open: [(type: HKObjectType, flag: String)],
            service: any HealthKitServiceProtocol
        ) async -> [(type: HKObjectType, flag: String)] {
            var ask: [(type: HKObjectType, flag: String)] = []
            for entry in open {
                switch await service.authorizationRequestStatus(toShare: [], read: [entry.type]) {
                case .unnecessary:
                    defaults.set(true, forKey: entry.flag)
                case .shouldRequest:
                    ask.append(entry)
                default:
                    continue
                }
            }
            return ask
        }
    #endif
}
