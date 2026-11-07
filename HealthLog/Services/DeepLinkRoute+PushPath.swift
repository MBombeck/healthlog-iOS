import Foundation

/// #141 / #126 3.2 — the push `url` (server `tap-target.ts`, a same-origin web
/// path) mapped to the native screen.
///
/// The server resolves one path per delivery: `/` (system alerts, the daily
/// briefing, every Guardian delivery and every discreet one), `/mood?add=1`,
/// `/medications` (or `/medications/<id>` from a producer override),
/// `/checkups`, `/settings/security`, `/settings/integrations`, `/cycle` and
/// `/coach`. A path without a native screen opens home, exactly as the server's
/// own root does. The value is never logged (it can carry a record id).
extension DeepLinkRoute {
    /// Longest path the server ever emits (`tap-target.ts` `MAX_PATH_LENGTH`).
    static let pushPathMaxLength = 512

    /// The route a push `url` opens. Anything that is not a same-origin path
    /// (`https://…`, `//host`, a backslash, whitespace) opens home: the server
    /// only ever sends such paths, so a different shape is not ours to follow.
    static func fromPushPath(_ raw: String) -> DeepLinkRoute {
        guard isSafePushPath(raw), let components = URLComponents(string: raw) else { return .dashboard }
        let parts = components.path.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []
        switch parts.first {
        case nil:
            return .dashboard
        case "mood":
            // Only `?add=1` opens the entry sheet (server: "No other target
            // here opens a write form"); the plain page has no native twin.
            let wantsSheet = parts.count == 1 && query.contains { $0.name == "add" && $0.value == "1" }
            return wantsSheet ? .mood : .dashboard
        case "medications":
            return medicationsRoute(parts: Array(parts.dropFirst()))
        case "checkups" where parts.count == 1:
            return checkupsRoute(query: query)
        case "cycle" where parts.count == 1:
            return .cycle
        case "coach" where parts.count == 1:
            return .coach
        case "settings" where parts.count == 2:
            switch parts[1] {
            case "security": return .settingsSecurity
            case "integrations": return .settingsIntegrations
            default: return .dashboard
            }
        default:
            return .dashboard
        }
    }

    /// `/medications` opens the list; `/medications/<id>` (and a deeper tab
    /// such as the low-stock alert's stock view) opens that medication. The id
    /// passes the same allowlist as `healthlog://medications/<id>`.
    private static func medicationsRoute(parts: [String]) -> DeepLinkRoute {
        guard let rawId = parts.first else { return .medications }
        guard let url = URL(string: "healthlog://medications/\(rawId)"),
              case let .medication(id)? = DeepLinkRoute(url: url) else { return .medications }
        return .medication(id: id)
    }

    /// VISIT — `/checkups?visit=<id>` names one booked visit; the id passes
    /// the same allowlist as every other record id. Anything else (no id,
    /// `?view=visits`, a tampered id) opens Vorsorge as before.
    private static func checkupsRoute(query: [URLQueryItem]) -> DeepLinkRoute {
        guard let id = query.first(where: { $0.name == "visit" })?.value, isAllowedRecordId(id) else {
            return .checkups
        }
        return .checkupsVisit(id: id)
    }

    static func isAllowedRecordId(_ id: String) -> Bool {
        guard let regex = idAllowlist else { return false }
        return regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    /// Mirrors the server's `isSafeAppPath`: one leading slash, no
    /// protocol-relative `//`, no backslash, no whitespace or control character.
    static func isSafePushPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= pushPathMaxLength, value.hasPrefix("/"), !value.hasPrefix("//") else {
            return false
        }
        return !value.contains("\\") && !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
}
