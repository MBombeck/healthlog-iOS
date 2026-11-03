#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **B5 (1.4, from A4 / HealthLog#1247) — the per-type direction decides
    /// what HealthLog writes into Apple Health.**
    ///
    /// Server rule (`healthKitWriteBackTypes`, `src/lib/integrations/
    /// healthkit-type-sync.ts`, v1.43.10): an entry writes back when it is
    /// enabled and its direction is `bidirectional` or `writeOnly`. Server
    /// defaults (`DEFAULT_HEALTHKIT_ENTRIES`, `src/app/api/integrations/
    /// healthkit/route.ts`): weight, blood pressure and glucose
    /// `bidirectional`; pulse, steps and sleep `readOnly`. Up to 1.3 the
    /// mirror asked only for the share permission.
    @Suite("B5 — Apple Health write-back follows the per-type direction")
    struct HealthKitWriteBackDirectionTests {
        private static let now = Date(timeIntervalSince1970: 1_790_000_000)

        /// `GET /api/integrations/healthkit` as the SWR cache of a 1.3.0 build
        /// holds it for an account that never changed a setting: the
        /// server's defaults, encoded the way `HealthKitSyncConfig` encodes
        /// (entries and `lastSyncedAt` only).
        private static let cachedDefaults130 = """
        {"entries":[\
        {"id":"bodyMass","kind":"bodyMass","direction":"bidirectional","enabled":true},\
        {"id":"bp","kind":"bloodPressure","direction":"bidirectional","enabled":true},\
        {"id":"glucose","kind":"bloodGlucose","direction":"bidirectional","enabled":true},\
        {"id":"heartRate","kind":"heartRate","direction":"readOnly","enabled":true},\
        {"id":"stepCount","kind":"stepCount","direction":"readOnly","enabled":true},\
        {"id":"sleep","kind":"sleepAnalysis","direction":"readOnly","enabled":true}],\
        "lastSyncedAt":null}
        """

        private static func policy(_ json: String) throws -> HealthKitWriteBackPolicy {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let config = try decoder.decode(HealthKitSyncConfig.self, from: Data(json.utf8))
            return HealthKitWriteBackPolicy(entries: config.entries)
        }

        private static func entry(_ kind: String, _ direction: SyncDirection, enabled: Bool = true) -> HealthKitSyncEntry {
            HealthKitSyncEntry(id: kind, kind: kind, direction: direction, enabled: enabled)
        }

        private static func reading(_ id: String, _ kind: MetricKind, _ value: Double) -> HealthLog.Measurement {
            HealthLog.Measurement(id: id, kind: kind, recordedAt: now, value: .scalar(value), source: .withings)
        }

        private static func probe(
            policy: HealthKitWriteBackPolicy?,
            inHealth: Set<String> = []
        ) -> HealthKitServerMirrorProbe {
            HealthKitServerMirrorProbe(
                isShareAuthorized: { _ in true },
                existsWithExternalIDs: { ids, _ in !inHealth.isDisjoint(with: ids) },
                ownSamplesNear: { _, _ in [] },
                writeBackPolicy: { policy }
            )
        }

        // MARK: - The rule

        @Test("the server defaults: weight, blood pressure, glucose write; pulse does not; kinds without a setting do")
        func serverDefaults() throws {
            let policy = try Self.policy(Self.cachedDefaults130)
            #expect(policy.allowsWrite(.weight))
            #expect(policy.allowsWrite(.bloodPressure))
            #expect(policy.allowsWrite(.glucose))
            #expect(!policy.allowsWrite(.pulse))
            for kind: MetricKind in [.bodyFat, .bodyTemperature, .spo2, .restingHeartRate, .hrv, .vo2Max, .bmi] {
                #expect(policy.allowsWrite(kind), "no setting for \(kind) keeps it writing")
            }
        }

        @Test("each direction and the enabled switch, exactly as the server reads them")
        func directions() {
            let policy = HealthKitWriteBackPolicy(entries: [
                Self.entry("bodyMass", .readOnly),
                Self.entry("heartRate", .bidirectional),
                Self.entry("bloodGlucose", .writeOnly),
                Self.entry("bloodPressure", .bidirectional, enabled: false),
                Self.entry("bodyFatPercentage", .disabled),
                Self.entry("oxygenSaturation", .unknown)
            ])
            #expect(!policy.allowsWrite(.weight))
            #expect(policy.allowsWrite(.pulse))
            #expect(policy.allowsWrite(.glucose))
            #expect(!policy.allowsWrite(.bloodPressure))
            #expect(!policy.allowsWrite(.bodyFat))
            #expect(!policy.allowsWrite(.spo2))
            #expect(HealthKitWriteBackPolicy.unrestricted.allowsWrite(.pulse))
        }

        @Test("two entries for one kind: any one that writes lets it write, like the server's union")
        func entriesUnion() {
            let policy = HealthKitWriteBackPolicy(entries: [
                HealthKitSyncEntry(id: "heartRate", kind: "heartRate", direction: .readOnly, enabled: true),
                HealthKitSyncEntry(id: "pulse-custom", kind: "heartRate", direction: .bidirectional, enabled: true)
            ])
            #expect(policy.allowsWrite(.pulse))
        }

        // MARK: - The mirror

        @Test("the mirror writes weight and leaves pulse alone under the server defaults")
        func mirrorFollowsTheDirection() async throws {
            let plan = try await HealthKitServerMirrorPlanner.plan(
                [Self.reading("srv-weight", .weight, 80), Self.reading("srv-pulse", .pulse, 64)],
                excluding: [],
                probe: Self.probe(policy: Self.policy(Self.cachedDefaults130))
            )
            #expect(plan.linkageIDs == ["srv-weight"])
            #expect(plan.decided)
        }

        @Test("when the direction is not known, the pass writes nothing and says so")
        func unknownDirectionWritesNothing() async {
            let plan = await HealthKitServerMirrorPlanner.plan(
                [Self.reading("srv-weight", .weight, 80)],
                excluding: [],
                probe: Self.probe(policy: nil)
            )
            #expect(plan.samples.isEmpty)
            #expect(!plan.decided)
        }

        /// The window can stay unknown (the iOS 27 call failing on a device);
        /// holding the one-shot open would refetch the whole history on every
        /// refresh, so A3's "write nothing" stands without holding it.
        @Test("an unknown readable window (A3) writes nothing and does not hold the one-shot")
        func unknownWindowWritesNothingButDecides() async {
            let probe = HealthKitServerMirrorProbe(
                isShareAuthorized: { _ in true },
                existsWithExternalIDs: { _, _ in false },
                ownSamplesNear: { _, _ in [] },
                earliestAuthorizedDates: { _ in nil }
            )
            let plan = await HealthKitServerMirrorPlanner.plan(
                [Self.reading("srv-weight", .weight, 80)],
                excluding: [],
                probe: probe
            )
            #expect(plan.samples.isEmpty)
            #expect(plan.decided)
        }

        @Test("no direction attached (no server, tests) writes as before 1.4")
        func noProviderIsUnrestricted() async {
            let policy = await HealthKitService.resolveWriteBackPolicy(nil)
            #expect(policy == .unrestricted)
            let unknown = await HealthKitService.resolveWriteBackPolicy { nil }
            #expect(unknown == nil)
        }

        // MARK: - Update path from 1.3.0

        @Test("update from 1.3.0: pulse already mirrored stays, no new pulse is written, nothing is deleted")
        func updatePathKeepsWhatIsThere() async throws {
            // 1.3.0 mirrored every pulse it saw; "srv-pulse-old" is in Apple
            // Health with its server id. After the update the cached setting
            // (server defaults) says pulse is read only.
            let rows = [
                Self.reading("srv-pulse-old", .pulse, 61),
                Self.reading("srv-pulse-new", .pulse, 63),
                Self.reading("srv-weight-new", .weight, 79.5)
            ]
            let plan = try await HealthKitServerMirrorPlanner.plan(
                rows,
                excluding: [],
                probe: Self.probe(policy: Self.policy(Self.cachedDefaults130), inHealth: ["srv-pulse-old"])
            )
            // Only the new weight is written. The plan is a list of saves; the
            // mirror has no delete path, so the pulse already in Apple Health
            // stays exactly as it is.
            #expect(plan.linkageIDs == ["srv-weight-new"])
            #expect(plan.samples.allSatisfy { $0.quantityType == HKQuantityType(.bodyMass) })
            #expect(plan.objects.count == 1)
        }
    }
#endif
