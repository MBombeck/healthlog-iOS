import Foundation

/// Who may call a document route on another person's record (server v1.48.0,
/// #1403, #182 A5). The vault's own reads take a READ grant on the
/// `documents` section. Every change to the vault, its AI reads and its
/// capability take the guardian of a **managed profile** with a MANAGE grant
/// (`requireRecordAuth("guardian", "documents")`); an adult's delegate never
/// reaches them. The source integrations, the layout save and the purge are
/// the owner's alone. Pure, so the table is pinned by tests.
public enum DocumentRouteAccess {
    public enum Need: Equatable, Sendable {
        /// A READ grant covering `documents`.
        case read
        /// A MANAGE grant covering `documents` on a managed profile.
        case guardian
        /// Never through a record selector.
        case ownerOnly
    }

    private static let prefix = "/api/documents"
    private static let inbound = "/api/documents/inbound"

    /// Inbound collection routes that take the guardian on every method.
    private static let guardianCollections: Set<String> = ["bulk", "capability", "deleted", "reindex"]
    /// Per-document routes that take the guardian on every method.
    private static let guardianActions: Set<String> = [
        "chat", "confirm", "extract", "facts", "index", "restore", "suggest", "summary"
    ]
    /// Per-document reads.
    private static let readActions: Set<String> = ["original", "thumbnail"]

    /// The need of `path` under `method`; `nil` when the path is not a
    /// document route.
    public static func need(path: String, method: HTTPMethod) -> Need? {
        guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        if path.hasPrefix(prefix + "/sources") { return .ownerOnly }
        guard path == inbound || path.hasPrefix(inbound + "/") else {
            return method == .get ? .read : .guardian
        }
        return inboundNeed(Array(path.dropFirst(inbound.count).split(separator: "/").map(String.init)), method: method)
    }

    /// `/api/documents/inbound/…` by its remaining segments.
    private static func inboundNeed(_ rest: [String], method: HTTPMethod) -> Need {
        guard let first = rest.first else {
            // The list reads; an upload is the guardian's.
            return method == .get ? .read : .guardian
        }
        switch first {
        case "source": return .ownerOnly
        case "layout": return method == .get ? .read : .ownerOnly
        case "usage": return .read
        default: break
        }
        if rest.count == 1, guardianCollections.contains(first) { return .guardian }
        guard rest.count >= 2 else {
            // `{id}`: the reading is shared, a change is the guardian's.
            return method == .get ? .read : .guardian
        }
        let action = rest[1]
        if action == "purge" { return .ownerOnly }
        if readActions.contains(action) { return .read }
        if guardianActions.contains(action) { return .guardian }
        return method == .get ? .read : .guardian
    }
}

public extension AccountAccessEntry {
    /// This entry is the guardian of a managed profile: a MANAGE grant on a
    /// record that carries the managed-profile marker.
    var isGuardianOfManagedProfile: Bool {
        level == .manage && recordKind == .managed && canWrite
    }

    /// The `"guardian"` need of a section route (server `admitGuardianNeed`):
    /// level, then the managed marker, then the section.
    func allowsGuardian(section: AccountAccessSection) -> Bool {
        isGuardianOfManagedProfile && sections.contains(section)
    }
}
