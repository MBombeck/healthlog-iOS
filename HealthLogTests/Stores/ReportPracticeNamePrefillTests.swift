import Foundation
import Testing

// swiftlint:disable force_unwrapping

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-35 (2) — `lastReportPracticeName` as an OPTIONAL prefill.**
///
/// The server field is last-used, not per-device: whoever generated the most
/// recent report wins. The whole risk of adopting it is therefore a single one —
/// that a suggestion silently replaces something the person typed — so the bulk
/// of this suite is that invariant from every angle a real session can reach it.
///
/// The wire half rides the real `APIClient` over `MockURLProtocol`; the request
/// test pins that a filled-in practice name actually reaches
/// `POST /api/export/health-record` (and that a blank field sends no key at all,
/// which matters because the schema is `.strict()`).
@Suite("CU-35 — practice-name prefill", .serialized)
struct ReportPracticeNamePrefillTests {
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []

        func record(_ body: Data?) {
            guard let body else { return }
            lock.lock()
            defer { lock.unlock() }
            bodies.append(body)
        }

        var snapshot: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return bodies
        }
    }

    private static func bodyFromStream(_ req: URLRequest) -> Data? {
        guard let stream = req.httpBodyStream else { return req.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    private static func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private static func respond(_ json: String) {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
    }

    // MARK: - Wire

    @Test("`lastReportPracticeName` decodes off /api/auth/me")
    func fieldDecodes() async throws {
        Self.respond(#"""
        {"data":{"id":"u1","unitPreference":"metric",
        "lastReportPracticeName":"Praxis Dr. Meier"},"error":null}
        """#)
        let prefs = try await SettingsRepository(api: Self.makeAPI()).authMeServerPrefs()
        #expect(prefs.lastReportPracticeName == "Praxis Dr. Meier")
        // Additive — the neighbouring prefs still decode.
        #expect(prefs.unitPreference == "metric")
    }

    @Test(
        "every honest absence decodes to nil — omitted, null, empty, whitespace",
        arguments: [
            #"{"data":{"id":"u1"},"error":null}"#,
            #"{"data":{"id":"u1","lastReportPracticeName":null},"error":null}"#,
            #"{"data":{"id":"u1","lastReportPracticeName":""},"error":null}"#,
            #"{"data":{"id":"u1","lastReportPracticeName":"   "},"error":null}"#
        ]
    )
    func absencesDecodeToNil(payload: String) async throws {
        Self.respond(payload)
        let prefs = try await SettingsRepository(api: Self.makeAPI()).authMeServerPrefs()
        #expect(prefs.lastReportPracticeName == nil)
    }

    @Test("a surrounding-whitespace value is trimmed, not prefilled raw")
    func valueIsTrimmed() async throws {
        Self.respond(#"{"data":{"id":"u1","lastReportPracticeName":"  Praxis Nord  "},"error":null}"#)
        let prefs = try await SettingsRepository(api: Self.makeAPI()).authMeServerPrefs()
        #expect(prefs.lastReportPracticeName == "Praxis Nord")
    }

    // MARK: - The invariant: a prefill NEVER overwrites the user

    @MainActor
    @Test("an untouched, empty field takes the suggestion")
    func prefillsIntoEmptyField() {
        let store = ReportPracticeNameStore(repo: SettingsRepository(api: Self.makeAPI()))
        #expect(store.applyPrefill("Praxis Dr. Meier"))
        #expect(store.draft == "Praxis Dr. Meier")
        #expect(store.didPrefill)
        #expect(store.practiceName == "Praxis Dr. Meier")
    }

    @MainActor
    @Test("a value the user typed is NEVER replaced by the suggestion")
    func typedValueSurvives() {
        let store = ReportPracticeNameStore(repo: SettingsRepository(api: Self.makeAPI()))
        store.setDraftFromUser("Hausarztpraxis Süd")
        #expect(!store.applyPrefill("Praxis Dr. Meier"))
        #expect(store.draft == "Hausarztpraxis Süd")
        #expect(!store.didPrefill)
    }

    @MainActor
    @Test("a field the user CLEARED stays cleared — deleting the name is an answer")
    func clearedFieldIsNotRefilled() {
        let store = ReportPracticeNameStore(repo: SettingsRepository(api: Self.makeAPI()))
        store.setDraftFromUser("Praxis Nord")
        store.setDraftFromUser("")
        // Empty again, but no longer the app's to fill: the user removed it on
        // purpose, and re-inserting would be exactly the silent overwrite the
        // rule forbids.
        #expect(!store.applyPrefill("Praxis Dr. Meier"))
        #expect(store.draft.isEmpty)
        #expect(store.practiceName == nil)
    }

    @MainActor
    @Test("the suggestion lands at most once — a later /me refresh cannot re-stamp it")
    func prefillHappensOnlyOnce() {
        let store = ReportPracticeNameStore(repo: SettingsRepository(api: Self.makeAPI()))
        #expect(store.applyPrefill("Praxis A"))
        // The user then curates the prefilled value…
        store.setDraftFromUser("Praxis A — Zweigstelle")
        // …and a second hydration tick offers something else. It must not land.
        #expect(!store.applyPrefill("Praxis B"))
        #expect(store.draft == "Praxis A — Zweigstelle")
    }

    @MainActor
    @Test("an absent server value neither fills nor latches — a first report elsewhere can still suggest later")
    func absentValueDoesNotLatch() {
        let store = ReportPracticeNameStore(repo: SettingsRepository(api: Self.makeAPI()))
        #expect(!store.applyPrefill(nil))
        #expect(!store.applyPrefill("   "))
        #expect(!store.didPrefill)
        #expect(store.applyPrefill("Praxis Später"))
        #expect(store.draft == "Praxis Später")
    }

    @MainActor
    @Test("loadPrefill reads /me and applies it; a repeat call is a no-op")
    func loadPrefillFromServer() async {
        Self.respond(#"{"data":{"id":"u1","lastReportPracticeName":"Praxis Dr. Meier"},"error":null}"#)
        let store = ReportPracticeNameStore(repo: SettingsRepository(api: Self.makeAPI()))
        await store.loadPrefill()
        #expect(store.draft == "Praxis Dr. Meier")

        // The user edits, then the screen re-appears and loads again.
        store.setDraftFromUser("Praxis Nord")
        Self.respond(#"{"data":{"id":"u1","lastReportPracticeName":"Praxis Dr. Meier"},"error":null}"#)
        await store.loadPrefill()
        #expect(store.draft == "Praxis Nord", "a re-entry must not clobber the edit")
    }

    @MainActor
    @Test("a /me failure leaves the field exactly as it was — no report is blocked by it")
    func loadPrefillFailsSoft() async {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"boom"}"#.utf8)
            )
        }
        let store = ReportPracticeNameStore(repo: SettingsRepository(api: Self.makeAPI()))
        await store.loadPrefill()
        #expect(store.draft.isEmpty)
        #expect(!store.didPrefill)
        #expect(store.practiceName == nil)
    }

    @MainActor
    @Test("a whitespace-only draft is not a practice name")
    func whitespaceDraftIsNil() {
        let store = ReportPracticeNameStore(repo: SettingsRepository(api: Self.makeAPI()))
        store.setDraftFromUser("   ")
        #expect(store.practiceName == nil)
        store.setDraftFromUser("  Praxis Nord ")
        #expect(store.practiceName == "Praxis Nord")
    }

    // MARK: - Request: the name actually reaches the export route

    @Test("the report POST carries `practiceName` when the field is filled")
    func requestCarriesPracticeName() async throws {
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(Self.bodyFromStream(req))
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/pdf"]
                )!,
                Data("%PDF-1.4".utf8)
            )
        }
        _ = try await DoctorReportService(api: Self.makeAPI()).downloadPDF(
            days: 90,
            locale: "de",
            selection: ReportSelection(leaves: ["WEIGHT"]),
            practiceName: "Praxis Dr. Meier"
        )
        let body = try #require(log.snapshot.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["practiceName"] as? String == "Praxis Dr. Meier")
        #expect(json["format"] as? String == "pdf")
    }

    @Test("a blank field omits the key entirely — `.strict()` would 422 on a null")
    func requestOmitsAbsentPracticeName() async throws {
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(Self.bodyFromStream(req))
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/pdf"]
                )!,
                Data("%PDF-1.4".utf8)
            )
        }
        _ = try await DoctorReportService(api: Self.makeAPI()).downloadPDF(
            days: 90,
            locale: "de",
            selection: ReportSelection(leaves: ["WEIGHT"])
        )
        let body = try #require(log.snapshot.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(!json.keys.contains("practiceName"))
    }
}

// swiftlint:enable force_unwrapping
