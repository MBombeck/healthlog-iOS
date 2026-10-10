import SwiftUI

/// U1 (#16) — the **top-bar sync glyph**, Immich-style. INT-L (1.1.1): it is
/// now the one sync slot next to the avatar and also carries the attention
/// states the avatar badge used to show.
///
/// Healthy and idle is nothing: no glyph, no reserved space. While a sync
/// runs, a small `arrow.triangle.2.circlepath` rotates; on the store's `.done`
/// beat it turns into a checkmark, and when the phase decays to `.idle` it
/// scales and fades out over 300 ms and leaves. When something needs
/// attention (lost writes, a failed sync, writes waiting for a connection,
/// nothing synced for a day) a calm symbol for that state stays in the slot
/// until the state clears. A running sync takes the slot back while it runs.
///
/// It reads `SyncStateStore.slotGlyph(now:)`, built on the same phase machine
/// the pull-to-refresh checkmark and the footer caption read, so the top and
/// the bottom of the screen cannot tell different stories.
///
/// **Reduce Motion:** no rotation, no scale, no symbol replace animation — the
/// glyph is static and arrives and leaves by opacity only.
///
/// Tappable whenever visible, the checkmark beat included: `action` opens the
/// screen's sync status (on the Dashboard, `DashboardSyncStatusPanel`).
struct HLSyncActivityGlyph: View {
    @Environment(SyncStateStore.self) private var syncState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The clock the attention states are judged against ("waiting", "stale");
    /// the caller re-reads it on a periodic timeline.
    var now: Date = .now
    var action: () -> Void

    /// The leave animation. 300 ms, the Immich dismissal tempo and the top of
    /// the STANDARDS §6 felt-budget.
    static let dismissal = Animation.easeOut(duration: 0.3)

    var body: some View {
        let glyph = syncState.slotGlyph(now: now)
        ZStack {
            if let glyph {
                Button(action: action) {
                    symbol(for: glyph)
                }
                .buttonStyle(.plain)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                .accessibilityLabel(Text(SyncActivityCopy.slot(glyph, now: now)))
                .accessibilityHint(Text("sync.activity.a11y.openHint"))
                .accessibilityIdentifier(Self.identifier(for: glyph))
            }
        }
        .animation(Self.dismissal, value: glyph)
    }

    private func symbol(for glyph: SyncSlotGlyph) -> some View {
        Image(systemName: Self.symbol(for: glyph))
            .font(.hlSubhead.weight(.semibold))
            .foregroundStyle(HLText.secondary)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .symbolEffect(
                .rotate.clockwise,
                options: .repeat(.continuous),
                isActive: glyph == .syncing && !reduceMotion
            )
            .frame(width: HLSyncActivityGlyph.hitSize, height: HLSyncActivityGlyph.hitSize)
            .contentShape(Rectangle())
    }

    /// One calm symbol per state, all in the secondary text colour: the slot
    /// is a quiet pointer to the panel, not an alarm.
    nonisolated static func symbol(for glyph: SyncSlotGlyph) -> String {
        switch glyph {
        case .syncing: "arrow.triangle.2.circlepath"
        case .done: "checkmark"
        case .attention(.failedWrites): "exclamationmark.icloud"
        case .attention(.failed): "exclamationmark.arrow.triangle.2.circlepath"
        case .attention(.queued): "icloud.slash"
        case .attention(.stale): "clock.arrow.circlepath"
        }
    }

    /// `sync.indicator` stays the identifier of the sync glyph; the attention
    /// glyph gets its own so UI tests can tell the two apart.
    nonisolated static func identifier(for glyph: SyncSlotGlyph) -> String {
        switch glyph {
        case .syncing, .done: "sync.indicator"
        case .attention: "sync.attention"
        }
    }

    /// HIG minimum hit target.
    static let hitSize: CGFloat = 44
}
