import SwiftUI

/// The consequence texts of "sign out everywhere", picked from what the running
/// server actually does (``SessionsStore``'s verdicts):
///
/// - below v1.38.11 (or an unreadable version): this device may be signed out
///   too — the pre-R2 harsh copy.
/// - v1.38.11 … v1.39.2: every other sign-in ends, this device stays.
/// - R2 / #115 A7, from v1.39.3: connected AI assistants, API tokens and —
///   unless the person keeps them — doctor share links end too; accepted
///   access grants are kept and named in the confirmation afterwards.
enum SignOutEverywhereCopy {
    @MainActor
    static func confirmBody(_ store: SessionsStore) -> LocalizedStringKey {
        if store.endsConnectionsAndLinks {
            return store.keepShareLinks
                ? "sessions.signOutAll.everything.keepLinks.confirmBody"
                : "sessions.signOutAll.everything.confirmBody"
        }
        return store.sparesThisDevice
            ? "sessions.signOutAll.else.confirmBody"
            : "sessions.signOutAll.confirmBody"
    }

    @MainActor
    static func footer(_ store: SessionsStore) -> LocalizedStringKey {
        if store.endsConnectionsAndLinks {
            return "sessions.signOutAll.everything.footer"
        }
        return store.sparesThisDevice
            ? "sessions.signOutAll.else.footer"
            : "sessions.signOutAll.footer"
    }

    @MainActor
    static func doneBody(_ store: SessionsStore) -> LocalizedStringKey {
        if store.endsConnectionsAndLinks {
            let linksEnded = (store.lastRevokeOthersResult?.shareLinksRevoked ?? 0) > 0 || !store.keepShareLinks
            return linksEnded
                ? "sessions.signOutAll.everything.doneBody"
                : "sessions.signOutAll.everything.keepLinks.doneBody"
        }
        return store.sparesThisDevice
            ? "sessions.signOutAll.else.doneBody"
            : "sessions.signOutAll.doneBody"
    }

    /// The done text, plus — when the server kept accepted grants — who can
    /// still read the record.
    @MainActor
    static func doneMessage(_ store: SessionsStore) -> Text {
        let names = store.keptGrantNames
        guard !names.isEmpty else { return Text(doneBody(store)) }
        let list = names.formatted(.list(type: .and))
        return Text(doneBody(store)) + Text(verbatim: "\n\n") + Text("sessions.signOutAll.grantsKept \(list)")
    }
}
