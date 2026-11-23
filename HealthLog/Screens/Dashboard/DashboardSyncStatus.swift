import SwiftUI

/// The sync half of the Dashboard header: the sync slot next to the
/// avatar, and the way into the status panel.
///
/// The avatar's tap still opens Konto; the sync status has doors of
/// its own so that door keeps its meaning: the slot glyph whenever it is
/// visible (syncing, the checkmark beat, or an attention state), and a
/// long-press on the avatar or the greeting (context menu / VoiceOver action)
/// at any time. All of them toggle the same inline `DashboardSyncStatusPanel`
/// below the greeting; nothing opens it on its own.
///
/// No badge on the avatar any more. Attention states show as
/// their own calm glyph in the slot (`HLSyncActivityGlyph`).
///
/// The cluster re-evaluates on a 30-second timeline because "stale" and
/// "waiting" are statements about the clock, not just about store changes.
struct DashboardSyncAvatar<Avatar: View>: View {
    @Environment(SyncStateStore.self) private var syncState
    @Binding var showProfile: Bool
    @Binding var showsSyncStatus: Bool
    @ViewBuilder var avatar: Avatar

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: HLSpace.xs) {
                HLSyncActivityGlyph(now: context.date, action: toggleStatus)
                profileButton
            }
        }
    }

    private var profileButton: some View {
        Button {
            showProfile = true
        } label: {
            avatar
        }
        .buttonStyle(.hlRow)
        .accessibilityLabel(Text(LocalizedStringKey("dashboard.toolbar.profile.accessibilityLabel")))
        .accessibilityAction(named: Text("sync.activity.showStatus"), toggleStatus)
        .contextMenu {
            Button(action: toggleStatus) {
                Label("sync.activity.showStatus", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .accessibilityIdentifier("dashboard.profile.avatar")
    }

    private func toggleStatus() {
        showsSyncStatus.toggle()
    }
}

/// **When did this device last sync, and what is still open.**
///
/// Inline under the greeting rather than a popover: it is part of the
/// Dashboard, scrolls with it, and leaves the presentation census alone.
/// Everything in it comes from `SyncStateStore`: the attention state as a
/// plain sentence, the last sync (handshake, outbox drain or an Apple Health
/// upload the server accepted, foreground or background), the outbox backlog
/// and what the last Apple Health pass still owes, plus the way into Sync
/// Diagnostics — which used to be four levels down in Settings.
///
/// An overview, not an error banner. No icon line, no warning
/// tint; the state reads as a sentence in secondary text. It opens only on a
/// tap or long-press and closes the same way, or with the quiet close button
/// (needed because a healthy, idle slot has no glyph to tap again).
///
/// The panel sits directly under the header's date line. On the
/// Liquid Glass card surface that line refracted into the panel's top edge
/// as a faint ghost ("Samstag, 4. Oktober"). The panel therefore paints the
/// opaque card fill (`HLSurface.secondary`, the same fill every card uses
/// under Reduce Transparency) instead of glass; shape, padding and shadow match `HLCard`.
struct DashboardSyncStatusPanel: View {
    @Environment(SyncStateStore.self) private var syncState
    var onClose: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HStack(alignment: .top, spacing: HLSpace.sm) {
                        VStack(alignment: .leading, spacing: HLSpace.xs) {
                            stateLine(now: context.date)
                            lastSyncLine(now: context.date)
                            detailLines(now: context.date)
                        }
                        Spacer(minLength: HLSpace.sm)
                        closeButton
                    }
                    diagnosticsLink
                }
            }
        }
    }

    /// The attention state as a plain sentence, only when there is one.
    @ViewBuilder
    private func stateLine(now: Date) -> some View {
        if let attention = syncState.attention(now: now) {
            Text(SyncActivityCopy.attention(attention, now: now))
                .hlText(.factLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sync.panel.attention")
        }
    }

    private func lastSyncLine(now: Date) -> some View {
        Text(SyncActivityCopy.lastSyncLine(syncState.lastSync, now: now))
            .hlText(.factLabel)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(SyncActivityCopy.lastSyncAccessibility(syncState.lastSync, now: now)))
            .accessibilityIdentifier("sync.panel.lastSync")
    }

    @ViewBuilder
    private func detailLines(now: Date) -> some View {
        if syncState.attention(now: now) == nil, syncState.pendingOutboxCount > 0 {
            caption(String(localized: "sync.status.queued \(syncState.pendingOutboxCount)"))
        }
        if syncState.healthSyncHeldItemCount > 0 {
            caption(String(localized: "sync.activity.healthHeld \(syncState.healthSyncHeldItemCount)"))
        }
    }

    private var closeButton: some View {
        HLIconButton(systemImage: "xmark", label: HLControlWord.close.key, action: onClose)
            .accessibilityIdentifier("sync.panel.close")
    }

    /// The settings-row primitive, so the chevron promises a push and the
    /// row looks like the Settings door it shortcuts.
    private var diagnosticsLink: some View {
        HLSettingsActionRow(title: "settings.hkdiag.nav_row", presents: .push) {
            SettingsHKSyncDiagnosticsScreen()
        }
        .accessibilityIdentifier("sync.panel.diagnostics")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .hlText(.rowSubtitle)
            .fixedSize(horizontal: false, vertical: true)
    }
}
