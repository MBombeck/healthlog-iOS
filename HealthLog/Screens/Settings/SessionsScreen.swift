import SwiftUI

/// Settings → Account → "Active sessions" (parity item 2.2). Port of the web
/// `security-sessions-card.tsx:139-189`: one row per active session with the
/// coarse device label, the masked IP + resolved location, the last-active
/// stamp and the current-session marker; swipe to revoke one (asked first); a footer action
/// to sign out everywhere.
///
/// **v1.38.11 — the consequence copy follows the server.** "Sign out
/// everywhere" used to take this device with it (the server revoked every
/// refresh token, the caller's included); from server v1.38.11 a Bearer caller
/// is spared. The action, its titles and its confirm button are unchanged —
/// only the three texts that describe the consequence swap, keyed on
/// `store.sparesThisDevice` (``SignOutEverywhereElse``). An unknown or
/// unreachable server keeps the older, harsher wording.
///
/// **Honest empty state.** A native sign-in creates no `Session` row (see
/// `SessionEntry`), so an account that has only ever used the iOS app sees an
/// empty list. The section header names what the list covers (browser
/// sign-ins), and the sign-out-everywhere action stays available because that
/// is the lever which actually reaches native devices.
struct SessionsScreen: View {
    @Environment(SessionsStore.self) private var store
    @State private var refreshTick: Int = 0

    var body: some View {
        List {
            sessionsSection
            signOutEverywhereSection
        }
        .hlPageMargins()
        .navigationTitle("sessions.title")
        // Sub-screen canon is `.inline`.
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable {
            await store.load()
            refreshTick &+= 1
        }
        .sensoryFeedback(.success, trigger: refreshTick)
        .hlAcknowledgeAlert(
            "sessions.signOutAll.doneTitle",
            item: Binding(
                get: { store.lastRevokedOthersCount },
                set: { if $0 == nil { store.clearRevokedOthersConfirmation() } }
            )
        ) { _ in
            SignOutEverywhereCopy.doneMessage(store)
        }
        .hlAcknowledgeAlert(
            "Error",
            item: Binding(get: { store.error }, set: { if $0 == nil { store.clearError() } })
        ) { err in
            Text(err.userFacingDescription)
        }
    }

    // MARK: - Sections

    private var sessionsSection: some View {
        Section {
            if store.isLoading, store.sessions.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if store.sessions.isEmpty {
                emptyState
            } else {
                ForEach(store.sessions) { session in
                    sessionRow(session)
                }
            }
        } header: {
            // The header says what the list holds (browser
            // sign-ins), so an empty list on an app-only account reads as an
            // answer, not a defect. It replaces the header that repeated the
            // navigation title and the empty state's second sentence.
            HLSectionHeader("sessions.section.browser")
        }
        .hlFormRowSurface()
    }

    private var emptyState: some View {
        HLEmptyNote("sessions.empty.title")
            .accessibilityIdentifier("sessions.emptyState")
    }

    /// Device, then place and last activity in one line; the current
    /// session says so as the row's status, the revoke shows as progress.
    private func sessionRow(_ session: SessionEntry) -> some View {
        HLRowLayout(
            title: Text(verbatim: session.device),
            subtitle: HLRowDetail.text([session.locationLine, activityCaption(for: session)])
        ) {
            if store.revokingID == session.id {
                ProgressView()
            } else if session.isCurrent {
                HLRowValue(
                    value: nil,
                    status: HLRowStatus(String(localized: "sessions.row.current"), tone: .success)
                )
            }
        } leading: {
            EmptyView()
        }
        // Revoking ends a sign-in and deletes no entry: the ladder asks with
        // the action's own word and sign instead of "Delete".
        .hlSwipeDelete(SettingsRevokeAction.session {
            await store.revoke(id: session.id)
        })
        .accessibilityIdentifier("sessions.row")
    }

    /// Two distinct captions so a session with no recorded activity is never
    /// mislabelled "last active". `hasRecordedActivity` is the pure predicate.
    private func activityCaption(for session: SessionEntry) -> String {
        let when = session.effectiveActivityDate.formatted(.relative(presentation: .named))
        return session.hasRecordedActivity
            ? String(localized: "sessions.row.lastActive \(when)")
            : String(localized: "sessions.row.signedIn \(when)")
    }

    private var signOutEverywhereSection: some View {
        @Bindable var store = store
        return Section {
            // Only where the server ends share links at all.
            if store.endsConnectionsAndLinks {
                HLSettingsToggleRow(
                    title: "sessions.signOutAll.keepShareLinks",
                    description: nil,
                    isOn: $store.keepShareLinks,
                    isEnabled: !store.isRevokingOthers,
                    accessibilityID: "sessions.signOutAll.keepShareLinks"
                )
            }
            // The consequence differs by server build: from v1.38.11 the
            // calling device is spared, below it the same call also drops this
            // phone's refresh token. Never promise "except this device" on a
            // server that does not honour it.
            HLDeleteButton(
                "sessions.signOutAll.action",
                form: .row,
                action: .confirmed(
                    title: "sessions.signOutAll.confirmTitle",
                    message: SignOutEverywhereCopy.confirmBody(store),
                    word: "sessions.signOutAll.confirmAction",
                    symbol: "rectangle.portrait.and.arrow.right"
                ) {
                    await store.revokeOthers()
                }
            )
            .disabled(store.isRevokingOthers)
            .accessibilityIdentifier("sessions.signOutAllButton")
            // What signing out everywhere ends, inside the card under the
            // action it explains.
            Text(SignOutEverywhereCopy.footer(store))
                .hlText(.note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .hlFormRowSurface()
    }
}
