import Foundation
@testable import HealthLog
import SwiftData
import Testing

@Suite("Authenticated dashboard and settings boundaries")
struct AuthenticatedDashboardSettingsBoundaryTests {
    private final class SessionOwnerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ownerID: String?

        init(_ ownerID: String?) {
            self.ownerID = ownerID
        }

        func read() -> String? {
            lock.withLock { ownerID }
        }

        func set(_ ownerID: String?) {
            lock.withLock { self.ownerID = ownerID }
        }
    }

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

    private actor SuspensionGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWaitForRelease() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor SettingsBoundaryAPI: APIClientProtocol {
        private let accountAExtrasGate = SuspensionGate()
        private let accountBExtrasGate = SuspensionGate()
        private var profileRequests = 0
        private var configRequests = 0
        private var extrasRequests = 0

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            switch request.path {
            case "/api/user/profile":
                profileRequests += 1
                return try cast(profileRequests == 1 ? Self.accountAProfile : Self.accountBProfile)
            case "/api/integrations/healthkit":
                configRequests += 1
                return try cast(configRequests == 1 ? Self.accountAConfig : Self.accountBConfig)
            case "/api/auth/me":
                extrasRequests += 1
                if extrasRequests == 1 {
                    await accountAExtrasGate.enterAndWaitForRelease()
                    return try cast(Self.accountAExtras)
                }
                await accountBExtrasGate.enterAndWaitForRelease()
                return try cast(Self.accountBExtras)
            default:
                throw HLError.unknown("unexpected settings boundary request")
            }
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("download is not used")
        }

        func waitUntilAccountAExtrasStarted() async {
            await accountAExtrasGate.waitUntilEntered()
        }

        func waitUntilAccountBExtrasStarted() async {
            await accountBExtrasGate.waitUntilEntered()
        }

        func releaseAccountAExtras() async {
            await accountAExtrasGate.release()
        }

        func releaseAccountBExtras() async {
            await accountBExtrasGate.release()
        }

        private func cast<T>(_ value: some Sendable) throws -> T {
            guard let typed = value as? T else {
                throw HLError.decoding("settings boundary fixture type mismatch")
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

        private static let accountAConfig = HealthKitSyncConfig(entries: [], lastSyncedAt: .distantPast)
        private static let accountBConfig = HealthKitSyncConfig(entries: [], lastSyncedAt: .distantFuture)
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

    @Test("lateAccountAResponseCannotPublishIntoB")
    @MainActor
    func lateAccountAResponseCannotPublishIntoB() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: OnlineReachability())
        let api = StubAPIClient()
        let gate = SuspensionGate()
        let accountA = Self.dashboardSummary(label: "Account A")
        let accountB = Self.dashboardSummary(label: "Account B")
        await api.setHandler { request in
            guard request is APIRequest<DashboardSummary> else {
                throw HLError.unknown("unexpected dashboard boundary request")
            }
            await gate.enterAndWaitForRelease()
            return accountA
        }

        let registry = AuthenticatedSessionLeaseRegistry()
        let owner = SessionOwnerBox("account-a")
        _ = registry.activate(ownerID: "account-a")
        let store = DashboardStore(
            repo: DashboardRepository(api: api),
            swr: swr,
            authenticatedSessionRegistry: registry,
            userIDProvider: owner.read
        )
        let loadTask = Task { @MainActor in await store.load(force: true) }
        await gate.waitUntilEntered()

        registry.invalidate()
        await swr.invalidateAll()
        _ = registry.activate(ownerID: "account-b")
        owner.set("account-b")
        store.clearOnLogout()
        store.seedSummaryForTesting(accountB)
        await gate.release()
        await loadTask.value

        #expect(
            store.summary == accountB,
            "EXPECTED_RED: late A response published into B"
        )
    }

    @Test("lateAccountATerminalStateCannotRepaintB")
    @MainActor
    func lateAccountATerminalStateCannotRepaintB() async throws {
        let suite = "AuthenticatedDashboardSettingsBoundaryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SettingsStore.unitPreferenceMigratedKey)
        defaults.set(true, forKey: SettingsStore.cycleOptInMigratedKey)

        let registry = AuthenticatedSessionLeaseRegistry()
        let owner = SessionOwnerBox("account-a")
        _ = registry.activate(ownerID: "account-a")
        let api = SettingsBoundaryAPI()
        let store = SettingsStore(
            repo: SettingsRepository(api: api),
            defaults: defaults,
            authenticatedSessionRegistry: registry,
            userIDProvider: owner.read
        )
        let accountALoad = Task { @MainActor in await store.load() }
        await api.waitUntilAccountAExtrasStarted()

        registry.invalidate()
        _ = registry.activate(ownerID: "account-b")
        owner.set("account-b")
        store.clearOnLogout()
        let accountBLoad = Task { @MainActor in await store.load() }
        await api.waitUntilAccountBExtrasStarted()
        await api.releaseAccountAExtras()
        await accountALoad.value

        let accountBStateRemainsCurrent = store.profile?.username == "account-b"
            && store.profile?.avatarUrl == nil
            && store.unitPreference == .metric
            && store.cycleTrackingServerEnabled == nil
            && store.isLoading
            && store.error == nil
        #expect(
            accountBStateRemainsCurrent,
            "EXPECTED_RED: late A terminal state repainted B"
        )

        await api.releaseAccountBExtras()
        await accountBLoad.value
    }

    /// **20-02 / D-14-06-A — the dashboard twin of the test directly above.**
    ///
    /// 13-03 gave `DashboardStore.load()` an **unconditional** covering defer.
    /// That is right for cancellation — the exit 13-03 existed to close — and
    /// wrong across an account boundary: a superseded load's defer still writes
    /// `isLoading = false`, and `isLoading` is an observable, so a retired
    /// generation is publishing. What it publishes over is the skeleton the NEW
    /// account's in-flight load is legitimately showing.
    ///
    /// 14-06 hit exactly this in `SettingsStore` and split the predicate
    /// (`ownsRegistryGeneration` — registry currency WITHOUT the cancellation
    /// fold). The primitive existed; this store's boundary test did not, which
    /// is why the ledger's instruction was to write the test FIRST and watch it
    /// fail rather than to reshape the store from a description.
    ///
    /// Built without an `SWRCoordinator` on purpose: the defect lives in
    /// `load()`'s own defer, which sits ABOVE the `guard let swr`, so the direct
    /// path exercises it exactly — and it keeps two concurrent loads from
    /// collapsing into one round-trip through `revalidateSingleFlight`, which
    /// would make "account B's load is in flight" untrue.
    @Test("lateAccountATerminalStateCannotRepaintDashboardB")
    @MainActor
    func lateAccountATerminalStateCannotRepaintDashboardB() async {
        let api = StubAPIClient()
        let gateA = SuspensionGate()
        let gateB = SuspensionGate()
        let accountA = Self.dashboardSummary(label: "Account A")
        let accountB = Self.dashboardSummary(label: "Account B")
        let requests = RequestCounter()
        await api.setHandler { request in
            guard request is APIRequest<DashboardSummary> else {
                throw HLError.unknown("unexpected dashboard boundary request")
            }
            if requests.next() == 1 {
                await gateA.enterAndWaitForRelease()
                return accountA
            }
            await gateB.enterAndWaitForRelease()
            return accountB
        }

        let registry = AuthenticatedSessionLeaseRegistry()
        let owner = SessionOwnerBox("account-a")
        _ = registry.activate(ownerID: "account-a")
        let store = DashboardStore(
            repo: DashboardRepository(api: api),
            authenticatedSessionRegistry: registry,
            userIDProvider: owner.read
        )

        let accountALoad = Task { @MainActor in await store.load() }
        await gateA.waitUntilEntered()

        registry.invalidate()
        _ = registry.activate(ownerID: "account-b")
        owner.set("account-b")
        // The boundary step production always runs — it is what settles A's
        // flag honestly, and it is why refusing A's own settle strands nothing.
        store.clearOnLogout()

        let accountBLoad = Task { @MainActor in await store.load() }
        await gateB.waitUntilEntered()
        #expect(store.isLoading, "precondition: account B's load is legitimately showing a skeleton")

        await gateA.release()
        await accountALoad.value

        #expect(
            store.isLoading,
            "EXPECTED_RED: a superseded dashboard load's unconditional defer cleared account B's skeleton"
        )
        #expect(store.summary == nil, "and it published no summary either")

        await gateB.release()
        await accountBLoad.value
        #expect(store.summary == accountB, "account B's own load still lands")
        #expect(store.isLoading == false, "and it settles its own flag")
    }

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    private static func dashboardSummary(label: String) -> DashboardSummary {
        DashboardSummary(
            greeting: Greeting(salutation: label, date: Date(timeIntervalSince1970: 1_700_000_000)),
            compliance: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            highlightInsight: nil,
            metrics: [],
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
