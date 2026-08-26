import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// `@MainActor @Observable` ``EnvironmentStore`` behaviour (Build 7 Item 7.7),
/// driven through the **real** ``APIClient`` + `MockURLProtocol`. Covers the
/// success load, the module-gate "sinnvoll leer" disabled state, the
/// always-present Open-Meteo attribution, and the logout wipe.
///
/// `@MainActor` (the store is main-actor isolated) + `.serialized` (the shared
/// `MockURLProtocol.handler`).
@Suite("EnvironmentStore — load, module gate, attribution, logout", .serialized)
@MainActor
struct EnvironmentStoreTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("bearer-abc", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeStore() -> EnvironmentStore {
        EnvironmentStore(repository: EnvironmentRepository(api: makeClient()))
    }

    private nonisolated static func ok(_ dataJSON: String, url: URL) -> (HTTPURLResponse, Data?) {
        let body = #"{"data":\#(dataJSON),"error":null}"#
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    private nonisolated static func moduleDisabled(url: URL) -> (HTTPURLResponse, Data?) {
        let body = #"{"data":null,"error":"disabled","meta":{"errorCode":"module.disabled","module":"environment"}}"#
        return (HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    @Test("Attribution is present from the first frame, before any load")
    func attributionPresentInitially() {
        let store = makeStore()
        #expect(store.attribution == EnvironmentOverviewDTO.defaultAttribution)
        #expect(!store.attribution.isEmpty)
        #expect(!store.hasLoaded)
    }

    @Test("A successful load populates the snapshot and keeps the attribution")
    func successfulLoad() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            let home = #"{"lat":51.48,"lon":7.22,"label":"Bochum","timezone":"Europe/Berlin","since":"2026-01-01T00:00:00Z"}"#
            let trip = #"{"id":"t1","startDate":"2026-06-01","endDate":"2026-06-08","lat":48.1,"lon":11.6,"label":"Munich"}"#
            let ctx = #"{"days":9,"latestDate":"2026-07-20","latestFetchedAt":"2026-07-21T03:00:00Z"}"#
            return Self.ok(
                #"{"home":\#(home),"travel":[\#(trip)],"context":\#(ctx),"attribution":"Weather data by Open-Meteo.com"}"#,
                url: req.url!
            )
        }

        await store.load()

        #expect(store.hasLoaded)
        #expect(store.isDisabled == false)
        #expect(store.lastError == nil)
        #expect(store.hasHome)
        #expect(store.home?.label == "Bochum")
        #expect(store.travel.count == 1)
        #expect(store.context.days == 9)
        #expect(store.hasContent)
        #expect(store.attribution == "Weather data by Open-Meteo.com")
    }

    @Test("A 403 module.disabled flips isDisabled — sinnvoll leer, no error, attribution intact")
    func moduleDisabledIsSensiblyEmpty() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in Self.moduleDisabled(url: req.url!) }

        await store.load()

        #expect(store.isDisabled)
        #expect(store.lastError == nil, "a disabled module is not an error state")
        #expect(store.hasLoaded)
        #expect(!store.hasContent)
        #expect(store.home == nil)
        #expect(store.travel.isEmpty)
        // LICENCE: the Open-Meteo credit is present even in the disabled state.
        #expect(store.attribution == EnvironmentOverviewDTO.defaultAttribution)
        #expect(!store.attribution.isEmpty)
    }

    @Test("clearOnLogout wipes the snapshot but keeps the canonical attribution")
    func logoutWipes() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            let ctx = #"{"days":5,"latestDate":"2026-07-20"}"#
            return Self.ok(
                #"{"home":{"lat":1,"lon":2,"label":"X"},"travel":[],"context":\#(ctx),"attribution":"Weather data by Open-Meteo.com"}"#,
                url: req.url!
            )
        }
        await store.load()
        #expect(store.context.days == 5)

        store.clearOnLogout()

        #expect(store.home == nil)
        #expect(store.travel.isEmpty)
        #expect(store.context.days == 0)
        #expect(store.hasLoaded == false)
        #expect(store.isDisabled == false)
        #expect(store.lastError == nil)
        // Attribution is a constant, not user data — stays present for next user.
        #expect(store.attribution == EnvironmentOverviewDTO.defaultAttribution)
    }
}
