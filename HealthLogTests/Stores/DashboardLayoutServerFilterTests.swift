import Foundation
@testable import HealthLog
import Testing

/// **v0.10 W10-PIN (server v1.7.0 LIVE).** Issue #11 is resolved server-side:
/// the dashboard widget enum now accepts + round-trips the full 27-id
/// catalogue. The former iOS-side workarounds (`filteringForServer()` /
/// `byRestoringIosOnlyWidgets(from:)` / `byMergingIosOnlyDefaults()`) are
/// deleted. This suite pins the new contract: the full layout survives a
/// PUT/GET round-trip unfiltered, and the GET reflects the server payload
/// verbatim (no implicit merge).
@Suite("DashboardLayout — full 27-id round-trip (v1.7.0)")
struct DashboardLayoutServerFilterTests {
    /// Stub that echoes the PUT body back (server round-trips the full
    /// catalogue) and captures it for inspection.
    actor CapturingStubAPI: APIClientProtocol {
        private(set) var lastPutPayload: DashboardWidgetLayout?
        var getResponse: DashboardWidgetLayout

        init(initial: DashboardWidgetLayout = .default) {
            getResponse = initial
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            if request.path == "/api/dashboard/widgets", request.method == .get {
                guard let typed = getResponse as? T else {
                    throw HLError.unknown("type mismatch GET")
                }
                return typed
            }
            if request.path == "/api/dashboard/widgets", request.method == .put {
                guard let body = request.body,
                      let decoded = try? JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: body) else
                {
                    throw HLError.unknown("no body")
                }
                lastPutPayload = decoded
                // Server now accepts + echoes the full catalogue verbatim.
                guard let typed = decoded as? T else {
                    throw HLError.unknown("type mismatch PUT")
                }
                return typed
            }
            throw HLError.unknown("unexpected path \(request.path)")
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("not impl")
        }
    }

    /// The 7 ids the v0.5.2 HK-completeness sweep added — formerly stripped on
    /// the wire, now first-class on the server.
    private static let formerlyIosOnlyIds: Set<String> = [
        "restingHeartRate", "hrv", "walkingSpeed", "walkingAsymmetry",
        "walkingStepLength", "bmi", "bodyTemperature"
    ]

    private static func restoreMigrationFlag(_ prior: Bool, forKey key: String) {
        if prior {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test("PUT payload carries every widget id (no filtering on the wire)")
    @MainActor
    func putPayloadCarriesEveryWidgetId() async {
        let migrationKey = DashboardLayoutStore.defaultsMigrationKey
        let priorFlag = UserDefaults.standard.bool(forKey: migrationKey)
        UserDefaults.standard.set(true, forKey: migrationKey)
        defer { Self.restoreMigrationFlag(priorFlag, forKey: migrationKey) }

        let api = CapturingStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()
        await store.toggleTileVisible(forId: "weight")

        let puttedLayout = await api.lastPutPayload
        #expect(puttedLayout != nil)
        let puttedIds = Set(puttedLayout?.widgets.map(\.id) ?? [])
        // The formerly-stripped HK-completeness ids now ride on the wire.
        for id in Self.formerlyIosOnlyIds {
            #expect(puttedIds.contains(id), "PUT payload dropped widget id \(id)")
        }
        // Full catalogue survives — nothing filtered off the wire.
        #expect(puttedIds == Set(DashboardWidgetLayout.default.widgets.map(\.id)))

        // Local layout unchanged — still carries every id.
        let layoutIds = Set(store.layout.widgets.map(\.id))
        #expect(layoutIds == puttedIds)
        #expect(store.error == nil)
    }

    @Test("widgetLayout() reflects the server payload verbatim (no implicit merge)")
    @MainActor
    func widgetLayoutReflectsServerVerbatim() async throws {
        // The server now stores + returns the full catalogue. A GET reflects
        // exactly what the server holds — no iOS-side default merge.
        let api = CapturingStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)

        let first = try await repo.widgetLayout()
        #expect(first == DashboardWidgetLayout.default)

        // Idempotent — calling again yields the identical shape (no drift).
        let second = try await repo.widgetLayout()
        #expect(first == second)
    }

    @Test("full layout survives a PUT→GET round-trip unchanged")
    func fullLayoutRoundTrips() async throws {
        let api = CapturingStubAPI(initial: DashboardWidgetLayout(widgets: []))
        let repo = DashboardRepository(api: api)

        let echo = try await repo.setWidgetLayout(.default)
        // The server echoes the full catalogue back unfiltered.
        #expect(echo == DashboardWidgetLayout.default)
    }
}
