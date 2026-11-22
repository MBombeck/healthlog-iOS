import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// Server 1.48.0 removed Fitbit (#182, part A 1): no Fitbit entry in
/// `integrations[]`, a top-level `fitbitRemovalNotice`, a dismiss route, and
/// `410 route.retired` on every former Fitbit write. Each point once against a
/// 1.48 server and once against an older one that still lists Fitbit.
@MainActor
@Suite("Fitbit removal (server 1.48): row, note, dismiss, route.retired", .serialized, .mockURLSession)
struct FitbitRemovalTests {
    /// `METHOD path` of every request the mock answered.
    final class RequestLog: Sendable {
        let entries = Mutex<[String]>([])
    }

    private nonisolated static let removedWithNotice = #"""
    {"data":{"threshold":3,"metricFreshnessDegraded":false,"integrations":[
      {"integration":"withings","connected":false},
      {"integration":"google-health","connected":false}
    ],"fitbitRemovalNotice":true},"error":null}
    """#

    private nonisolated static let removedWithoutNotice = #"""
    {"data":{"integrations":[{"integration":"withings","connected":false}],"fitbitRemovalNotice":false},"error":null}
    """#

    private nonisolated static let olderWithRetirement = #"""
    {"data":{"integrations":[
      {"integration":"fitbit","connected":true,
       "retirement":{"endsOn":"2026-10-30","ended":true,"successor":"google-health","offered":true}}
    ]},"error":null}
    """#

    private nonisolated static let routeRetired = #"""
    {"data":null,"error":"This endpoint was removed in v1.48.0","meta":{"errorCode":"route.retired","removedIn":"1.48.0","replacedBy":null}}
    """#

    /// The 1.48 compatibility bridge: always 200, never connected.
    private nonisolated static let bridgeStatus = #"{"data":{"connected":false,"configured":false,"retired":true},"error":null}"#

    private static func makeAPI() -> APIClient {
        APIClient(
            environment: AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.7.0",
                buildNumber: "1"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
    }

    private static func fitbitCore() -> OAuthIntegrationCore {
        OAuthIntegrationCore(repo: OAuthIntegrationRepository(api: makeAPI(), provider: .fitbit), provider: .fitbit)
    }

    /// Answers the consolidated read with `consolidated`, `/api/fitbit/status`
    /// with `fitbitStatus`, the dismiss route with `{dismissed:true}` and every
    /// other path (the former Fitbit writes) with `writeStatus`/`writeBody`.
    /// Records `METHOD path` of every request.
    private static func install(
        consolidated: String,
        fitbitStatus: String = bridgeStatus,
        writeStatus: Int = 410,
        writeBody: String = routeRetired,
        log: RequestLog
    ) {
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            log.entries.withLock { $0.append("\(req.httpMethod ?? "") \(path)") }
            let (status, body): (Int, String) = switch path {
            case "/api/integrations/status": (200, consolidated)
            case "/api/fitbit/status": (200, fitbitStatus)
            case "/api/integrations/fitbit-removal-notice/dismiss": (200, #"{"data":{"dismissed":true},"error":null}"#)
            default: (writeStatus, writeBody)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    // MARK: - Row

    @Test("1.48: no Fitbit entry hides the row, and Fitbit is never connectable")
    func newServerHidesRow() async {
        let log = RequestLog()
        Self.install(consolidated: Self.removedWithoutNotice, log: log)
        let core = Self.fitbitCore()
        #expect(!core.isOffered, "before the read the row stays away, no flash of a dead row")
        await core.loadStatus()
        #expect(core.fitbitListed == false)
        #expect(!core.isOffered, "an account that never had Fitbit sees no Fitbit row")
        #expect(core.isRetired, "nothing offers to connect Fitbit")
        #expect(!core.showsRemovalNotice)
        #expect(core.error == nil)
    }

    @Test("Older server with retirement: the row and the dated notice stay as before")
    func olderServerKeepsRow() async throws {
        let log = RequestLog()
        Self.install(
            consolidated: Self.olderWithRetirement,
            fitbitStatus: #"{"data":{"connected":true,"configured":true},"error":null}"#,
            log: log
        )
        let core = Self.fitbitCore()
        await core.loadStatus()
        #expect(core.fitbitListed == true)
        #expect(core.isOffered)
        #expect(core.isRetired)
        #expect(!core.showsRemovalNotice, "an older server sends no removal note")
        let retirement = try #require(core.retirement)
        #expect(retirement.endsOn == "2026-10-30")
        #expect(retirement.notice != String(localized: "integration.fitbit.retired.endedNoDate"))
    }

    @Test("A server that lists Fitbit without retirement no longer offers to connect it")
    func listedWithoutRetirementIsRetired() async {
        let log = RequestLog()
        Self.install(
            consolidated: #"{"data":{"integrations":[{"integration":"fitbit","connected":false}]},"error":null}"#,
            log: log
        )
        let core = Self.fitbitCore()
        await core.loadStatus()
        #expect(core.isOffered)
        #expect(core.isRetired)
        #expect(core.retirement?.notice == String(localized: "integration.fitbit.retired.endedNoDate"))
    }

    @Test("Other providers are untouched: always offered, never retired")
    func otherProvidersUntouched() async {
        let log = RequestLog()
        Self.install(consolidated: Self.removedWithNotice, log: log)
        let oura = OAuthIntegrationCore(repo: OAuthIntegrationRepository(api: Self.makeAPI(), provider: .oura), provider: .oura)
        await oura.loadStatus()
        #expect(oura.isOffered)
        #expect(!oura.isRetired)
        #expect(!oura.showsRemovalNotice)
        #expect(!log.entries.withLock { $0 }.contains("GET /api/integrations/status"), "only Fitbit reads the consolidated status")
    }

    // MARK: - Note

    @Test("1.48: fitbitRemovalNotice true shows the note; dismiss hides it and posts the dismiss route once")
    func noticeAndDismiss() async {
        let log = RequestLog()
        Self.install(consolidated: Self.removedWithNotice, log: log)
        let core = Self.fitbitCore()
        await core.loadStatus()
        #expect(core.showsRemovalNotice)
        #expect(!core.isOffered, "the note replaces the row, not both")

        await core.dismissRemovalNotice()
        #expect(!core.showsRemovalNotice)
        await core.dismissRemovalNotice()
        let dismisses = log.entries.withLock { $0 }.filter { $0 == "POST /api/integrations/fitbit-removal-notice/dismiss" }
        #expect(dismisses.count == 1, "a second tap has nothing left to clear")
    }

    @Test("A dismiss that does not land hides the note locally; the next read decides again")
    func dismissFailureIsQuiet() async {
        let log = RequestLog()
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            log.entries.withLock { $0.append(path) }
            let (status, body): (Int, String) = switch path {
            case "/api/integrations/status": (200, Self.removedWithNotice)
            case "/api/fitbit/status": (200, Self.bridgeStatus)
            default: (500, #"{"data":null,"error":"boom"}"#)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let core = Self.fitbitCore()
        await core.loadStatus()
        await core.dismissRemovalNotice()
        #expect(!core.showsRemovalNotice)
        #expect(core.error == nil, "the note is not the connection; its dismiss never paints an error")
        await core.loadStatus()
        #expect(core.showsRemovalNotice, "the server still holds it, so it comes back")
    }

    @Test("Payload: the note is read only when the server sends a Bool")
    func payloadDecoding() throws {
        let decode = { (json: String) in
            try JSONDecoder.hlDefault.decode(IntegrationsRetirementPayload.self, from: Data(json.utf8)).fitbitState
        }
        let new = try decode(#"{"integrations":[{"integration":"withings"}],"fitbitRemovalNotice":true}"#)
        #expect(new == FitbitConsolidatedState(listed: false, retirement: nil, removalNotice: true))
        let older = try decode(#"{"integrations":[{"integration":"fitbit"}]}"#)
        #expect(older.listed)
        #expect(older.removalNotice == nil)
        let odd = try decode(#"{"integrations":[],"fitbitRemovalNotice":"yes"}"#)
        #expect(odd.removalNotice == nil, "a malformed flag shows no note")
    }

    @Test("Logout forgets the note and the listing")
    func logoutClears() async {
        let log = RequestLog()
        Self.install(consolidated: Self.removedWithNotice, log: log)
        let core = Self.fitbitCore()
        await core.loadStatus()
        core.clearOnLogout()
        #expect(!core.showsRemovalNotice)
        #expect(core.fitbitListed == nil)
    }

    // MARK: - 410 route.retired

    @Test("410 route.retired is the retirement, not an error")
    func routeRetiredRecognised() {
        #expect(FitbitRetirement.isRetiredRefusal(HLError.server(status: 410, code: "route.retired", message: "")))
        #expect(FitbitRetirement.isRetiredRefusal(HLError.server(status: 410, code: "provider_retired", message: "")))
        #expect(FitbitRetirement.isRetiredRefusal(HLError.server(status: 410, code: nil, message: "")))
        #expect(!FitbitRetirement.isRetiredRefusal(HLError.server(status: 404, code: nil, message: "")))
        #expect(!FitbitRetirement.isRetiredRefusal(HLError.server(status: 410, code: "glp1.doseChange.deleted", message: "")))
    }

    @Test("1.48: disconnect, resume, sync, test and credentials that hit route.retired end quietly")
    func everyActionAbsorbsRouteRetired() async {
        let log = RequestLog()
        Self.install(
            consolidated: Self.olderWithRetirement,
            fitbitStatus: #"{"data":{"connected":true,"configured":true},"error":null}"#,
            log: log
        )
        let core = Self.fitbitCore()
        await core.loadStatus()

        await core.disconnect()
        #expect(core.error == nil)
        await core.resume()
        #expect(core.error == nil)
        await core.syncNow()
        #expect(core.error == nil)
        #expect(core.syncState == .idle)
        await core.testConnection()
        #expect(core.error == nil)
        let saved = await core.saveCredentials(clientId: "id", clientSecret: "secret")
        #expect(!saved)
        #expect(core.error == nil)
        await core.deleteCredentials()
        #expect(core.error == nil)
        #expect(core.isRetired)

        // Another provider's route.retired is still that provider's error.
        let oura = OAuthIntegrationCore(repo: OAuthIntegrationRepository(api: Self.makeAPI(), provider: .oura), provider: .oura)
        await oura.disconnect()
        #expect(oura.error != nil)
    }
}

// swiftlint:enable force_unwrapping
