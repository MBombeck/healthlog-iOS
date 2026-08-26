import Foundation

// One suite deliberately holds all eight routes plus the special cases, so the
// contract reads as a single table rather than being scattered across files.
// swiftlint:disable force_unwrapping file_length type_body_length
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-20 (#69) — `baseUpdatedAt` on the eight guarded routes.**
///
/// One 409 integration test per route (conflict → re-read → the retry lands),
/// plus the token-refresh assertion, the three GET special cases, and the
/// pinned `medication.clientManaged` gain.
///
/// Real `APIClient` over `MockURLProtocol` — no mock server — so a path /
/// method / body-shape drift is caught at the wire boundary. `.serialized`
/// because the handler is process-global.
@Suite("CU-20 — guarded routes", .serialized)
struct OptimisticConcurrencyRouteTests {
    // MARK: - Harness

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data("{\"data\":\(json)}".utf8)
        )
    }

    /// The exact 409 envelope every guarded route emits: three top-level keys,
    /// `meta` carrying only `errorCode`, and **no fresh `updatedAt`** — the
    /// server never calls `freshToken()` on the conflict arm.
    private static func conflict(_ req: URLRequest, code: String) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!,
            Data("{\"data\":null,\"error\":\"changed since it was loaded\",\"meta\":{\"errorCode\":\"\(code)\"}}".utf8)
        )
    }

    /// Records every request the repository under test issues, and scripts a
    /// single conflict on the first write.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writeTokens: [String?] = []
        private var _paths: [(String, String)] = []
        private var _writeCount = 0

        /// `baseUpdatedAt` as it actually appeared on the wire, per write.
        var writeTokens: [String?] {
            lock.withLock { _writeTokens }
        }

        /// `(method, path)` for every request, in order.
        var paths: [(String, String)] {
            lock.withLock { _paths }
        }

        var writeCount: Int {
            lock.withLock { _writeCount }
        }

        /// `true` when a write body contained the literal key at all — used to
        /// separate "absent" from "present and null".
        private(set) var sawTokenKey: [Bool] = []

        func note(_ req: URLRequest) {
            lock.withLock {
                _paths.append((req.httpMethod ?? "?", req.url?.path ?? "?"))
            }
        }

        func noteWrite(_ req: URLRequest) -> Int {
            let body = req.bodyOrStream().flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return lock.withLock {
                _writeCount += 1
                _writeTokens.append(body?["baseUpdatedAt"] as? String)
                sawTokenKey.append(body?.index(forKey: "baseUpdatedAt") != nil)
                return _writeCount
            }
        }
    }

    /// Shared shape of every per-route test: GET seeds token `T0`, the first
    /// write conflicts, the re-GET yields `T1`, the retry lands.
    private func scriptConflictThenSuccess(
        recorder: Recorder,
        writeMethod: String,
        writePath: String,
        code: String,
        readPath: String,
        readBody: @escaping @Sendable (String) -> String,
        writeEcho: @escaping @Sendable (String) -> String
    ) {
        nonisolated(unsafe) var reads = 0
        MockURLProtocol.handler = { req in
            recorder.note(req)
            let path = req.url?.path ?? ""
            if req.httpMethod == writeMethod, path == writePath {
                let n = recorder.noteWrite(req)
                return n == 1
                    ? Self.conflict(req, code: code)
                    : Self.ok(req, writeEcho("T2"))
            }
            if path == readPath {
                reads += 1
                return Self.ok(req, readBody(reads == 1 ? "T0" : "T1"))
            }
            return Self.ok(req, "{}")
        }
    }

    // MARK: - 1. PUT /api/auth/me/coach-prefs

    @Test("coach-prefs: 409 → re-read → retry lands, token advances")
    func coachPrefsConflictRecovers() async throws {
        let rec = Recorder()
        scriptConflictThenSuccess(
            recorder: rec,
            writeMethod: "PUT",
            writePath: "/api/auth/me/coach-prefs",
            code: OptimisticConflictCode.coachPrefs,
            readPath: "/api/auth/me/coach-prefs",
            readBody: { #"{"tone":"warm","updatedAt":"\#($0)"}"# },
            writeEcho: { #"{"tone":"warm","updatedAt":"\#($0)"}"# }
        )
        let repo = AICoachSettingsRepository(api: makeAPI())
        _ = try await repo.setReminderSuggestionsEnabled(true)

        #expect(rec.writeCount == 2)
        #expect(rec.writeTokens == ["T0", "T1"])
        // Token advanced off the successful write echo.
        #expect(await repo.currentCoachPrefsToken() == "T2")
    }

    /// Special case 7a — a never-saved user's GET OMITS `updatedAt` entirely
    /// (`route.ts:43-51`, gated on `coachPrefsJson == null`). The first save
    /// must therefore leave `baseUpdatedAt` out of the body: a `null` would be
    /// `422 invalid_base_updated_at`, not an unconditional write.
    @Test("coach-prefs special case: never saved → GET omits the token, first PUT omits it too")
    func coachPrefsNeverSavedWritesUnconditionally() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "PUT" {
                _ = rec.noteWrite(req)
                return Self.ok(req, #"{"tone":"warm","updatedAt":"T-first"}"#)
            }
            // No `updatedAt` key at all — the pure-defaults shape.
            return Self.ok(req, #"{"tone":"warm"}"#)
        }
        let repo = AICoachSettingsRepository(api: makeAPI())
        #expect(await repo.currentCoachPrefsToken() == nil)
        _ = try await repo.setReminderSuggestionsEnabled(false)

        #expect(rec.writeCount == 1)
        #expect(rec.sawTokenKey == [false], "a first save must omit the key, not send null")
        // The unconditional write bootstraps the guarded regime.
        #expect(await repo.currentCoachPrefsToken() == "T-first")
    }

    // MARK: - 2. PATCH /api/auth/me/modules

    @Test("modules: 409 → re-read → retry lands, token advances")
    func modulesConflictRecovers() async throws {
        let rec = Recorder()
        scriptConflictThenSuccess(
            recorder: rec,
            writeMethod: "PATCH",
            writePath: "/api/auth/me/modules",
            code: OptimisticConflictCode.modules,
            readPath: "/api/auth/me/modules",
            readBody: { #"{"modules":{"illness":true},"updatedAt":"\#($0)"}"# },
            writeEcho: { #"{"modules":{"illness":false},"updatedAt":"\#($0)"}"# }
        )
        let repo = ModuleGateRepository(api: makeAPI())
        // First write is unconditional (the map is read off `/api/auth/me`,
        // which carries no token), then guarded off the re-read.
        _ = try await repo.updateModules(changes: ["illness": false])

        #expect(rec.writeCount == 2)
        #expect(rec.writeTokens == [nil, "T0"])
        #expect(rec.sawTokenKey == [false, true])
        #expect(await repo.currentModulesToken() == "T2")
        // The re-read went to the DEDICATED modules route, the only one with a token.
        #expect(rec.paths.contains { $0 == ("GET", "/api/auth/me/modules") })
    }

    // MARK: - 3. PATCH /api/auth/me/notification-prefs

    @Test("notification-prefs: 409 → re-read → retry lands, token advances")
    func notificationPrefsConflictRecovers() async throws {
        let rec = Recorder()
        scriptConflictThenSuccess(
            recorder: rec,
            writeMethod: "PATCH",
            writePath: "/api/auth/me/notification-prefs",
            code: OptimisticConflictCode.notificationPrefs,
            readPath: "/api/auth/me/notification-prefs",
            readBody: { #"{"mood":{"reminderHour":21},"updatedAt":"\#($0)"}"# },
            writeEcho: { #"{"mood":{"reminderHour":20},"updatedAt":"\#($0)"}"# }
        )
        let repo = NotificationsRepository(api: makeAPI())
        _ = try await repo.authNotificationPrefs() // seeds T0
        try await repo.setMoodReminderHour(20)

        #expect(rec.writeCount == 2)
        #expect(rec.writeTokens == ["T0", "T1"])
        #expect(await repo.currentPrefsToken() == "T2")
    }

    /// **The pinned gain.** `medication.clientManaged` decides whether iOS or
    /// the server delivers medication reminders. The server deep-merges the
    /// whole prefs blob, so before CU-20 a web session PATCHing from a read
    /// taken *before* the flag was set silently reset it — and the user got a
    /// server push AND a local notification for the same dose.
    ///
    /// With the token the stale write cannot land: it comes back 409 with
    /// nothing written, the flag survives, and only a write built on the fresh
    /// read is accepted.
    @Test("GAIN: a stale write cannot silently reset medication.clientManaged")
    func medicationClientManagedSurvivesStaleWrite() async throws {
        let rec = Recorder()
        // Server state: clientManaged is ON, and something else moved the token
        // to T1 after our client last read at T0.
        nonisolated(unsafe) var serverClientManaged = true
        nonisolated(unsafe) var serverToken = "T0"
        nonisolated(unsafe) var reads = 0

        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "PATCH" {
                let n = rec.noteWrite(req)
                let body = req.bodyOrStream()
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let sent = body?["baseUpdatedAt"] as? String
                guard sent == nil || sent == serverToken else {
                    // Guarded write on a stale token: reject, write NOTHING.
                    // Crucially `serverClientManaged` is not touched here.
                    return Self.conflict(req, code: OptimisticConflictCode.notificationPrefs)
                }
                // Deep-merge: only the supplied leaves change. A body that does
                // not mention `medication` leaves `clientManaged` alone.
                if let med = body?["medication"] as? [String: Any],
                   let flag = med["clientManaged"] as? Bool
                {
                    serverClientManaged = flag
                }
                serverToken = "T\(n + 1)"
                return Self.ok(req, #"{"medication":{"clientManaged":\#(serverClientManaged)},"updatedAt":"\#(serverToken)"}"#)
            }
            reads += 1
            return Self.ok(
                req,
                #"{"medication":{"clientManaged":\#(serverClientManaged)},"updatedAt":"\#(serverToken)"}"#
            )
        }

        let repo = NotificationsRepository(api: makeAPI())
        let initial = try await repo.authNotificationPrefs()
        #expect(initial.medicationClientManaged == true)
        #expect(await repo.currentPrefsToken() == "T0")

        // Another session writes; the shared User.updatedAt rotates underneath us.
        serverToken = "T-web"

        // Our write, built on the now-stale read, is REFUSED once, then retried
        // against the fresh token.
        try await repo.setMoodReminderHour(21)

        #expect(rec.writeTokens == ["T0", "T-web"])
        // The flag was never clobbered — the stale write wrote nothing at all.
        #expect(serverClientManaged == true)
        let after = try await repo.authNotificationPrefs()
        #expect(after.medicationClientManaged == true)
    }

    @Test("GAIN: the clientManaged write itself is guarded and echoes the new token")
    func medicationClientManagedWriteIsGuarded() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "PATCH" {
                _ = rec.noteWrite(req)
                return Self.ok(req, #"{"medication":{"clientManaged":true},"updatedAt":"T9"}"#)
            }
            return Self.ok(req, #"{"medication":{"clientManaged":false},"updatedAt":"T0"}"#)
        }
        let repo = NotificationsRepository(api: makeAPI())
        _ = try await repo.authNotificationPrefs()
        try await repo.setMedicationClientManaged(true)

        #expect(rec.writeTokens == ["T0"])
        #expect(await repo.currentPrefsToken() == "T9")
    }

    // MARK: - 4. PUT /api/coach/about-me

    @Test("about-me: 409 → re-read → retry lands, token advances")
    func aboutMeConflictRecovers() async throws {
        let rec = Recorder()
        let dto: @Sendable (String) -> String = {
            #"""
            {"aboutMe":"hi","conditions":"","allergies":"","coachFocus":"",
             "pendingQuestions":[],"updatedAt":"\#($0)","maxChars":4000,"fieldMaxChars":500}
            """#
        }
        scriptConflictThenSuccess(
            recorder: rec,
            writeMethod: "PUT",
            writePath: "/api/coach/about-me",
            code: OptimisticConflictCode.aboutMe,
            readPath: "/api/coach/about-me",
            readBody: dto,
            writeEcho: dto
        )
        let repo = CoachAboutMeRepository(api: makeAPI())
        _ = try await repo.get() // seeds T0
        _ = try await repo.update(CoachAboutMeWrite(aboutMe: "hi", conditions: "", allergies: "", coachFocus: ""))

        #expect(rec.writeCount == 2)
        #expect(rec.writeTokens == ["T0", "T1"])
        #expect(await repo.currentAboutMeToken() == "T2")
    }

    /// Special case 7c — this GET returns an explicit `updatedAt: null` (not an
    /// omitted key) before the first save, because `UserHealthProfile` is a
    /// separate table that does not exist yet. The null must decode to "no
    /// token" and the first PUT must OMIT `baseUpdatedAt` — echoing the null
    /// back would be `422 invalid_base_updated_at`.
    @Test("about-me special case: GET updatedAt=null → first PUT omits the token")
    func aboutMeNullTokenWritesUnconditionally() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "PUT" {
                _ = rec.noteWrite(req)
                return Self.ok(req, #"""
                {"aboutMe":"x","conditions":"","allergies":"","coachFocus":"",
                 "pendingQuestions":[],"updatedAt":"T-first","maxChars":4000,"fieldMaxChars":500}
                """#)
            }
            return Self.ok(req, #"""
            {"aboutMe":null,"conditions":null,"allergies":null,"coachFocus":null,
             "pendingQuestions":[],"updatedAt":null,"maxChars":4000,"fieldMaxChars":500}
            """#)
        }
        let repo = CoachAboutMeRepository(api: makeAPI())
        let dto = try await repo.get()
        #expect(dto.updatedAt == nil)
        #expect(await repo.currentAboutMeToken() == nil)

        _ = try await repo.update(CoachAboutMeWrite(aboutMe: "x", conditions: "", allergies: "", coachFocus: ""))
        #expect(rec.sawTokenKey == [false], "an explicit null token must become an OMITTED key")
        #expect(await repo.currentAboutMeToken() == "T-first")
    }

    /// The server relaxed `aboutMe` to optional; iOS never had a mandatory
    /// check, and an empty value must still go through as the documented
    /// "clear" semantic rather than being blocked client-side.
    @Test("about-me: an empty aboutMe is accepted and sent (no client-side required check)")
    func aboutMeEmptyIsAllowed() async throws {
        let rec = Recorder()
        nonisolated(unsafe) var sentAboutMe: String?
        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "PUT" {
                let body = req.bodyOrStream()
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                sentAboutMe = body?["aboutMe"] as? String
                _ = rec.noteWrite(req)
            }
            return Self.ok(req, #"""
            {"aboutMe":null,"conditions":"c","allergies":"","coachFocus":"",
             "pendingQuestions":[],"updatedAt":"T1","maxChars":4000,"fieldMaxChars":500}
            """#)
        }
        let repo = CoachAboutMeRepository(api: makeAPI())
        _ = try await repo.update(CoachAboutMeWrite(aboutMe: "", conditions: "c", allergies: "", coachFocus: ""))

        #expect(rec.writeCount == 1)
        #expect(sentAboutMe?.isEmpty == true)
    }

    // MARK: - 5. PUT /api/dashboard/widgets

    private static let widgets = #"[{"id":"weight","visible":true,"tileVisible":true,"order":0}]"#

    @Test("dashboard/widgets: 409 → re-read → retry lands, token advances")
    func dashboardLayoutConflictRecovers() async throws {
        let rec = Recorder()
        scriptConflictThenSuccess(
            recorder: rec,
            writeMethod: "PUT",
            writePath: "/api/dashboard/widgets",
            code: OptimisticConflictCode.dashboardLayout,
            readPath: "/api/dashboard/widgets",
            readBody: { #"{"version":1,"widgets":\#(Self.widgets),"updatedAt":"\#($0)"}"# },
            writeEcho: { #"{"version":1,"widgets":\#(Self.widgets),"updatedAt":"\#($0)"}"# }
        )
        let repo = DashboardRepository(api: makeAPI())
        _ = try await repo.widgetLayout() // seeds T0
        _ = try await repo.setWidgetLayout(
            DashboardWidgetLayout(widgets: [.init(id: "weight", visible: true, order: 0)])
        )

        #expect(rec.writeCount == 2)
        #expect(rec.writeTokens == ["T0", "T1"])
        #expect(await repo.currentWidgetLayoutToken() == "T2")
    }

    /// The dashboard DELETE reset is the one reset that DOES echo a token
    /// (`route.ts:413-451`) — adopt it rather than dropping to unconditional.
    @Test("dashboard/widgets DELETE reset: takes no token, adopts the one it echoes")
    func dashboardResetAdoptsEchoedToken() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "DELETE" {
                _ = rec.noteWrite(req)
                return Self.ok(req, #"{"version":1,"widgets":\#(Self.widgets),"updatedAt":"T-reset"}"#)
            }
            return Self.ok(req, #"{"version":1,"widgets":\#(Self.widgets),"updatedAt":"T0"}"#)
        }
        let repo = DashboardRepository(api: makeAPI())
        _ = try await repo.widgetLayout()
        try await repo.resetWidgetLayout()

        #expect(rec.sawTokenKey == [false], "a reset must not carry baseUpdatedAt")
        #expect(await repo.currentWidgetLayoutToken() == "T-reset")
    }

    // MARK: - 6. PUT /api/insights/layout

    private static let tiles = #"[{"id":"overview","visible":true,"order":0}]"#

    @Test("insights/layout: 409 → re-read → retry lands, token advances")
    func insightsLayoutConflictRecovers() async throws {
        let rec = Recorder()
        scriptConflictThenSuccess(
            recorder: rec,
            writeMethod: "PUT",
            writePath: "/api/insights/layout",
            code: OptimisticConflictCode.insightsLayout,
            readPath: "/api/insights/layout",
            readBody: { #"{"version":2,"tiles":\#(Self.tiles),"updatedAt":"\#($0)"}"# },
            writeEcho: { #"{"version":2,"tiles":\#(Self.tiles),"updatedAt":"\#($0)"}"# }
        )
        let repo = try InsightsLayoutRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        _ = try await repo.fetch() // seeds T0
        _ = try await repo.update(
            InsightsLayout(version: 2, tiles: [.init(id: "overview", visible: true, order: 0)])
        )

        #expect(rec.writeCount == 2)
        #expect(rec.writeTokens == ["T0", "T1"])
        #expect(await repo.currentLayoutToken() == "T2")
    }

    /// The insights DELETE reset returns the bare defaults with NO token
    /// (`route.ts:232-245`). Holding the pre-reset token would 409 the user's
    /// very next edit, so it must be dropped.
    @Test("insights/layout DELETE reset: no token in, none out → token cleared")
    func insightsResetClearsToken() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "DELETE" {
                _ = rec.noteWrite(req)
                // Bare defaults — no `updatedAt`.
                return Self.ok(req, #"{"version":2,"tiles":\#(Self.tiles)}"#)
            }
            return Self.ok(req, #"{"version":2,"tiles":\#(Self.tiles),"updatedAt":"T0"}"#)
        }
        let repo = try InsightsLayoutRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        _ = try await repo.fetch()
        #expect(await repo.currentLayoutToken() == "T0")

        _ = try await repo.reset()
        #expect(rec.sawTokenKey == [false], "a reset must not carry baseUpdatedAt")
        #expect(await repo.currentLayoutToken() == nil)
    }

    // MARK: - 7. PUT /api/medications/layout

    @Test("medications/layout: 409 → re-read → retry lands, token advances")
    func medicationLayoutConflictRecovers() async throws {
        let rec = Recorder()
        scriptConflictThenSuccess(
            recorder: rec,
            writeMethod: "PUT",
            writePath: "/api/medications/layout",
            code: OptimisticConflictCode.medicationLayout,
            readPath: "/api/medications/layout",
            // 08-05: the write under test is an order change — the only
            // medication-layout write the app performs now that presentation is
            // cards-only. The route contract (409 → re-read → retry, token
            // advances) is exactly the one this case always asserted.
            readBody: { #"{"version":1,"view":"cards","order":[],"updatedAt":"\#($0)"}"# },
            writeEcho: { #"{"version":1,"view":"cards","order":["m1"],"updatedAt":"\#($0)"}"# }
        )
        let repo = try MedicationsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        _ = try await repo.listLayout() // seeds T0
        _ = try await repo.updateListLayout(MedicationListLayoutPatch(order: ["m1"]))

        #expect(rec.writeCount == 2)
        #expect(rec.writeTokens == ["T0", "T1"])
        #expect(await repo.currentListLayoutToken() == "T2")
    }

    // MARK: - 8. PUT /api/mood/tags/layout

    @Test("mood/tags/layout: 409 → re-read → retry lands, token advances")
    func moodTagLayoutConflictRecovers() async throws {
        let rec = Recorder()
        scriptConflictThenSuccess(
            recorder: rec,
            writeMethod: "PUT",
            writePath: "/api/mood/tags/layout",
            code: OptimisticConflictCode.moodTagLayout,
            readPath: "/api/mood/tags/layout",
            readBody: { #"{"groupOrder":["a"],"placements":{},"updatedAt":"\#($0)"}"# },
            writeEcho: { #"{"groupOrder":["b"],"placements":{},"updatedAt":"\#($0)"}"# }
        )
        let repo = MoodTagCatalogRepository(api: makeAPI())
        _ = try await repo.updateGroupOrder(["b"])

        #expect(rec.writeCount == 2)
        #expect(rec.writeTokens == ["T0", "T1"])
        #expect(await repo.currentLayoutToken() == "T2")
    }

    /// Special case 7b — this GET emits `updatedAt` **conditionally** (the key
    /// is spread in only when the user row resolved, `route.ts:57-61`), so an
    /// absent key means "no token" and the PUT must omit `baseUpdatedAt`.
    @Test("mood/tags/layout special case: token omitted on GET → PUT omits it too")
    func moodTagLayoutConditionalToken() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "PUT" {
                _ = rec.noteWrite(req)
                return Self.ok(req, #"{"groupOrder":["b"],"placements":{},"updatedAt":"T-first"}"#)
            }
            // Fresh user — the key is dropped from the JSON entirely.
            return Self.ok(req, #"{"groupOrder":["a"],"placements":{}}"#)
        }
        let repo = MoodTagCatalogRepository(api: makeAPI())
        _ = try await repo.updateGroupOrder(["b"])

        #expect(rec.sawTokenKey == [false])
        #expect(await repo.currentLayoutToken() == "T-first")
    }

    // MARK: - Falle 2 on a real route

    /// The 300 s server-side cache case, end to end: the post-409 re-GET keeps
    /// returning the same token, so retrying is provably futile. The write must
    /// fail VISIBLY rather than loop — and must NOT silently fall back to a
    /// tokenless write, which would clobber the other session.
    @Test("Stale cached re-read → bounded give-up, and never an unconditional fallback")
    func staleCacheGivesUpVisibly() async throws {
        let rec = Recorder()
        MockURLProtocol.handler = { req in
            rec.note(req)
            if req.httpMethod == "PUT" {
                _ = rec.noteWrite(req)
                return Self.conflict(req, code: OptimisticConflictCode.dashboardLayout)
            }
            // The cached GET keeps handing back the SAME token for up to 5 min.
            return Self.ok(req, #"{"version":1,"widgets":\#(Self.widgets),"updatedAt":"T0"}"#)
        }
        let repo = DashboardRepository(api: makeAPI())
        _ = try await repo.widgetLayout()

        await #expect(throws: HLError.writeConflictUnresolved(OptimisticConflictCode.dashboardLayout)) {
            _ = try await repo.setWidgetLayout(
                DashboardWidgetLayout(widgets: [.init(id: "weight", visible: true, order: 0)])
            )
        }
        // Exactly one attempt: the re-read did not advance the token, so a
        // second write would have been byte-identical.
        #expect(rec.writeCount == 1)
        // Critically: no unconditional (tokenless) retry was ever sent.
        #expect(rec.sawTokenKey == [true])
        #expect(rec.writeTokens == ["T0"])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension URLRequest {
    /// URLSession moves a write body onto `httpBodyStream` by the time a
    /// `URLProtocol` sees the request, so prefer `httpBody` then drain the
    /// stream synchronously.
    func bodyOrStream() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping file_length type_body_length
