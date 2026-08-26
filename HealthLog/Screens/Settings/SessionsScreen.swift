import SwiftUI

/// Settings → Account → "Active sessions" (parity item 2.2). Port of the web
/// `security-sessions-card.tsx:139-189`: one row per active session with the
/// coarse device label, the masked IP + resolved location, the last-active
/// stamp and the current-session marker; swipe to revoke one; a footer action
/// to sign out everywhere.
///
/// **Honest empty state.** A native sign-in creates no `Session` row (see
/// `SessionEntry`), so an account that has only ever used the iOS app sees an
/// empty list. Rather than paint a bare "nothing here" — which reads as a bug —
/// the empty state explains that this list covers browser sign-ins, and the
/// sign-out-everywhere action stays available because that is the lever which
/// actually reaches native devices.
struct SessionsScreen: View {
    @Environment(SessionsStore.self) private var store
    @State private var pendingRevokeID: String?
    @State private var showSignOutAllConfirm: Bool = false
    @State private var refreshTick: Int = 0

    var body: some View {
        List {
            sessionsSection
            signOutEverywhereSection
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same primitive
            // as every other server-backed settings surface).
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        // W3b B3 — iOS 26+ soft scroll-edge (no-op on iOS 18-25).
        .hlScrollEdgeSoft()
        .navigationTitle("sessions.title")
        // SET-V2-C (C-3) — sub-screen canon is `.inline`.
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable {
            await store.load()
            refreshTick &+= 1
        }
        .sensoryFeedback(.success, trigger: refreshTick)
        .hlConfirmDestructive(
            Text("sessions.revoke.confirmTitle"),
            isPresented: Binding(
                get: { pendingRevokeID != nil },
                set: { if !$0 { pendingRevokeID = nil } }
            ),
            message: Text("sessions.revoke.confirmBody"),
            confirm: Text(String(localized: "sessions.revoke.confirmAction")),
            cancel: Text(String(localized: "Cancel")),
            onCancel: { pendingRevokeID = nil },
            action: {
                if let id = pendingRevokeID {
                    Task { await revoke(id: id) }
                }
            }
        )
        .hlConfirmDestructive(
            Text("sessions.signOutAll.confirmTitle"),
            isPresented: $showSignOutAllConfirm,
            // Deliberately NOT "except this device" — on iOS the server also
            // revokes this device's refresh token. See SessionsRepository.
            message: Text("sessions.signOutAll.confirmBody"),
            confirm: Text(String(localized: "sessions.signOutAll.confirmAction")),
            cancel: Text(String(localized: "Cancel")),
            action: {
                Task { await store.revokeOthers() }
            }
        )
        .alert(
            "sessions.signOutAll.doneTitle",
            isPresented: Binding(
                get: { store.lastRevokedOthersCount != nil },
                set: { if !$0 { store.clearRevokedOthersConfirmation() } }
            )
        ) {
            Button(String(localized: "OK")) { store.clearRevokedOthersConfirmation() }
        } message: {
            Text("sessions.signOutAll.doneBody")
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.clearError() } }
            ),
            presenting: store.error
        ) { _ in
            Button(String(localized: "OK")) { store.clearError() }
        } message: { err in
            Text(err.localizedDescription)
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
            Text("sessions.section.active")
        }
    }

    /// The list only ever contains browser sign-ins — say so, so an empty list
    /// on an app-only account reads as an explanation instead of a defect.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("sessions.empty.title")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
            Text("sessions.empty.body")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
        .accessibilityIdentifier("sessions.emptyState")
    }

    private func sessionRow(_ session: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.sm) {
                Text(session.device)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                if session.isCurrent {
                    Text("sessions.row.current")
                        .font(.hlCaption2.weight(.semibold))
                        .padding(.horizontal, HLSpace.sm)
                        .padding(.vertical, HLSpace.xxs)
                        .background(HLAccent.userBrandTint.opacity(0.12))
                        .clipShape(Capsule())
                        .accessibilityIdentifier("sessions.row.currentBadge")
                }
                Spacer(minLength: 0)
                if store.revokingID == session.id {
                    ProgressView()
                }
            }

            if let locationLine = session.locationLine {
                Text(locationLine)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }

            Text(activityCaption(for: session))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingRevokeID = session.id
            } label: {
                Label(String(localized: "sessions.revoke.action"), systemImage: "xmark.circle")
            }
        }
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
        Section {
            Button(role: .destructive) {
                showSignOutAllConfirm = true
            } label: {
                HStack {
                    Label(
                        String(localized: "sessions.signOutAll.action"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                    Spacer(minLength: 0)
                    if store.isRevokingOthers {
                        ProgressView()
                    }
                }
            }
            .disabled(store.isRevokingOthers)
            .accessibilityIdentifier("sessions.signOutAllButton")
        } footer: {
            // R12 — Fußnoten-Tinte in Listen-Gerüsten ist `HLText.secondary`.
            Text("sessions.signOutAll.footer")
                .foregroundStyle(HLText.secondary)
        }
    }

    private func revoke(id: String) async {
        await store.revoke(id: id)
        pendingRevokeID = nil
    }
}
