import Foundation
@testable import HealthLog
import Testing

/// Deep-Link-URL → Route-Mapping. Quelle: Server-Handoff
/// \`06-ios-responsibilities.md\` § Domain 5 — 7 Pfade. Closed-table-driven
/// damit ein versehentlich umbenannter Pfad sofort hier failed.
@Suite("DeepLinkRoute parsing", .serialized)
struct DeepLinkRouteTests {
    /// Helper: vermeidet \`URL(string:)!\` (force-unwrap-Lint-Verstoss). Alle
    /// Fixture-URLs sind statisch → ein Fehler hier ist Test-Bug, kein Crash.
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string), "Test-Fixture URL ungültig: \(string)")
    }

    /// Der Host des EINGERICHTETEN Servers. Die App bringt keinen eigenen
    /// mehr mit, also ist der akzeptierte Universal-Link-Host immer die vom
    /// Nutzer eingetragene Adresse — hier eine Beispiel-Domain.
    private static let configuredHost = "healthlog.example.com"

    @Test("Falsches Scheme → nil")
    func wrongSchemeReturnsNil() throws {
        try #expect(DeepLinkRoute(url: url("https://healthlog.example.com/dashboard")) == nil)
        try #expect(DeepLinkRoute(url: url("mailto:foo@bar.tld")) == nil)
    }

    @Test("Dashboard")
    func dashboard() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://dashboard")) == .dashboard)
    }

    @Test("Coach")
    func coach() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://coach")) == .coach)
    }

    @Test("Mood — systemSmall widget whole-tile deep link")
    func mood() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://mood")) == .mood)
    }

    @Test("Insights ohne Metric")
    func insightsBare() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://insights")) == .insights(metric: nil))
    }

    @Test("Insights mit Metric")
    func insightsWithMetric() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://insights/blood-pressure")) == .insights(metric: "blood-pressure"))
    }

    @Test("Medication-Detail")
    func medicationDetail() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://medications/med_xyz")) == .medication(id: "med_xyz"))
    }

    @Test("Medication-History")
    func medicationHistory() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://medications/med_xyz/history")) == .medicationHistory(id: "med_xyz"))
    }

    @Test("Personal-Record-Detail")
    func personalRecord() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://personal-records/pr_abc")) == .personalRecord(id: "pr_abc"))
    }

    @Test("Settings → Notifications")
    func settingsNotifications() throws {
        try #expect(DeepLinkRoute(url: url("healthlog://settings/notifications")) == .settingsNotifications)
    }

    @Test("Unbekannter Pfad fallback auf .unknown")
    func unknownPath() throws {
        let parsedURL = try url("healthlog://this-does-not-exist")
        guard case let .unknown(parsed) = DeepLinkRoute(url: parsedURL) else {
            Issue.record("Erwartete .unknown, bekam was anderes")
            return
        }
        #expect(parsed == parsedURL)
    }

    @Test("Medication-ohne-ID → .medications (Meds-Liste-Root, W0-2)")
    func medicationWithoutID() throws {
        // v0.12 W0-2 — `healthlog://medications` (kein id) ist jetzt der Meds-
        // Tab-Root, nicht mehr `.unknown` → Dashboard. Der med-reminder no-id
        // Fallback emittiert genau diese URL und muss auf der Meds-Liste landen.
        try #expect(DeepLinkRoute(url: url("healthlog://medications")) == .medications)
    }

    @Test("Settings ohne Subroute landet in .unknown")
    func settingsBare() throws {
        guard case .unknown = try DeepLinkRoute(url: url("healthlog://settings")) else {
            Issue.record("Erwartete .unknown für settings-ohne-Subroute")
            return
        }
    }

    @Test("Case-insensitive Scheme-Match")
    func caseInsensitiveScheme() throws {
        try #expect(DeepLinkRoute(url: url("HEALTHLOG://dashboard")) == .dashboard)
        try #expect(DeepLinkRoute(url: url("HealthLog://dashboard")) == .dashboard)
    }

    // MARK: - b182 W-B182-INVITE (GH #16)

    /// A valid `hlv_<64 hex>` token (the server `looksLikeInviteToken` shape).
    /// Static fixture — not a real secret.
    private static let validToken = "hlv_" + String(repeating: "a", count: 64)

    @Test("Custom-scheme invite (?token=) → .invite(token:)")
    func customSchemeInvite() throws {
        try #expect(
            DeepLinkRoute(url: url("healthlog://invite?token=\(Self.validToken)"))
                == .invite(token: Self.validToken)
        )
    }

    /// W-INVITE-DEEPLINK (#16) — the custom scheme also accepts the `?invite=`
    /// query key (the web `buildInviteUrl` key) so a QR that encodes either shape
    /// resolves.
    @Test("Custom-scheme invite (?invite=) → .invite(token:)")
    func customSchemeInviteAltQueryKey() throws {
        try #expect(
            DeepLinkRoute(url: url("healthlog://invite?invite=\(Self.validToken)"))
                == .invite(token: Self.validToken)
        )
    }

    /// W-INVITE-DEEPLINK (#16) — the path-token form `healthlog://invite/<token>`.
    @Test("Custom-scheme invite (path token) → .invite(token:)")
    func customSchemeInvitePathToken() throws {
        try #expect(
            DeepLinkRoute(url: url("healthlog://invite/\(Self.validToken)"))
                == .invite(token: Self.validToken)
        )
    }

    /// W-INVITE-DEEPLINK (#16) — a malformed path-token still drops to `.unknown`
    /// (never routed, never logged).
    @Test("Custom-scheme invite (bad path token) → .unknown")
    func customSchemeInvitePathTokenRejected() throws {
        guard case .unknown = try DeepLinkRoute(url: url("healthlog://invite/hlv_short")) else {
            Issue.record("Expected .unknown for malformed custom-scheme path token")
            return
        }
    }

    @Test("Universal-link invite (/auth/register?invite=) → .invite(token:)")
    func universalLinkInvite() throws {
        let parsed = try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/auth/register?invite=\(Self.validToken)"),
            expectedHost: Self.configuredHost
        )
        #expect(parsed == .invite(token: Self.validToken))
    }

    /// W-INVITE-DEEPLINK (#16) — the shorter `/invite?token=` universal-link shape.
    @Test("Universal-link invite (/invite?token=) → .invite(token:)")
    func universalLinkShortInviteTokenQuery() throws {
        let parsed = try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/invite?token=\(Self.validToken)"),
            expectedHost: Self.configuredHost
        )
        #expect(parsed == .invite(token: Self.validToken))
    }

    /// W-INVITE-DEEPLINK (#16) — the `/invite?invite=` universal-link shape.
    @Test("Universal-link invite (/invite?invite=) → .invite(token:)")
    func universalLinkShortInviteInviteQuery() throws {
        let parsed = try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/invite?invite=\(Self.validToken)"),
            expectedHost: Self.configuredHost
        )
        #expect(parsed == .invite(token: Self.validToken))
    }

    /// W-INVITE-DEEPLINK (#16) — the `/invite/<token>` path-token universal link.
    @Test("Universal-link invite (/invite/{token}) → .invite(token:)")
    func universalLinkShortInvitePathToken() throws {
        let parsed = try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/invite/\(Self.validToken)"),
            expectedHost: Self.configuredHost
        )
        #expect(parsed == .invite(token: Self.validToken))
    }

    /// W-INVITE-DEEPLINK (#16) — a malformed token on the short `/invite` path
    /// returns nil (stays in Safari), never a routed value.
    @Test("Universal-link short invite with bad token → nil")
    func universalLinkShortInviteBadTokenReturnsNil() throws {
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/invite?token=hlv_short"),
            expectedHost: Self.configuredHost
        ) == nil)
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/invite/hlv_short"),
            expectedHost: Self.configuredHost
        ) == nil)
        // Bare `/invite` with no token at all → nil.
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/invite"),
            expectedHost: Self.configuredHost
        ) == nil)
    }

    @Test("Malformed invite token rejected (custom scheme → .unknown)")
    func malformedCustomSchemeTokenRejected() throws {
        // Too short, wrong prefix, uppercase hex, non-hex chars — all rejected.
        for bad in [
            "hlv_short",
            "hlk_" + String(repeating: "a", count: 64),
            "hlv_" + String(repeating: "A", count: 64),
            "hlv_" + String(repeating: "z", count: 64)
        ] {
            guard case .unknown = try DeepLinkRoute(url: url("healthlog://invite?token=\(bad)")) else {
                Issue.record("Expected .unknown for malformed custom-scheme invite token")
                return
            }
        }
    }

    @Test("Malformed / missing invite token rejected (universal link → nil)")
    func malformedUniversalLinkTokenRejected() throws {
        // Bad token shape → nil (stays in Safari).
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/auth/register?invite=hlv_short"),
            expectedHost: Self.configuredHost
        ) == nil)
        // Missing query → nil.
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/auth/register"),
            expectedHost: Self.configuredHost
        ) == nil)
    }

    @Test("Non-invite https universal link returns nil (stays in browser)")
    func nonInviteUniversalLinkReturnsNil() throws {
        // Wrong path on the same host.
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/forgot-password?invite=\(Self.validToken)"),
            expectedHost: Self.configuredHost
        ) == nil)
        // Wrong host.
        #expect(try DeepLinkRoute.universalLink(
            url("https://evil.example.com/auth/register?invite=\(Self.validToken)"),
            expectedHost: Self.configuredHost
        ) == nil)
        // Plain dashboard https (the legacy `init?` already returns nil for https).
        #expect(try DeepLinkRoute(url: url("https://healthlog.example.com/dashboard")) == nil)
    }

    /// Ohne eingerichteten Server gibt es keinen Host, fuer den ein
    /// Invite-Link etwas bedeuten koennte — es wird nichts geroutet, der Link
    /// bleibt im Browser. Frueher stand hier eine fest eingebaute Domain.
    @Test("Ohne eingerichteten Server routet kein Universal Link")
    func universalLinkWithoutConfiguredServerReturnsNil() throws {
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/auth/register?invite=\(Self.validToken)"),
            expectedHost: nil
        ) == nil)
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/auth/register?invite=\(Self.validToken)"),
            expectedHost: ""
        ) == nil)
    }

    /// Der akzeptierte Host folgt der EINGERICHTETEN Adresse: wer seinen
    /// eigenen Server eintraegt, dessen Invite-Links greifen.
    @Test("Der Universal-Link-Host folgt dem eingerichteten Server")
    func universalLinkFollowsConfiguredHost() throws {
        #expect(try DeepLinkRoute.universalLink(
            url("https://hl.selbstgehostet.example.org/auth/register?invite=\(Self.validToken)"),
            expectedHost: "hl.selbstgehostet.example.org"
        ) == .invite(token: Self.validToken))
        // Ein anderer Host als der eingerichtete wird nicht geroutet.
        #expect(try DeepLinkRoute.universalLink(
            url("https://healthlog.example.com/auth/register?invite=\(Self.validToken)"),
            expectedHost: "hl.selbstgehostet.example.org"
        ) == nil)
    }

    /// Token-safety contract: the parser never surfaces the raw token anywhere
    /// except inside the `.invite` associated value. A malformed token resolves
    /// to `.unknown(url)` — assert the token is NOT exposed as a routable value
    /// (it would only ride along inside the original URL, which AppRouter logs
    /// host/path-only). This guards the "token is never logged" doctrine at the
    /// parse layer.
    @Test("Rejected invite token is never promoted to a routable value")
    func rejectedTokenNeverRouted() throws {
        let route = try DeepLinkRoute(url: url("healthlog://invite?token=hlv_bad"))
        if case let .invite(token) = route {
            Issue.record("Malformed token was wrongly routed as .invite(\(token.prefix(4))…)")
        }
    }
}
