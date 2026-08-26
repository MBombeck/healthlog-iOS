// App-target symbols (APIClient, stores) aren't in the SPM library — skip under
// the SPM test build.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // swiftlint:disable force_unwrapping

    /// Pins the web-parity `TodayHero` data spine: the tolerant ``DailyDigest``
    /// decode across every documented state, the ``DailyDigestStore``
    /// presentable/degrade state machine (driven through the REAL `APIClient` over
    /// `MockURLProtocol`, per PROJECT_GUIDE.md — no mock-server shortcut), and the 0–3
    /// worth-a-look rail bounding.
    ///
    /// `.serialized` because `MockURLProtocol.handler` is a process-global.
    @Suite("DailyDigest — decode + store + rail bounding", .serialized)
    struct DailyDigestTests {
        // MARK: - Decode fixtures

        private func decode(_ json: String) throws -> DailyDigest {
            try JSONDecoder().decode(DailyDigest.self, from: Data(json.utf8))
        }

        @Test("Full data state decodes verbatim (score, top signal, rail)")
        func decodesFullDataState() throws {
            let digest = try decode(Self.fullJSON)

            #expect(digest.phase == "final")
            #expect(digest.isProvisional == false)
            #expect(digest.sleepPending == false)
            #expect(digest.score?.value == 82)
            #expect(digest.score?.band == "green")
            #expect(digest.score?.delta == 4)
            #expect(digest.topSignal?.headline == "Resting heart rate is settling")
            #expect(digest.topSignal?.delta == "−2 bpm")
            #expect(digest.briefingLead == "You slept well and your heart is calm.")
            #expect(digest.hasBriefingLead)
            #expect(digest.lead == "You slept well and your heart is calm.")
            #expect(digest.isEmptyDegrade == false)

            #expect(digest.worthALook.count == 2)
            let dose = try #require(digest.worthALook.first)
            #expect(dose.kindToken == .doseWindow)
            #expect(dose.statusToken == .warning)
            #expect(dose.isDismissible == false) // actionable kind, never dismissible
            #expect(dose.actions.first?.intent == "dose.log")
            #expect(dose.actions.first?.href == "/medications?highlight=med_1")

            let milestone = digest.worthALook[1]
            #expect(milestone.kindToken == .milestone)
            #expect(milestone.itemKey == "milestone:weight:record")
            #expect(milestone.isDismissible) // observational + itemKey → dismissible
        }

        @Test("Null score + no rail + no briefing → empty-degrade (hero hides)")
        func decodesEmptyDegrade() throws {
            let digest = try decode(Self.emptyDegradeJSON)
            #expect(digest.score == nil)
            #expect(digest.worthALook.isEmpty)
            #expect(digest.hasBriefingLead == false)
            #expect(digest.isEmptyDegrade)
            // The `line` floor still feeds `lead` even when the hero hides.
            #expect(digest.lead == "Nothing needs your attention today.")
        }

        @Test("Null score but a briefing present → NOT empty-degrade (provisional face)")
        func nullScoreWithBriefingIsNotDegrade() throws {
            let digest = try decode(Self.provisionalJSON)
            #expect(digest.score == nil)
            #expect(digest.isProvisional)
            #expect(digest.sleepPending)
            #expect(digest.hasBriefingLead)
            #expect(digest.isEmptyDegrade == false)
        }

        @Test("Lossy rail decode skips a malformed element, keeps the valid ones")
        func lossyArraySkipsMalformedRailItem() throws {
            let digest = try decode(Self.malformedRailJSON)
            // The array carried [validItem, 123]; the int is skipped, not fatal.
            #expect(digest.worthALook.count == 1)
            #expect(digest.worthALook.first?.kindToken == .syncIssue)
        }

        @Test("Rail bounds to 3 even if the server ever over-sends")
        func railBoundsToThree() throws {
            let digest = try decode(Self.fiveItemJSON)
            #expect(digest.worthALook.count == 5) // raw payload preserved
            #expect(digest.rail.count == 3) // render bound
            #expect(digest.rail.map(\.kind) == ["dose_window", "sync_issue", "coach_checkin"])
        }

        @Test("Dismiss gate: only observational kinds with an itemKey are dismissible")
        func dismissGate() {
            // milestone WITHOUT an itemKey → not dismissible.
            let noKey = DailyPriorityItem(
                kind: "milestone", itemKey: nil, title: "t", body: nil,
                status: "success", actions: [], moduleKey: nil
            )
            #expect(noKey.isDismissible == false)
            // dose_window WITH an itemKey (never happens, but gate must hold) → not dismissible.
            let actionableWithKey = DailyPriorityItem(
                kind: "dose_window", itemKey: "dose:x", title: "t", body: nil,
                status: "warning", actions: [], moduleKey: nil
            )
            #expect(actionableWithKey.isDismissible == false)
            // tension_window WITH an itemKey → dismissible.
            let observational = DailyPriorityItem(
                kind: "tension_window", itemKey: "tension:2026-07-18:morning", title: "t",
                body: nil, status: "info", actions: [], moduleKey: nil
            )
            #expect(observational.isDismissible)
        }

        @Test("Unknown kind / status tokens degrade to nil, never a decode failure")
        func unknownTokensDegradeGracefully() throws {
            let digest = try decode(Self.unknownKindJSON)
            let item = try #require(digest.worthALook.first)
            #expect(item.kind == "future_kind") // raw preserved
            #expect(item.kindToken == nil) // no icon, no crash
            #expect(item.statusToken == nil)
        }

        // MARK: - Store presentation (real APIClient + MockURLProtocol)

        @MainActor
        private func makeStore() -> DailyDigestStore {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            return DailyDigestStore(repo: DailyDigestRepository(api: api))
        }

        private func respond(_ request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data?) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        @MainActor
        @Test("200 data → .data presentation")
        func storePresentsData() async {
            MockURLProtocol.handler = { req in
                respond(req, status: 200, body: #"{"data":\#(Self.fullJSON),"error":null}"#)
            }
            let store = makeStore()
            await store.load()

            #expect(store.digest?.score?.value == 82)
            if case let .data(digest) = store.presentation {
                #expect(digest.worthALook.count == 2)
            } else {
                Issue.record("expected .data presentation")
            }
        }

        @MainActor
        @Test("404 → nil digest → .hidden (never an error)")
        func storeHidesOn404() async {
            MockURLProtocol.handler = { req in
                respond(req, status: 404, body: #"{"data":null,"error":"not found"}"#)
            }
            let store = makeStore()
            await store.load()

            #expect(store.digest == nil)
            #expect(store.error == nil)
            if case .hidden = store.presentation {} else { Issue.record("expected .hidden") }
        }

        @MainActor
        @Test("403 module.disabled → .hidden (insights off)")
        func storeHidesOnModuleDisabled() async {
            MockURLProtocol.handler = { req in
                respond(
                    req, status: 403,
                    body: #"{"data":null,"error":"module disabled","meta":{"errorCode":"module.disabled","module":"insights"}}"#
                )
            }
            let store = makeStore()
            await store.load()

            #expect(store.digest == nil)
            if case .hidden = store.presentation {} else { Issue.record("expected .hidden") }
        }

        @MainActor
        @Test("200 empty-degrade digest → .hidden")
        func storeHidesOnEmptyDegrade() async {
            MockURLProtocol.handler = { req in
                respond(req, status: 200, body: #"{"data":\#(Self.emptyDegradeJSON),"error":null}"#)
            }
            let store = makeStore()
            await store.load()

            #expect(store.digest != nil)
            if case .hidden = store.presentation {} else { Issue.record("expected .hidden") }
        }

        @MainActor
        @Test("500 → .error presentation (retry)")
        func storeSurfacesError() async {
            MockURLProtocol.handler = { req in
                respond(req, status: 500, body: #"{"data":null,"error":"boom"}"#)
            }
            let store = makeStore()
            await store.load()

            #expect(store.digest == nil)
            if case .error = store.presentation {} else { Issue.record("expected .error") }
        }

        @MainActor
        @Test("Optimistic dismiss removes the card immediately")
        func storeOptimisticDismiss() async {
            MockURLProtocol.handler = { req in
                if req.url?.path.contains("/dismiss") == true {
                    return respond(req, status: 200, body: #"{"data":{"dismissed":true},"error":null}"#)
                }
                return respond(req, status: 200, body: #"{"data":\#(Self.fullJSON),"error":null}"#)
            }
            let store = makeStore()
            await store.load()
            #expect(store.digest?.worthALook.count == 2)

            await store.dismiss(itemKey: "milestone:weight:record")
            #expect(store.digest?.worthALook.contains { $0.itemKey == "milestone:weight:record" } == false)
            #expect(store.digest?.worthALook.count == 1)
        }

        // MARK: - JSON fixtures

        private static let fullJSON = #"""
        {
          "generatedAt": "2026-07-18T07:00:00Z",
          "phase": "final",
          "sleepPending": false,
          "score": { "value": 82, "band": "green", "delta": 4 },
          "topSignal": {
            "sourceMetric": "restingHeartRate",
            "tone": "good",
            "headline": "Resting heart rate is settling",
            "nudge": "Keep the evenings calm.",
            "delta": "−2 bpm"
          },
          "briefingLead": "You slept well and your heart is calm.",
          "line": "You slept well and your heart is calm.",
          "worthALook": [
            {
              "kind": "dose_window",
              "title": "Medication due",
              "body": "Metformin is due today.",
              "status": "warning",
              "actions": [
                { "labelKey": "daily.action.logDose", "intent": "dose.log", "href": "/medications?highlight=med_1" }
              ],
              "moduleKey": "medications"
            },
            {
              "kind": "milestone",
              "itemKey": "milestone:weight:record",
              "title": "A new weight best",
              "body": "A personal best today.",
              "status": "success",
              "actions": [
                { "labelKey": "daily.action.viewMilestone", "intent": "milestone.view", "href": "/insights/weight" }
              ],
              "moduleKey": "insights"
            }
          ]
        }
        """#

        private static let emptyDegradeJSON = #"""
        {
          "generatedAt": "2026-07-18T07:00:00Z",
          "phase": "final",
          "sleepPending": false,
          "score": null,
          "topSignal": null,
          "briefingLead": null,
          "line": "Nothing needs your attention today.",
          "worthALook": []
        }
        """#

        private static let provisionalJSON = #"""
        {
          "generatedAt": "2026-07-18T07:00:00Z",
          "phase": "provisional",
          "sleepPending": true,
          "score": null,
          "topSignal": null,
          "briefingLead": "Today's read is still coming together.",
          "line": "Today's read is still coming together.",
          "worthALook": []
        }
        """#

        private static let malformedRailJSON = #"""
        {
          "generatedAt": "2026-07-18T07:00:00Z",
          "phase": "final",
          "sleepPending": false,
          "score": { "value": 70, "band": "green", "delta": null },
          "topSignal": null,
          "briefingLead": "All steady.",
          "line": "All steady.",
          "worthALook": [
            {
              "kind": "sync_issue",
              "title": "Sync needs attention",
              "body": "Withings isn't syncing.",
              "status": "warning",
              "actions": [
                { "labelKey": "daily.action.reconnect", "intent": "sync.reconnect", "href": "/settings/integrations" }
              ]
            },
            123
          ]
        }
        """#

        private static let fiveItemJSON = #"""
        {
          "generatedAt": "2026-07-18T07:00:00Z",
          "phase": "final",
          "sleepPending": false,
          "score": { "value": 60, "band": "yellow", "delta": 0 },
          "topSignal": null,
          "briefingLead": "A busy day.",
          "line": "A busy day.",
          "worthALook": [
            { "kind": "dose_window", "title": "d", "actions": [] },
            { "kind": "sync_issue", "title": "s", "actions": [] },
            { "kind": "coach_checkin", "title": "c", "actions": [] },
            { "kind": "preventive_care", "title": "p", "actions": [] },
            { "kind": "tension_window", "title": "t", "actions": [] }
          ]
        }
        """#

        private static let unknownKindJSON = #"""
        {
          "generatedAt": "2026-07-18T07:00:00Z",
          "phase": "final",
          "sleepPending": false,
          "score": { "value": 50, "band": "yellow", "delta": null },
          "topSignal": null,
          "briefingLead": "Hello.",
          "line": "Hello.",
          "worthALook": [
            { "kind": "future_kind", "title": "Something new", "status": "cosmic", "actions": [] }
          ]
        }
        """#
    }

#endif
