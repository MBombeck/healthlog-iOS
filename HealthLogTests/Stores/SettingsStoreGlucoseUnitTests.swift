import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#108 / #115 1.4 — the glucose unit follows the account.**
///
/// Server v1.39.0: `/api/auth/me` carries the raw `User.glucoseUnit` column
/// (`user.glucoseUnit ?? null`, `src/app/api/auth/me/route.ts`), `null`
/// resolves to mg/dL (`resolveGlucoseUnit`, `src/lib/glucose.ts`), and
/// `GET /api/measurements/series` converts glucose into that resolved unit.
/// `PATCH /api/auth/me/glucose-unit` takes `{ "glucoseUnit": "mg/dL" | "mmol/L" }`
/// and echoes `{ data: { glucoseUnit } }` (`GlucoseUnitPatchRequest` /
/// `PatchGlucoseUnitEnvelope`).
///
/// Before the fix the app decoded the field and never used it: the tiles,
/// the entry sheet and the chart summaries converted with a device-only pick
/// while the chart itself arrived in the account's unit. These tests drive the
/// real `SettingsStore` over the real `APIClient` (`MockURLProtocol`).
@MainActor
@Suite("SettingsStore glucose unit follows the account (#108)", .serialized)
struct SettingsStoreGlucoseUnitTests {
    /// Per-test transport (`MockURLProtocolSession`), so a parallel suite can
    /// never answer these requests or count them.
    private let session = MockURLProtocolSession()

    private func makeStore(defaults: UserDefaults) -> SettingsStore {
        let env = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        return SettingsStore(repo: SettingsRepository(api: api), defaults: defaults)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SettingsStoreGlucoseUnitTests.\(UUID().uuidString)")!
    }

    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    /// The account's stored column. `.null` is a v1.39 account that never set
    /// it; `.absent` is an older server whose `/me` has no such key.
    enum ServerColumn: Equatable {
        case absent
        case null
        case value(String)
    }

    private final class RouterState: @unchecked Sendable {
        var column: ServerColumn
        var patchCount = 0
        var lastPatchBody: [String: Any]?
        var failPatchStatus: Int?
        var offline = false
        init(column: ServerColumn, failPatchStatus: Int? = nil) {
            self.column = column
            self.failPatchStatus = failPatchStatus
        }
    }

    private func installRouter(_ state: RouterState) {
        let profileJSON = """
        {"data":{"username":"anna","displayName":"Anna","email":"anna@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":null,"heightCm":175,\
        "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false},"error":null}
        """
        let hkJSON = #"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#
        session.install { req in
            let path = req.url?.path ?? ""
            func ok(_ body: String) -> (HTTPURLResponse, Data?) {
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            switch path {
            case "/api/user/profile":
                return ok(profileJSON)
            case "/api/integrations/healthkit":
                return ok(hkJSON)
            case "/api/auth/me":
                let field = switch state.column {
                case .absent: ""
                case .null: #","glucoseUnit":null"#
                case let .value(unit): #","glucoseUnit":"\#(unit)""#
                }
                return ok(#"{"data":{"id":"u1","username":"anna","avatarUrl":null,"unitPreference":"metric"\#(field)},"error":null}"#)
            case "/api/auth/me/glucose-unit":
                guard req.httpMethod == "PATCH" else { break }
                state.patchCount += 1
                let body = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
                state.lastPatchBody = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if state.offline { throw URLError(.notConnectedToInternet) }
                if let status = state.failPatchStatus {
                    let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                    return (http, Data(#"{"data":null,"error":"nope"}"#.utf8))
                }
                let sent = state.lastPatchBody?["glucoseUnit"] as? String ?? "mg/dL"
                state.column = .value(sent)
                return ok(#"{"data":{"glucoseUnit":"\#(sent)"},"error":null}"#)
            default:
                break
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
    }

    // MARK: - Adoption

    @Test("An account in mmol/L is adopted: tiles, entry and summaries all switch")
    func adoptsAccountUnit() async {
        let defaults = makeDefaults()
        let state = RouterState(column: .value("mmol/L"))
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()

        #expect(store.glucoseUnit == .mmolL)
        #expect(store.unitPreferences.glucose == .mmolL)
        #expect(defaults.string(forKey: "hl.settings.glucoseUnit") == GlucoseUnit.mmolL.rawValue)
        #expect(state.patchCount == 0) // adoption is never a write
    }

    @Test("A web-side switch back to mg/dL is adopted over a stale mmol/L mirror")
    func adoptsOverStaleMirror() async {
        let defaults = makeDefaults()
        defaults.set(GlucoseUnit.mmolL.rawValue, forKey: "hl.settings.glucoseUnit")
        defaults.set(true, forKey: "hl.settings.glucoseUnit.migrated.v1")
        let state = RouterState(column: .value("mg/dL"))
        installRouter(state)

        let store = makeStore(defaults: defaults)
        #expect(store.glucoseUnit == .mmolL) // offline start: the mirror
        await store.load()
        #expect(store.glucoseUnit == .mgdL)
        #expect(state.patchCount == 0)
    }

    @Test("An old server without the key keeps the mirror, and nothing is written")
    func oldServerKeepsMirror() async {
        let defaults = makeDefaults()
        defaults.set(GlucoseUnit.mmolL.rawValue, forKey: "hl.settings.glucoseUnit")
        let state = RouterState(column: .absent)
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.glucoseUnit == .mmolL)
        #expect(state.patchCount == 0)
    }

    // MARK: - One-time migration of a device-only pick

    @Test("A device-only mmol/L pick on a never-set account is written once, and survives a restart")
    func migratesLocalPickOnce() async {
        let defaults = makeDefaults()
        defaults.set(GlucoseUnit.mmolL.rawValue, forKey: "hl.settings.glucoseUnit")
        let state = RouterState(column: .null)
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(state.patchCount == 1)
        #expect(state.lastPatchBody?["glucoseUnit"] as? String == "mmol/L")
        #expect(store.glucoseUnit == .mmolL)

        let restarted = makeStore(defaults: defaults)
        await restarted.load()
        #expect(state.patchCount == 1)
        #expect(restarted.glucoseUnit == .mmolL)
    }

    @Test("Offline during the migration: the local pick is kept to migrate later")
    func migrationTransientKeepsLocalPick() async {
        let defaults = makeDefaults()
        defaults.set(GlucoseUnit.mmolL.rawValue, forKey: "hl.settings.glucoseUnit")
        let state = RouterState(column: .null)
        state.offline = true
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.glucoseUnit == .mmolL)
        #expect(!defaults.bool(forKey: "hl.settings.glucoseUnit.migrated.v1"))

        state.offline = false
        await store.load()
        #expect(state.column == .value("mmol/L"))
        #expect(defaults.bool(forKey: "hl.settings.glucoseUnit.migrated.v1"))
    }

    @Test("A server without the PATCH route settles the flag and the account unit wins")
    func migrationRefusedAdoptsServer() async {
        let defaults = makeDefaults()
        defaults.set(GlucoseUnit.mmolL.rawValue, forKey: "hl.settings.glucoseUnit")
        let state = RouterState(column: .null, failPatchStatus: 404)
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(state.patchCount == 1)
        #expect(defaults.bool(forKey: "hl.settings.glucoseUnit.migrated.v1"))
        #expect(store.glucoseUnit == .mgdL) // the series is in mg/dL on that server
    }

    // MARK: - Explicit pick

    @Test("setGlucoseUnit PATCHes the server token and hard-sets the echo")
    func explicitPickWrites() async {
        let defaults = makeDefaults()
        let state = RouterState(column: .value("mg/dL"))
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        let ok = await store.setGlucoseUnit(.mmolL)

        #expect(ok)
        #expect(state.patchCount == 1)
        #expect(state.lastPatchBody?["glucoseUnit"] as? String == "mmol/L")
        #expect(store.glucoseUnit == .mmolL)
        // The next hydration reads the stored column back — no ping-pong.
        await store.load()
        #expect(store.glucoseUnit == .mmolL)
        #expect(state.patchCount == 1)
    }

    @Test("A pick the server refuses, or one made offline, is reverted")
    func explicitPickReverts() async {
        let defaults = makeDefaults()
        let state = RouterState(column: .value("mg/dL"), failPatchStatus: 422)
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(await store.setGlucoseUnit(.mmolL) == false)
        #expect(store.glucoseUnit == .mgdL)
        #expect(store.error != nil)

        state.failPatchStatus = nil
        state.offline = true
        #expect(await store.setGlucoseUnit(.mmolL) == false)
        #expect(store.glucoseUnit == .mgdL)
    }

    // MARK: - Entry inverts in the account's unit

    @Test("A value typed in mmol/L on an mmol/L account is stored as mg/dL")
    func entryInvertsInAccountUnit() async {
        let defaults = makeDefaults()
        let state = RouterState(column: .value("mmol/L"))
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()

        let canonical = MeasureEntryConversion.canonicalScalar(5.3, kind: .glucose, units: store.unitPreferences)
        // 5.3 mmol/L × 18.0182 (the server's `MGDL_PER_MMOL`) = 95.496 mg/dL.
        #expect(abs(canonical - 95.496) < 0.001)
        #expect(MeasureEntryConversion.entrySuffix(kind: .glucose, units: store.unitPreferences) == "mmol/L")
        // …and a stored 95.496 mg/dL reads back as the 5.3 that was typed.
        #expect(MetricValueFormatter.formatScalar(canonical, kind: .glucose, units: store.unitPreferences)
            == 5.3.formatted(.number.precision(.fractionLength(1))))
    }

    // MARK: - Logout

    @Test("Logout drops the account's unit, its mirror and the migration flag")
    func logoutClears() async {
        let defaults = makeDefaults()
        let state = RouterState(column: .value("mmol/L"))
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.glucoseUnit == .mmolL)

        store.clearOnLogout()
        #expect(store.glucoseUnit == .mgdL)
        #expect(defaults.object(forKey: "hl.settings.glucoseUnit") == nil)
        #expect(defaults.object(forKey: "hl.settings.glucoseUnit.migrated.v1") == nil)
    }
}

// swiftlint:enable force_unwrapping
