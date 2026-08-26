import Foundation
@testable import HealthLog
import SwiftData
import Testing

@MainActor
@Suite("Authenticated store publication boundary")
struct AuthenticatedStorePublicationBoundaryTests {
    private final class OnlineReachability: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { continuation in
                    continuation.yield(true)
                    continuation.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }

    private actor SuspensionGroup {
        private var entered = 0
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            entered += 1
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitForEntries(_ count: Int) async {
            while entered < count {
                await withCheckedContinuation { entryWaiters.append($0) }
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private actor SuspendedFirst<Value: Sendable> {
        private let group: SuspensionGroup
        private let first: Value
        private let later: Value
        private var requestCount = 0

        init(group: SuspensionGroup, first: Value, later: Value) {
            self.group = group
            self.first = first
            self.later = later
        }

        func next() async -> Value {
            requestCount += 1
            guard requestCount == 1 else { return later }
            await group.suspend()
            return first
        }
    }

    private actor SettingsSequenceAPI: APIClientProtocol {
        private let group: SuspensionGroup
        private var profileRequests = 0
        private var configRequests = 0
        private var extrasRequests = 0

        init(group: SuspensionGroup) {
            self.group = group
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            switch request.path {
            case "/api/user/profile":
                profileRequests += 1
                return try cast(profileRequests == 1 ? Self.accountAProfile : Self.accountBProfile)
            case "/api/integrations/healthkit":
                configRequests += 1
                return try cast(
                    HealthKitSyncConfig(
                        entries: [],
                        lastSyncedAt: configRequests == 1 ? .distantPast : .distantFuture
                    )
                )
            case "/api/auth/me":
                extrasRequests += 1
                if extrasRequests == 1 {
                    await group.suspend()
                    return try cast(Self.accountAExtras)
                }
                return try cast(Self.accountBExtras)
            default:
                throw HLError.unknown("unexpected matrix settings request")
            }
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("matrix settings download is not used")
        }

        private func cast<T>(_ value: some Sendable) throws -> T {
            guard let typed = value as? T else {
                throw HLError.decoding("matrix settings fixture type mismatch")
            }
            return typed
        }

        private static let accountAProfile = UserProfile(
            username: "account-a",
            displayName: "Account A",
            dateOfBirth: nil,
            gender: nil,
            heightCm: nil,
            locale: "de",
            timezone: "Europe/Berlin"
        )
        private static let accountBProfile = UserProfile(
            username: "account-b",
            displayName: "Account B",
            dateOfBirth: nil,
            gender: nil,
            heightCm: nil,
            locale: "en",
            timezone: "America/New_York"
        )
        private static let accountAExtras = AuthMeServerPrefs(
            avatarUrl: "/private/account-a-avatar",
            unitPreference: "imperial",
            glucoseUnit: nil,
            disableCoach: nil,
            cycleTrackingEnabled: true
        )
        private static let accountBExtras = AuthMeServerPrefs(
            avatarUrl: "/private/account-b-avatar",
            unitPreference: "metric",
            glucoseUnit: nil,
            disableCoach: nil,
            cycleTrackingEnabled: false
        )
    }

    // 09-08 — six store families are suspended, switched and resumed inside ONE
    // arrangement, because the property under test is that a late account-A
    // effect is rejected by all six *of the same session*. Splitting it into six
    // tests would give six different sessions and stop proving that.
    // function_body_length exception (owner: 09-08): one shared session arrangement across six families.
    // swiftlint:disable function_body_length
    @Test("allSixComposedStoreFamiliesRejectLateAccountAEffects")
    func allSixComposedStoreFamiliesRejectLateAccountAEffects() async throws {
        let group = SuspensionGroup()
        let registry = AuthenticatedSessionLeaseRegistry()
        let keychain = InMemoryKeychain()
        try keychain.setString("account-a", forKey: KeychainKey.userID)
        _ = try #require(registry.activate(ownerID: "account-a"))

        let dashboardAPI = StubAPIClient()
        let dashboardResponses = SuspendedFirst(
            group: group,
            first: Self.dashboardSummary(label: "Account A"),
            later: Self.dashboardSummary(label: "Account B")
        )
        await dashboardAPI.setHandler { request in
            guard request is APIRequest<DashboardSummary> else {
                throw HLError.unknown("unexpected matrix dashboard request")
            }
            return await dashboardResponses.next()
        }
        let dashboard = DashboardStore(
            repo: DashboardRepository(api: dashboardAPI),
            authenticatedSessionRegistry: registry,
            userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )

        let suiteName = "AuthenticatedStorePublicationBoundaryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SettingsStore.unitPreferenceMigratedKey)
        defaults.set(true, forKey: SettingsStore.cycleOptInMigratedKey)
        let settings = SettingsStore(
            repo: SettingsRepository(api: SettingsSequenceAPI(group: group)),
            defaults: defaults,
            authenticatedSessionRegistry: registry,
            userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )

        let measurementsAPI = StubAPIClient()
        let measurementResponses = SuspendedFirst(
            group: group,
            first: MeasurementListWireResponse(measurements: [Self.measurementWire(id: "account-a-measurement")]),
            later: MeasurementListWireResponse(measurements: [Self.measurementWire(id: "account-b-measurement")])
        )
        await measurementsAPI.setHandler { request in
            if request is APIRequest<MeasurementSeries> {
                return MeasurementSeries(
                    kind: .steps,
                    points: [],
                    stats: SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0)
                )
            }
            guard request is APIRequest<MeasurementListWireResponse> else {
                throw HLError.unknown("unexpected matrix measurements request")
            }
            return await measurementResponses.next()
        }

        let medicationsAPI = StubAPIClient()
        let medicationResponses = SuspendedFirst(
            group: group,
            first: [Self.medicationWire(id: "account-a-medication", name: "Account A")],
            later: [Self.medicationWire(id: "account-b-medication", name: "Account B")]
        )
        await medicationsAPI.setHandler { request in
            switch request {
            case is APIRequest<[MedicationWireDTO]>:
                return await medicationResponses.next()
            case is APIRequest<[MedicationIntake]>:
                return [MedicationIntake]()
            case is APIRequest<[ComplianceDay]>:
                return [ComplianceDay]()
            case is APIRequest<MedicationListLayout>:
                return MedicationListLayout.default
            case is APIRequest<[MedicationComplianceSummaryEntry]>:
                return [MedicationComplianceSummaryEntry]()
            case is APIRequest<MedicationCompliancePayload>:
                return Self.compliancePayload(rate: 91)
            default:
                throw HLError.unknown("unexpected matrix medications request")
            }
        }

        let outbox = try OutboxQueue(inMemory: true)
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: OnlineReachability())
        let core = AppContainer.makeMeasurementsAndMedications(
            measurementsRepo: MeasurementsRepository(api: measurementsAPI, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: medicationsAPI, outbox: outbox),
            healthKit: nil,
            undo: UndoCoordinator(),
            celebration: CelebrationCoordinator(),
            personalRecordsSnapshotBox: PersonalRecordsSnapshotBox(),
            swr: swr,
            keychain: keychain,
            authenticatedSessionRegistry: registry
        )
        let measurements = core.measurements
        let medications = core.medications
        medications.bindAuthenticatedSessionRegistry(
            registry,
            ownerIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )

        let labsAPI = StubAPIClient()
        let labResponses = SuspendedFirst(
            group: group,
            first: ListLabResultsResponse(
                results: [Self.lab(id: "account-a-lab")],
                meta: LabResultsListMeta(total: 1, limit: 500, offset: 0)
            ),
            later: ListLabResultsResponse(
                results: [Self.lab(id: "account-b-lab")],
                meta: LabResultsListMeta(total: 1, limit: 500, offset: 0)
            )
        )
        let biomarkerResponses = SuspendedFirst(
            group: group,
            first: ListBiomarkersResponse(biomarkers: [Self.biomarker(id: "account-a-marker")]),
            later: ListBiomarkersResponse(biomarkers: [Self.biomarker(id: "account-b-marker")])
        )
        await labsAPI.setHandler { request in
            if request is APIRequest<ListLabResultsResponse> {
                return await labResponses.next()
            }
            if request is APIRequest<ListBiomarkersResponse> {
                return await biomarkerResponses.next()
            }
            throw HLError.unknown("unexpected matrix labs request")
        }
        let labs = try LabsStore(
            repository: LabsRepository(api: labsAPI, outbox: OutboxQueue(inMemory: true))
        )
        labs.bindAuthenticatedSessionRegistry(
            registry,
            ownerIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )

        let documentsAPI = StubAPIClient()
        let usageResponses = SuspendedFirst(
            group: group,
            first: Self.usage(usedBytes: 100),
            later: Self.usage(usedBytes: 7)
        )
        let documentResponses = SuspendedFirst(
            group: group,
            first: InboundDocumentDetail(document: Self.document(id: "shared", title: "Account A"), facts: []),
            later: InboundDocumentDetail(document: Self.document(id: "shared", title: "Account B"), facts: [])
        )
        await documentsAPI.setHandler { request in
            if request is APIRequest<DocumentUsage> {
                return await usageResponses.next()
            }
            if request is APIRequest<InboundDocumentDetail> {
                return await documentResponses.next()
            }
            if request is APIRequest<InboundDocumentList> {
                return InboundDocumentList(documents: [], nextCursor: nil)
            }
            throw HLError.unknown("unexpected matrix documents request")
        }
        let documents = DocumentsStore(repository: DocumentsRepository(api: documentsAPI))
        documents.bindAuthenticatedSessionRegistry(
            registry,
            ownerIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
        )

        let dashboardALoad = Task { @MainActor in await dashboard.load(force: true) }
        let settingsALoad = Task { @MainActor in await settings.load() }
        let measurementsALoad = Task { @MainActor in await measurements.load(limit: 1, force: true) }
        let medicationsALoad = Task { @MainActor in await medications.load(force: true) }
        let labsALoad = Task { @MainActor in await labs.load() }
        let documentsALoad = Task { @MainActor in await documents.load() }
        let documentAWrite = Task { @MainActor in
            await documents.updateMetadata(id: "shared", .title("Account A"))
        }
        await group.waitForEntries(8)

        registry.invalidate()
        await swr.invalidateAll()
        await dashboard.awaitAuthenticatedSessionQuiescence()
        await measurements.cancelAndDrainAuthenticatedWork()
        await medications.awaitAuthenticatedSessionQuiescence()
        dashboard.clearOnLogout()
        settings.clearOnLogout()
        measurements.clearOnLogout()
        medications.clearOnLogout()
        labs.clearOnLogout()
        documents.clearOnLogout()

        try keychain.setString("account-b", forKey: KeychainKey.userID)
        _ = try #require(registry.activate(ownerID: "account-b"))
        async let dashboardBLoad: Void = dashboard.load(force: true)
        async let settingsBLoad: Void = settings.load()
        _ = await (dashboardBLoad, settingsBLoad)

        let accountBMeasurement = Self.measurement(id: "account-b-measurement")
        measurements.recent = [accountBMeasurement]
        let accountBMedication = Self.medication(id: "account-b-medication", name: "Account B")
        medications._testForceSet(medications: [accountBMedication])
        medications._testForceSet(cardSnapshot: .init(rate7: 44, rate30: 55), for: accountBMedication.id)
        let accountBLab = Self.lab(id: "account-b-lab")
        let accountBMarker = Self.biomarker(id: "account-b-marker")
        labs.seedForTesting(labs: [accountBLab], biomarkers: [accountBMarker])
        let accountBDocument = Self.document(id: "shared", title: "Account B")
        let accountBUsage = Self.usage(usedBytes: 7)
        documents.seedForTesting(documents: [accountBDocument], usage: accountBUsage, selection: ["shared"])
        documents.filter = DocumentListFilter(q: "account-b")

        var medicationCallbacks = 0
        medications.onMedicationsDidChange = { _ in medicationCallbacks += 1 }
        await group.release()
        let staleWriteResult = await documentAWrite.value
        _ = await (
            dashboardALoad.value,
            settingsALoad.value,
            measurementsALoad.value,
            medicationsALoad.value,
            labsALoad.value,
            documentsALoad.value
        )

        #expect(dashboard.summary?.greeting.salutation == "Account B")
        #expect(!dashboard.isLoading && dashboard.error == nil)
        #expect(settings.profile?.username == "account-b")
        #expect(settings.unitPreference == .metric)
        #expect(!settings.isLoading && settings.error == nil)
        #expect(measurements.recent == [accountBMeasurement])
        #expect(!measurements.isLoading && measurements.error == nil)
        #expect(medications.medications == [accountBMedication])
        #expect(medications.complianceCardSnapshots[accountBMedication.id]?.rate7 == 44)
        #expect(medicationCallbacks == 0 && !medications.isLoading && medications.error == nil)
        #expect(labs.labs == [accountBLab] && labs.biomarkers == [accountBMarker])
        #expect(!labs.isLoading && labs.lastError == nil)
        #expect(documents.documents == [accountBDocument])
        #expect(documents.usage == accountBUsage && documents.filter.q == "account-b")
        #expect(documents.selection == ["shared"] && !documents.isLoading && documents.lastError == nil)
        #expect(staleWriteResult == nil)
    }

    // swiftlint:enable function_body_length

    @Test("sameOwnerReloginInvalidatesEveryComposedFamilyLease")
    func sameOwnerReloginInvalidatesEveryComposedFamilyLease() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        _ = try #require(registry.activate(ownerID: "same-owner"))
        let familyLeases = Dictionary(uniqueKeysWithValues: [
            "dashboard", "settings", "measurements", "medications", "labs", "documents"
        ].compactMap { family in
            registry.capture(ownerID: "same-owner").map { (family, $0) }
        })
        #expect(familyLeases.count == 6)

        registry.invalidate()
        _ = try #require(registry.activate(ownerID: "same-owner"))

        #expect(familyLeases.values.allSatisfy { !$0.isCurrent })
        #expect(
            familyLeases.values.allSatisfy { oldLease in
                guard let current = registry.capture(ownerID: "same-owner") else { return false }
                return current.isCurrent && current.generation != oldLease.generation
            }
        )
    }

    private nonisolated static func dashboardSummary(label: String) -> DashboardSummary {
        DashboardSummary(
            greeting: Greeting(salutation: label, date: Date(timeIntervalSince1970: 1_700_000_000)),
            compliance: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            highlightInsight: nil,
            metrics: [],
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private nonisolated static func measurementWire(id: String) -> MeasurementWireDTO {
        MeasurementWireDTO(
            id: id,
            type: .weight,
            value: 72,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private nonisolated static func measurement(id: String) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: id,
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(72)
        )
    }

    private nonisolated static func medicationWire(id: String, name: String) -> MedicationWireDTO {
        MedicationWireDTO(
            id: id,
            name: name,
            dose: "1 mg",
            schedules: [MedicationScheduleDTO(windowStart: "08:00")]
        )
    }

    private nonisolated static func medication(id: String, name: String) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: "1 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
    }

    private nonisolated static func compliancePayload(rate: Int) -> MedicationCompliancePayload {
        let window = ComplianceWindowResult(
            totalExpected: 1,
            taken: 1,
            skipped: 0,
            missed: 0,
            rate: rate,
            streak: 1
        )
        return MedicationCompliancePayload(compliance7: window, compliance30: window)
    }

    private nonisolated static func lab(id: String) -> LabResultDTO {
        LabResultDTO(
            id: id,
            biomarkerId: nil,
            panel: "Panel",
            analyte: id,
            value: 1,
            unit: "unit",
            referenceLow: nil,
            referenceHigh: nil,
            takenAt: "2026-08-14T08:00:00.000Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: .inRange,
            createdAt: "2026-08-14T08:00:00.000Z",
            updatedAt: "2026-08-14T08:00:00.000Z"
        )
    }

    private nonisolated static func biomarker(id: String) -> BiomarkerDTO {
        BiomarkerDTO(
            id: id,
            name: id,
            unit: "unit",
            lowerBound: nil,
            upperBound: nil,
            panel: "Panel",
            hasContext: false,
            context: nil,
            createdAt: "2026-08-14T08:00:00.000Z",
            updatedAt: "2026-08-14T08:00:00.000Z"
        )
    }

    private nonisolated static func document(id: String, title: String) -> InboundDocument {
        InboundDocument(
            id: id,
            kind: .other,
            title: title,
            filename: "document.pdf",
            mimeType: "application/pdf",
            byteSize: 1,
            status: .stored,
            providerType: nil,
            reportDate: nil,
            documentDate: "2026-08-14",
            errorReason: nil,
            factCount: 0,
            pendingCount: 0,
            conditionLinks: [],
            servingClass: .inline,
            createdAt: "2026-08-14T08:00:00.000Z",
            updatedAt: "2026-08-14T08:00:00.000Z"
        )
    }

    private nonisolated static func usage(usedBytes: Int) -> DocumentUsage {
        DocumentUsage(
            usedBytes: usedBytes,
            quotaBytes: 1000,
            maxFileBytes: 500,
            acceptedExtensions: [".pdf"],
            linkedEpisodes: []
        )
    }
}
