import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// 1.5 KONTO (#149, #151, #157) — connections, notifications, Coach copy and
/// the account payload. Each point once against a server that sends the field
/// and once against one that does not (rule 10).
@MainActor
@Suite("KONTO: Fitbit turndown, already linked, event defaults, Coach copy, account payload", .serialized, .mockURLSession)
struct KontoConnectionsTests {
    private static let statusWithRetirement = #"""
    {"data":{"threshold":3,"metricFreshnessDegraded":false,"integrations":[
      {"integration":"withings","connected":false},
      {"integration":"fitbit","connected":true,
       "retirement":{"endsOn":"2026-10-30","ended":true,"successor":"google-health","offered":true}}
    ]},"error":null}
    """#

    private static func makeAPI() -> APIClient {
        APIClient(
            environment: AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.5.0",
                buildNumber: "1"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
    }

    /// `/api/fitbit/status` answers connected; `/api/integrations/status`
    /// answers `consolidated` (nil: 404 like a server without the route);
    /// `/api/fitbit/sync` and `/test` answer `syncStatus` + `syncBody`.
    private static func install(consolidated: String?, syncStatus: Int = 200, syncBody: String = "{}") {
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            let (status, body): (Int, String) = if path == "/api/integrations/status" {
                consolidated.map { (200, $0) } ?? (404, #"{"data":null,"error":"Not found"}"#)
            } else if path.hasSuffix("/sync") || path.hasSuffix("/test") {
                (syncStatus, syncBody)
            } else {
                (200, #"{"data":{"connected":true,"configured":true},"error":null}"#)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private static func fitbitCore() -> OAuthIntegrationCore {
        OAuthIntegrationCore(repo: OAuthIntegrationRepository(api: makeAPI(), provider: .fitbit), provider: .fitbit)
    }

    // MARK: - Fitbit turndown (#149)

    @Test("Fitbit: retirement from the consolidated status ends connect, sync and test; the date is the published day")
    func fitbitRetiredByStatus() async throws {
        Self.install(consolidated: Self.statusWithRetirement)
        let core = Self.fitbitCore()
        await core.loadStatus()
        let retirement = try #require(core.retirement)
        #expect(core.isRetired)
        #expect(core.isOffered)
        #expect(core.isConnected == true, "the connection row stays; only the provider is gone")
        #expect(retirement.pointsToGoogleHealth)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parts = try utc.dateComponents([.year, .month, .day], from: #require(retirement.endDate))
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 30)
        #expect(retirement.notice != String(localized: "integration.fitbit.retired.endedNoDate"), "a known day is named")
    }

    @Test("Fitbit: a server without retirement keeps the row exactly as before")
    func fitbitWithoutField() async {
        Self.install(consolidated: #"{"data":{"integrations":[{"integration":"fitbit","connected":true}]},"error":null}"#)
        let core = Self.fitbitCore()
        await core.loadStatus()
        #expect(core.retirement == nil)
        #expect(!core.isRetired)
        #expect(core.isOffered)
        #expect(core.error == nil)

        Self.install(consolidated: nil)
        let older = Self.fitbitCore()
        await older.loadStatus()
        #expect(older.retirement == nil)
        #expect(older.error == nil, "a missing consolidated route is not the connection's error")
    }

    @Test("Fitbit: 410 provider_retired on sync or test turns into the notice, not an error line")
    func fitbitRetiredByRefusal() async {
        let refusal = #"{"data":null,"error":"Gone","meta":{"errorCode":"provider_retired"}}"#
        Self.install(consolidated: nil, syncStatus: 410, syncBody: refusal)
        let core = Self.fitbitCore()
        await core.loadStatus()
        await core.syncNow()
        #expect(core.isRetired)
        #expect(core.error == nil)
        #expect(core.syncState == .idle)
        #expect(core.retirement?.notice == String(localized: "integration.fitbit.retired.endedNoDate"))

        // Another provider's 410 is not a Fitbit turndown.
        let oura = OAuthIntegrationCore(repo: OAuthIntegrationRepository(api: Self.makeAPI(), provider: .oura), provider: .oura)
        await oura.testConnection()
        #expect(!oura.isRetired)
        #expect(oura.error != nil)
    }

    @Test("Fitbit: offered false hides the row; before the day the notice says it is coming")
    func fitbitOfferedAndEnding() throws {
        let data = Data(
            (#"{"integrations":[{"integration":"fitbit","retirement":{"endsOn":"2026-10-30","ended":false,"#
                + #""successor":"google-health","offered":true}},{"integration":"strava","retirement":"garbage"}]}"#)
                .utf8
        )
        let payload = try JSONDecoder.hlDefault.decode(IntegrationsRetirementPayload.self, from: data)
        let ending = try #require(payload.fitbit)
        #expect(!ending.ended)
        #expect(ending.notice.contains("2026") || ending.notice.contains("30"))
        #expect(ending.notice != String(localized: "integration.fitbit.retired.endingNoDate"))

        let hidden = try JSONDecoder.hlDefault.decode(
            FitbitRetirement.self,
            from: Data(#"{"endsOn":"2026-10-30","ended":true,"successor":"google-health","offered":false}"#.utf8)
        )
        #expect(hidden.offered == false)
        #expect(FitbitRetirement.isRetiredRefusal(HLError.server(status: 410, code: "provider_retired", message: "")))
        #expect(!FitbitRetirement.isRetiredRefusal(HLError.server(status: 500, code: nil, message: "")))
    }

    // MARK: - already_linked (#149)

    @Test("WHOOP: already_linked and the old owner_conflict share one sentence; other reasons keep theirs")
    func alreadyLinked() {
        let linked = WhoopConnectOutcome.failed(reason: "already_linked").userFacingMessage
        let legacy = WhoopConnectOutcome.failed(reason: "owner_conflict").userFacingMessage
        #expect(linked == OAuthConnectReason.alreadyLinkedMessage(provider: "WHOOP"))
        #expect(legacy == linked)
        #expect(linked?.contains("WHOOP") == true)
        #expect(WhoopConnectOutcome.failed(reason: "something").userFacingMessage
            == String(localized: "WHOOP connection failed. Please try again."))
        #expect(OAuthConnectReason.message(for: "already_linked", provider: "Oura")?.contains("Oura") == true)
        #expect(OAuthConnectReason.message(for: "state", provider: "Oura") == nil)
    }

    // MARK: - eventDefaults and BACKUP_HEALTH (#149, #151)

    @Test("eventDefaults from the server win; without them the mirrored table answers")
    func eventDefaults() throws {
        let withDefaults = try JSONDecoder.hlDefault.decode(NotificationPreferencesPayload.self, from: Data(#"""
        {"channels":[],"preferences":[{"channelId":"c1","eventType":"DAILY_BRIEFING","enabled":true}],
         "eventTypes":["MOOD_REMINDER","SYSTEM_ALERT","DAILY_BRIEFING"],
         "eventDefaults":{"MOOD_REMINDER":true,"SYSTEM_ALERT":false,"DAILY_BRIEFING":false}}
        """#.utf8))
        #expect(withDefaults.effectiveEnabled(channelId: "c1", eventType: "MOOD_REMINDER"), "server says on, the old table said off")
        #expect(!withDefaults.effectiveEnabled(channelId: "c1", eventType: "SYSTEM_ALERT"))
        #expect(withDefaults.effectiveEnabled(channelId: "c1", eventType: "DAILY_BRIEFING"), "a stored row still wins")
        #expect(withDefaults.effectiveEnabled(channelId: "c1", eventType: "NEW_EVENT"), "an event the map leaves out falls back")

        // A payload cached by 1.4.1 (and an older server) has no map.
        let cached = try JSONDecoder.hlDefault.decode(NotificationPreferencesPayload.self, from: Data(#"""
        {"channels":[],"preferences":[],"eventTypes":["MOOD_REMINDER","SYSTEM_ALERT"]}
        """#.utf8))
        #expect(cached.eventDefaults == nil)
        #expect(!cached.effectiveEnabled(channelId: "c1", eventType: "MOOD_REMINDER"))
        #expect(cached.effectiveEnabled(channelId: "c1", eventType: "SYSTEM_ALERT"))

        // A malformed map is the same as none, never a failed read.
        let malformed = try JSONDecoder.hlDefault.decode(NotificationPreferencesPayload.self, from: Data(#"""
        {"channels":[],"preferences":[],"eventTypes":[],"eventDefaults":["x"]}
        """#.utf8))
        #expect(malformed.eventDefaults == nil)

        // Round trip keeps the map (the payload is cached as JSON).
        let encoded = try JSONEncoder().encode(withDefaults)
        #expect(try JSONDecoder.hlDefault.decode(NotificationPreferencesPayload.self, from: encoded) == withDefaults)
    }

    @Test("BACKUP_HEALTH has a title, a hint and sorts after the system notice")
    func backupHealth() {
        #expect(NotificationEventLocalization.title(for: "BACKUP_HEALTH") == String(localized: "notifications.event.backupHealth"))
        #expect(NotificationEventLocalization.title(for: "BACKUP_HEALTH") != String(localized: "Notification"))
        #expect(NotificationEventLocalization.hint(for: "BACKUP_HEALTH") == String(localized: "notifications.event.backupHealth.hint"))
        #expect(NotificationEventPriority.rank(of: "BACKUP_HEALTH") > NotificationEventPriority.rank(of: "SYSTEM_ALERT"))
        #expect(NotificationEventPriority.rank(of: "BACKUP_HEALTH") < NotificationEventPriority.rank(of: "SOMETHING_NEW"))
    }

    // MARK: - Coach (#151)

    @Test("Coach: reasoning_only gets its own sentence; an unknown code keeps the generic one")
    func coachReasoningOnly() {
        let generic = AskCoachSheet.providerErrorCopy("coach.provider.something_new")
        #expect(AskCoachSheet.providerErrorCopy("coach.provider.reasoning_only") == String(localized: "coach.error.reasoningOnly"))
        #expect(AskCoachSheet.providerErrorCopy("coach.provider.reasoning_only") != generic)
    }

    @Test("Coach: 422 ai.provider.none (unreadable stored key) lands on the existing no-provider sentence")
    func coachProviderNone() async {
        MockURLProtocol.install { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"No provider","meta":{"errorCode":"ai.provider.none","capability":"coach"}}"#.utf8)
            )
        }
        do {
            _ = try await Self.makeAPI().send(APIRequest<EmptyPayload>(method: .post, path: "/api/insights/chat", maxRetries: 0))
            Issue.record("a 422 must throw")
        } catch let HLError.aiUnavailable(refusal) {
            #expect(refusal.kind == .noProvider)
            #expect(AskCoachSheet.coachRefusalCopy(refusal)
                == String(localized: "No AI provider is available. Set one up in Settings → Assistant."))
        } catch {
            Issue.record("expected aiUnavailable, got \(error)")
        }
    }

    // MARK: - Account payload (#149, #157)

    @Test("displayName from the account wins for the initials when the profile has none; without it the username")
    func initialsFromDisplayName() {
        let profile = UserProfile(
            username: "anna",
            displayName: nil,
            dateOfBirth: nil,
            gender: nil,
            heightCm: nil,
            locale: nil,
            timezone: nil
        )
        let user = User(id: "u1", username: "anna", displayName: "Lena Fischer")
        #expect(UserProfile.initials(profile: profile, user: user) == "LF")
        let named = UserProfile(
            username: "anna",
            displayName: "Anna Berg",
            dateOfBirth: nil,
            gender: nil,
            heightCm: nil,
            locale: nil,
            timezone: nil
        )
        #expect(UserProfile.initials(profile: named, user: user) == "AB", "the profile's own name comes first")
        #expect(UserProfile.initials(profile: profile, user: User(id: "u1", username: "anna")) == "A")
        #expect(UserProfile.initials(profile: nil, user: nil) == "?")
    }

    @Test("/api/auth/me: createdAt and displayName decode when sent and stay nil when not")
    func accountPayload() throws {
        let modern = try JSONDecoder.hlDefault.decode(User.self, from: Data(#"""
        {"id":"u1","username":"anna","displayName":"Anna","createdAt":"2026-11-01T08:00:00.000Z","role":"ADMIN"}
        """#.utf8))
        #expect(modern.displayName == "Anna")
        #expect(modern.createdAt == AccountDeletionWire.date("2026-11-01T08:00:00.000Z"))
        let older = try JSONDecoder.hlDefault.decode(User.self, from: Data(#"{"id":"u1","username":"anna"}"#.utf8))
        #expect(older.displayName == nil)
        #expect(older.createdAt == nil)
    }

    @Test("/api/auth/me/mfa: proofMethods decode, oidc is never offered, an older server has none")
    func proofMethods() throws {
        let modern = try JSONDecoder.hlDefault.decode(MfaStatus.self, from: Data(#"""
        {"totp":{"enabled":false},"recoveryCodesRemaining":0,"webauthn":[],"passkeyNudgeDismissed":false,
         "proofMethods":["password","oidc","passkey"]}
        """#.utf8))
        #expect(modern.proofMethods == ["password", "oidc", "passkey"])
        #expect(modern.offeredProofMethods == ["password", "passkey"])
        let older = try JSONDecoder.hlDefault.decode(MfaStatus.self, from: Data(#"""
        {"totp":{"enabled":true},"recoveryCodesRemaining":8,"webauthn":[],"passkeyNudgeDismissed":true}
        """#.utf8))
        #expect(older.proofMethods == nil)
        #expect(older.offeredProofMethods == nil)
        #expect(older.totp.enabled)
    }

    @Test("Admin pushes open the home screen: system-job alert and backup health")
    func adminPushLandsHome() {
        #expect(DeepLinkRoute.fromPushPath("/admin/system-status") == .dashboard)
        #expect(DeepLinkRoute.fromPushPath("/admin/backups") == .dashboard)
    }
}
