import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// Closed enum aller iOS-seitig bekannten Deep-Link-Routen. Quelle: Server-Handoff
/// `06-ios-responsibilities.md` § Domain 5 — 7 Pfade.
///
/// Unbekannte Hosts/Pfade landen in `.unknown(url)` und werden geloggt — der
/// Router fällt dann auf Dashboard zurück statt zu crashen.
enum DeepLinkRoute: Equatable {
    case dashboard
    case coach
    case insights(metric: String?)
    /// v0.12 W0-2 — the Meds tab list root (`healthlog://medications` with no
    /// id). Used by the med-reminder no-id fallback so a body-tap on a reminder
    /// whose payload is missing `medicationId` lands the operator on the
    /// medications list instead of teleporting to Dashboard (the old `.unknown`
    /// behaviour). A reminder WITH an id still routes to `.medication(id:)`.
    case medications
    case medication(id: String)
    case medicationHistory(id: String)
    case personalRecord(id: String)
    case settingsNotifications
    /// v0.10.0 W10 — `healthlog://mood` surfaces the central-CTA mood
    /// quick-entry sheet. Used by the `systemSmall` mood widget's whole-tile
    /// deep-link tap (the interactive 5-face quick-log row lives on
    /// `systemMedium` only — five 44 pt targets don't fit the small family).
    case mood
    /// #42 (v1.27.6) — `healthlog://check-in` surfaces the mental-health
    /// check-in (`MentalWellbeingScreen`). Used by the screening-reminder action
    /// (`PHQ9_SCORE` / `GAD7_SCORE` / `WHO5_SCORE`): a derived screening sum
    /// score is not hand-entered, so the reminder opens the self-check instead of
    /// a numeric capture form. Payload-free (the screen opens at its instrument
    /// chooser); routes through `AppRouter.requestMentalWellbeingCheckIn()`.
    case mentalWellbeing
    /// b182 W-B182-INVITE (GH #16) — `healthlog://invite?token=hlv_…` (custom
    /// scheme) or `https://<managed-host>/auth/register?invite=hlv_…`
    /// (universal link from the web invite QR/link). Carries the server invite
    /// token (`hlv_<64 hex>`); routed into prefilled registration.
    ///
    /// **The token is a sensitive secret — it MUST NOT be logged anywhere.**
    /// The `init?(url:)` / `universalLink(_:)` parsers strip the query before
    /// any log line, and `DeepLinkRouter.handle(_:)` never echoes a raw URL on
    /// the invite path.
    case invite(token: String)
    case unknown(URL)

    /// Allowlist regex for server-generated entity IDs (medication, personal-
    /// record, etc.). The server emits cuid-style IDs (`med_xxxxxxxxxxxx`,
    /// `cuid2` 24-char identifiers, UUIDs); they MUST fit `[A-Za-z0-9_-]` and
    /// stay short. Anything else (`/`, `..`, percent-encoded bytes that
    /// survive `pathComponents` decoding, unicode look-alikes) is a tampered
    /// link and is rejected with `.unknown` (M-5 hardening).
    private static let idAllowlist: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^[A-Za-z0-9_-]{1,64}$",
        options: []
    )

    /// Allowlist regex for the insights metric slug. Metric IDs are server-
    /// canonical kebab-case slugs (`blood-pressure`, `heart-rate-variability`).
    /// Same defence as `idAllowlist` but allows lower-case letters + digits +
    /// hyphens only (no underscores, no upper-case — keeps the slug shape
    /// predictable and traversal-proof).
    private static let metricSlugAllowlist: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^[a-z0-9-]{1,48}$",
        options: []
    )

    /// b182 W-B182-INVITE — allowlist regex for the server invite token,
    /// mirroring the server gate `looksLikeInviteToken` (`hlv_<64 lowercase hex>`,
    /// 68 chars total). Anything that doesn't match this exact shape is rejected
    /// *before* it can be routed (so we never park a malformed/oversized value)
    /// and is never logged.
    private static let inviteTokenAllowlist: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^hlv_[0-9a-f]{64}$",
        options: []
    )

    /// b182 W-B182-INVITE — the host + path(s) the web app emits for invite links
    /// (`buildInviteUrl` → `<origin>/auth/register?invite=…`). Scoped narrowly so
    /// the universal-link factory only ever matches an invite path; every other
    /// https URL on the domain returns `nil` and stays in the browser (minimises
    /// the W-SEC-M-3 mis-parented-routing surface).
    ///
    /// W-INVITE-DEEPLINK (#16) — the universal-link factory now accepts the
    /// canonical `/auth/register?invite=` form AND the shorter `/invite` shapes
    /// the web QR may encode (`/invite?token=`, `/invite?invite=`, `/invite/{token}`).
    /// All still resolve via the same token validator; anything off these paths
    /// stays in Safari.
    private static let universalLinkInvitePath = "/auth/register"
    /// The short invite path segment (`/invite` or `/invite/<token>`). Matched by
    /// first path component so a trailing `/<token>` (path-token form) still hits.
    private static let universalLinkShortInviteSegment = "invite"
    /// Query keys carrying the token, accepted on BOTH the custom-scheme and the
    /// universal-link path. `invite` is the web `buildInviteUrl` key; `token` is
    /// the custom-scheme convention — accepting both means a QR that encodes
    /// either shape resolves.
    private static let inviteQueryKeys = ["invite", "token"]

    /// Payload-free hosts → their (parameterless) route. Looked up before the
    /// path-bearing switch so adding a simple route (e.g. v0.10.0's `mood`)
    /// stays a one-line entry and doesn't grow the parser's branch count.
    private static let simpleRoutes: [String: DeepLinkRoute] = [
        "dashboard": .dashboard,
        "coach": .coach,
        "mood": .mood,
        // #42 — screening-reminder deep-link → mental-health check-in surface.
        // Both spellings accepted so a server-supplied `deepLink` can use either.
        "check-in": .mentalWellbeing,
        "mental-wellbeing": .mentalWellbeing
    ]

    /// Returns the candidate string only when it matches the allowlist regex.
    /// Non-matches are dropped (caller falls back to `.unknown`).
    private static func validated(_ candidate: String, regex: NSRegularExpression?) -> String? {
        guard let regex else { return nil }
        let range = NSRange(candidate.startIndex..., in: candidate)
        return regex.firstMatch(in: candidate, options: [], range: range) == nil ? nil : candidate
    }

    /// Pure URL-Parser. Nimmt nur Scheme `healthlog://` an. Liefert `nil`
    /// für alles andere (z.B. `https://`, `mailto:` etc.) — die SwiftUI-Seite
    /// soll `.onOpenURL` solche URLs an andere Handler weiterreichen können.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "healthlog" else { return nil }
        let host = url.host?.lowercased() ?? ""
        // `pathComponents` liefert "/" als erstes Element wenn der Pfad mit /
        // beginnt; URLs wie `healthlog://medications/abc` haben Host="medications"
        // und Pfad="/abc" → Components=["/","abc"]. Wir filtern "/" raus.
        let parts = url.pathComponents.filter { $0 != "/" }

        // M-5 — ID-bearing routes go through the allowlist regex. Any path
        // component that survives `pathComponents` percent-decoding (e.g.
        // `abc%2F..%2Fbad` → `abc/../bad`) is rejected by the regex and the
        // route falls through to `.unknown` so the dashboard fallback handles
        // it. Same gate covers over-length, unicode look-alikes, and dot-
        // segment attempts.
        let id = Self.idAllowlist
        let slug = Self.metricSlugAllowlist

        // Payload-free hosts resolve directly (keeps the path-bearing switch
        // below lean — each is a single, parameterless route).
        if let simple = Self.simpleRoutes[host] {
            self = simple
            return
        }

        // v0.12 W0-2 — `healthlog://medications` (no id) → Meds list root. The
        // med-reminder no-id fallback emits this; it must select the Meds tab
        // rather than fall through to `.unknown` → Dashboard. Resolved here
        // (before the path-bearing switch) so the switch's complexity budget is
        // unaffected — the host-only form is a single parameterless route.
        if host == "medications", parts.isEmpty {
            self = .medications
            return
        }

        // b182 W-B182-INVITE / W-INVITE-DEEPLINK (#16) — `healthlog://invite?token=…`
        // (custom-scheme fallback for shares where the universal link doesn't fire
        // / non-AASA hosts). The token may ride the query (`?token=` / `?invite=`)
        // OR the path (`healthlog://invite/<token>`); both shapes are tried.
        // Validated against the `hlv_<64 hex>` shape gate; a malformed token drops
        // to `.unknown` and is NEVER logged (the URL carries the secret). Resolved
        // here so the path-bearing switch below stays lean (keeps `init?`'s
        // complexity budget).
        if host == "invite" {
            self = Self.extractInviteToken(from: url, pathParts: parts)
                .map(DeepLinkRoute.invite(token:)) ?? .unknown(url)
            return
        }

        switch (host, parts) {
        case let ("insights", p) where p.isEmpty:
            self = .insights(metric: nil)
        case let ("insights", p):
            if let raw = p.first, let safe = Self.validated(raw, regex: slug) {
                self = .insights(metric: safe)
            } else {
                self = .unknown(url)
            }
        case ("medications", _):
            // id-bearing Meds routes (`/<id>` + `/<id>/history`). The
            // host-only form was already resolved to `.medications` above.
            self = Self.parseMedications(parts: parts, id: id, url: url)
        case let ("personal-records", p) where p.count == 1:
            if let safe = Self.validated(p[0], regex: id) {
                self = .personalRecord(id: safe)
            } else {
                self = .unknown(url)
            }
        case let ("settings", p) where p == ["notifications"]:
            self = .settingsNotifications
        default:
            self = .unknown(url)
        }
    }

    /// Resolves the id-bearing `medications/<id>` and `medications/<id>/history`
    /// forms (the host-only `medications` root is handled inline in `init`).
    /// Factored out so `init`'s `switch` stays inside its cyclomatic-complexity
    /// budget. Any id that fails the allowlist regex → `.unknown(url)`.
    private static func parseMedications(parts: [String], id: NSRegularExpression?, url: URL) -> DeepLinkRoute {
        switch parts {
        case let p where p.count == 1:
            guard let safe = validated(p[0], regex: id) else { return .unknown(url) }
            return .medication(id: safe)
        case let p where p.count == 2 && p[1] == "history":
            guard let safe = validated(p[0], regex: id) else { return .unknown(url) }
            return .medicationHistory(id: safe)
        default:
            return .unknown(url)
        }
    }

    /// b182 W-B182-INVITE / W-INVITE-DEEPLINK (#16) — pulls the invite token out
    /// of `url` and returns it only when it passes the `hlv_<64 hex>` shape gate.
    /// Returns `nil` (caller → `.unknown`, dropped) for any malformed / missing /
    /// oversized value. Never logs the value.
    ///
    /// Resolution order (first match wins): the `invite` then `token` query keys
    /// (accepting whichever shape the QR encoded), then the first
    /// `pathParts` segment (the `/invite/<token>` path-token form). `pathParts`
    /// is the caller's already-`/`-filtered `pathComponents` — for the custom
    /// scheme it's `url.pathComponents` minus the `invite` host; for the universal
    /// link the caller passes the segments after `/invite`.
    private static func extractInviteToken(from url: URL, pathParts: [String] = []) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems
        {
            for key in inviteQueryKeys {
                if let raw = items.first(where: { $0.name == key })?.value,
                   let token = validated(raw, regex: inviteTokenAllowlist)
                {
                    return token
                }
            }
        }
        // Path-token fallback: `…/invite/<token>`. Only the single segment shape
        // is accepted; a deeper path is a malformed link → `nil`.
        if pathParts.count == 1, let token = validated(pathParts[0], regex: inviteTokenAllowlist) {
            return token
        }
        return nil
    }

    /// b182 W-B182-INVITE / W-INVITE-DEEPLINK (#16) — narrow universal-link
    /// factory. The plain `init?(url:)` hard-`guard`s `scheme == "healthlog"` (so
    /// `.onOpenURL` can hand https URLs to other handlers), so the UL path needs
    /// its own constructor. Accepts ausschliesslich `expectedHost` auf einem
    /// Invite-Pfad:
    ///   - `…/auth/register?invite=hlv_…` (the canonical web `buildInviteUrl` shape)
    ///   - `…/invite?invite=hlv_…` / `…/invite?token=hlv_…` (short query form)
    ///   - `…/invite/hlv_…` (short path-token form)
    /// Everything else (password-reset, dashboard, wrong host) returns `nil` and
    /// stays in Safari (keeps the W-SEC-M-3 attack surface minimal). The token is
    /// validated + never logged.
    ///
    /// - Parameter expectedHost: der Host des **eingerichteten** Servers
    ///   (`AppEnvironment.currentBaseURL(...)?.host`). Früher stand hier eine
    ///   fest eingebaute Domain; die App kennt keinen eigenen Server mehr,
    ///   also ist die einzige Adresse, für die ein Invite-Link etwas bedeuten
    ///   kann, die vom Nutzer eingetragene. Ist noch keine eingerichtet
    ///   (`nil`), wird nichts geroutet und der Link bleibt im Browser.
    static func universalLink(_ url: URL, expectedHost: String?) -> DeepLinkRoute? {
        guard let expectedHost = expectedHost?.lowercased(), !expectedHost.isEmpty,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == expectedHost else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }

        // Canonical `/auth/register?invite=…` — token rides the query only.
        if url.path == universalLinkInvitePath {
            return extractInviteToken(from: url).map(DeepLinkRoute.invite(token:))
        }

        // Short `/invite` form — `?invite=` / `?token=` query OR `/invite/<token>`
        // path-token. The segments AFTER `invite` are handed to the extractor as
        // the path-token candidate.
        if parts.first == universalLinkShortInviteSegment {
            let pathTail = Array(parts.dropFirst())
            return extractInviteToken(from: url, pathParts: pathTail).map(DeepLinkRoute.invite(token:))
        }

        return nil
    }
}

/// Public Entry-Point für alle Deep-Link-Sourcen: `.onOpenURL`,
/// `UNUserNotificationCenterDelegate.didReceive(response:)`, oder künftige
/// `NSUserActivity`-Universal-Links.
@MainActor
final class DeepLinkRouter {
    private let router: AppRouter
    private let isAuthenticated: @MainActor () -> Bool

    init(router: AppRouter, isAuthenticated: @escaping @MainActor () -> Bool) {
        self.router = router
        self.isAuthenticated = isAuthenticated
    }

    func handle(_ url: URL) {
        guard let route = DeepLinkRoute(url: url) else {
            // b182 W-B182-INVITE — token-safe logging. A rejected URL could be an
            // invite link whose query carries the secret token, so we NEVER echo
            // `url.absoluteString`. Log the scheme/host only — operator-grade,
            // token-free (the secret only ever lives in the query, which we drop).
            // M-7: scheme + host are sanitized, non-sensitive values → `.public`.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.notifications.debug(
                "Deep-Link übersprungen — falsches Scheme: \(url.scheme ?? "nil", privacy: .public)://\(url.host ?? "", privacy: .public)"
            )
            return
        }
        router.apply(route, isAuthenticated: isAuthenticated())
    }

    func handle(_ route: DeepLinkRoute) {
        router.apply(route, isAuthenticated: isAuthenticated())
    }

    /// v0.5.4.3 HP5 — request the central-CTA mood quick-entry sheet.
    /// Pure router-side intent, no URL involved — used by the
    /// `MOOD_REMINDER` action handler when the user taps either the
    /// body of a mood-reminder push or the `mood.log.now` action.
    ///
    /// NAV-1: routed through the SAME parking mechanism the
    /// `healthlog://mood` URL path uses (`AppRouter.apply(_:isAuthenticated:)`):
    /// when authenticated it applies immediately (→ `requestMoodQuickEntry()`);
    /// when NOT yet authenticated the `.mood` route is parked in
    /// `AppRouter.pendingRoute` and replayed by `RootView.consumePendingRoute()`
    /// after unlock — instead of being dropped on the floor.
    func routeToMoodQuickEntry() {
        router.apply(.mood, isAuthenticated: isAuthenticated())
    }
}
