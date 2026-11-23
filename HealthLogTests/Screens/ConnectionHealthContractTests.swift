// App-target symbols (`ConnectionHealthPresentation`, `HKServerSyncHealthSummary`,
// `WithingsStatus`) — not in the SPM library.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// Integration status reads `health` (server v1.42.4+) and nothing
    /// else; the legacy fields (`state`, `lastError`, `syncHealth`,
    /// `tokenExpired`, `hasActivityScope`, …) go in v1.44.
    ///
    /// Fixtures follow `ConnectionHealth` in `docs/api/openapi.yaml` on
    /// `origin/release/v1.43.0` (`b4dc0d592`, document identical to `v1.42.4`).
    @Suite("#139 ConnectionHealth contract")
    struct ConnectionHealthContractTests {
        // MARK: - Decode

        @Test("the full server shape decodes, diagnostics are ignored")
        func decodesFullShape() throws {
            let json = Data(#"""
            { "state": "action_required", "reason": "reauth_required",
              "since": "2026-10-15T06:15:00.000Z", "action": "reconnect",
              "unavailable": [ { "item": "vo2Max", "cause": "permission" } ],
              "lastSuccessAt": "2026-10-14T06:15:00.000Z", "lastDataAt": "2026-10-14T05:00:00.000Z",
              "diagnostics": { "ledgerState": "parked", "failingLegs": ["token_refresh"],
                               "failingSince": "2026-10-15T06:15:00.000Z", "lastAttemptAt": null,
                               "verdict": "reauth_required",
                               "recentCalls": [ { "endpoint": "token_refresh", "status": "reauth_required",
                                                  "at": "2026-10-15T06:15:00.000Z" } ] } }
            """#.utf8)
            let health = try JSONDecoder.hlDefault.decode(ConnectionHealth.self, from: json)
            #expect(health.state == .actionRequired)
            #expect(health.reason == .reauthRequired)
            #expect(health.action == .reconnect)
            #expect(health.since != nil)
            #expect(health.unavailable == [ConnectionHealth.Unavailable(item: "vo2Max", cause: "permission")])
            #expect(health.lastSuccessAt != nil)
            #expect(health.lastDataAt != nil)
            #expect(health.needsReconnect)
        }

        @Test("words this build does not know decode as unknown, never as a failure")
        func unknownWordsAreTolerated() throws {
            let json = Data(#"""
            { "state": "on_fire", "reason": "solar_flare", "action": "pray",
              "unavailable": [ { "item": "spo2" } ] }
            """#.utf8)
            let health = try JSONDecoder.hlDefault.decode(ConnectionHealth.self, from: json)
            #expect(health.state == .unknown("on_fire"))
            #expect(health.reason == .unknown("solar_flare"))
            #expect(health.action == nil)
            #expect(health.unavailable.map(\.item) == ["spo2"])
        }

        @Test("a malformed health object reads as absent; the status still decodes")
        func malformedHealthIsAbsent() throws {
            let oauth = try JSONDecoder.hlDefault.decode(
                OAuthIntegrationStatus.self,
                from: Data(#"{ "connected": true, "health": "broken" }"#.utf8)
            )
            #expect(oauth.connected)
            #expect(oauth.health == nil)

            let config = try JSONDecoder.hlDefault.decode(
                HealthKitSyncConfig.self,
                from: Data(#"{ "entries": [], "lastSyncedAt": null, "health": 42 }"#.utf8)
            )
            #expect(config.health == nil)
        }

        @Test("Withings reads health and no longer decodes the deprecated fields")
        func withingsReadsHealth() throws {
            let json = Data(#"""
            { "connected": true, "configured": true, "tokenExpired": true, "hasActivityScope": false,
              "health": { "state": "limited", "reason": "permission_limited", "since": null,
                          "action": "reconnect", "unavailable": [ { "item": "activity", "cause": "permission" } ] } }
            """#.utf8)
            let status = try JSONDecoder.hlDefault.decode(WithingsStatus.self, from: json)
            #expect(status.health?.state == .limited)
            #expect(status.health?.unavailable.first?.item == "activity")
            // `limited` with a reconnect action is not a broken connection.
            #expect(status.health?.needsReconnect == false)
        }

        // MARK: - Apple Health read

        @Test("Apple Health config decodes health and keeps it across the PATCH echo")
        func healthKitConfigKeepsHealth() throws {
            let json = Data(#"""
            { "entries": [], "lastSyncedAt": "2026-10-15T06:15:00.000Z",
              "syncHealth": { "verdict": "fresh", "since": null },
              "health": { "state": "degraded", "reason": "no_new_data",
                          "since": "2026-10-14T06:15:00.000Z", "action": null, "unavailable": [] } }
            """#.utf8)
            let read = try JSONDecoder.hlDefault.decode(HealthKitSyncConfig.self, from: json)
            #expect(read.health?.state == .degraded)

            let echo = HealthKitSyncConfig(entries: [], lastSyncedAt: nil)
            #expect(echo.keepingReadFields(of: read).health == read.health)

            // The PATCH body never carries read fields.
            let body = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(read)) as? [String: Any]
            #expect(body?["health"] == nil)
        }

        @Test("diagnostics verdict reads health first, the legacy syncHealth only without it")
        func diagnosticsVerdictFromHealth() throws {
            let withHealth = try JSONDecoder.hlDefault.decode(
                HealthKitSyncConfig.self,
                from: Data(#"""
                { "entries": [], "syncHealth": { "verdict": "fresh" },
                  "health": { "state": "degraded", "reason": "unexpected_silence",
                              "since": "2026-10-14T06:15:00.000Z" } }
                """#.utf8)
            )
            let summary = HKServerSyncHealthSummary(config: withHealth)
            #expect(summary.health?.reason == .unexpectedSilence)
            #expect(summary.verdict == nil, "the deprecated verdict is not read when health is there")
            #expect(summary.since == withHealth.health?.since)
            #expect(try summary.verdictLabel == ConnectionHealthPresentation(health: #require(withHealth.health)).stateLabel)

            let legacyOnly = try JSONDecoder.hlDefault.decode(
                HealthKitSyncConfig.self,
                from: Data(#"{ "entries": [], "syncHealth": { "verdict": "stalled" } }"#.utf8)
            )
            let fallback = HKServerSyncHealthSummary(config: legacyOnly)
            #expect(fallback.health == nil)
            #expect(fallback.verdict == .stalled)
        }

        // MARK: - Presentation (the three acceptance states)

        @Test("working, delayed and reauth-needed connections get three different pills")
        func acceptanceStates() {
            let working = ConnectionHealthPresentation(health: .init(state: .ok, reason: .dataArriving))
            let delayed = ConnectionHealthPresentation(health: .init(state: .degraded, reason: .syncStalled))
            let reauth = ConnectionHealthPresentation(
                health: .init(state: .actionRequired, reason: .reauthRequired, action: .reconnect)
            )
            #expect(Self.kind(working.pill) == "connected")
            #expect(Self.kind(delayed.pill) == "warning")
            #expect(Self.kind(reauth.pill) == "error")
            #expect(working.showsDetail == false, "a healthy connection is said by the pill alone")
            #expect(delayed.showsDetail)
            #expect(reauth.action(supported: [.reconnect]) == .reconnect)
        }

        @Test("an unknown state is neutral, never red")
        func unknownStateIsNeutral() {
            let presentation = ConnectionHealthPresentation(health: .init(state: .unknown("x"), reason: .unknown("y")))
            #expect(Self.kind(presentation.pill) == "unknown")
            #expect(presentation.needsAttention == false)
        }

        @Test("at most one button, and only for an action the surface can carry out")
        func actionNeedsSupport() {
            let resume = ConnectionHealthPresentation(
                health: .init(state: .actionRequired, reason: .pausedAfterErrors, action: .resume)
            )
            #expect(resume.action(supported: [.reconnect]) == nil, "no resume route, no button")
            #expect(resume.action(supported: [.reconnect, .resume]) == .resume)
            let none = ConnectionHealthPresentation(health: .init(state: .degraded, reason: .providerErrors))
            #expect(none.action(supported: [.reconnect, .resume]) == nil)
        }

        @Test("one sentence per reason, each one in the catalog in German and English")
        func everyReasonHasItsSentence() throws {
            let reasons: [ConnectionHealth.Reason] = [
                .dataArriving, .firstSyncPending, .planLimited, .permissionLimited, .providerErrors,
                .syncStalled, .noNewData, .unexpectedSilence, .reauthRequired, .pausedAfterErrors, .unknown("z")
            ]
            let keys = reasons.map { ConnectionHealthPresentation(health: .init(state: .degraded, reason: $0)).sentenceKey }
            #expect(Set(keys).count == reasons.count)
            let catalog = try Self.catalog()
            let extra = [
                "integration.health.pill.limited", "integration.health.pill.degraded",
                "integration.health.pill.actionRequired", "integration.health.pill.unknown",
                ConnectionHealthPresentation.actionTitleKey(.reconnect),
                ConnectionHealthPresentation.actionTitleKey(.resume),
                "integration.health.unavailable %@", "integration.health.since %@"
            ]
            for key in keys + extra {
                let locs = (catalog[key] as? [String: Any])?["localizations"] as? [String: Any]
                #expect(locs?["de"] != nil && locs?["en"] != nil, "missing de/en for \(key)")
            }
        }

        @Test("withheld types are listed, an empty list says nothing")
        func unavailableLine() {
            let none = ConnectionHealthPresentation(health: .init(state: .ok, reason: .dataArriving))
            #expect(none.unavailableLine == nil)
            let some = ConnectionHealthPresentation(health: .init(
                state: .limited,
                reason: .planLimited,
                unavailable: [.init(item: "spo2", cause: "plan")]
            ))
            #expect(some.unavailableLine?.contains("spo2") == true)
        }

        // MARK: - Resume routes

        @Test("resume posts to the provider's resume route; providers without one, retired Fitbit included, send nothing")
        func resumeRoutes() async throws {
            let api = PathRecordingAPI()
            try await OAuthIntegrationRepository(api: api, provider: .fitbit).resume()
            try await OAuthIntegrationRepository(api: api, provider: .oura).resume()
            try await WithingsRepository(api: api).resume()
            #expect(api.paths == ["/api/integrations/withings/resume"])
        }

        // MARK: - Helpers

        private static func kind(_ state: HLStatusPill.State) -> String {
            switch state {
            case .connected: "connected"
            case .error: "error"
            case .disconnected: "disconnected"
            case .unknown: "unknown"
            case .warning: "warning"
            }
        }

        private static func catalog(file: String = #filePath) throws -> [String: Any] {
            let url = URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
            let data = try Data(contentsOf: url)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(root["strings"] as? [String: Any])
        }

        private final class PathRecordingAPI: APIClientProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [String] = []

            var paths: [String] {
                lock.withLock { recorded }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                lock.withLock { recorded.append(request.path) }
                return try JSONDecoder.hlDefault.decode(T.self, from: Data(#"{ "resumed": true, "wasParked": true }"#.utf8))
            }

            func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
                lock.withLock { recorded.append(request.path) }
            }

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.canceled
            }
        }
    }

#endif
