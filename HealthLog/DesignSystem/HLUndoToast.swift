import SwiftUI

/// Centered bottom-anchored pill that surfaces a transient destructive-action
/// confirmation with a `Rückgängig` button. Lives ~5 seconds, then auto-
/// dismisses unless the user reaches for it. The destructive intent already
/// fired (optimistic remove); the toast only buys the user a recovery
/// window before the change becomes effectively permanent.
///
/// **Visual doctrine.** This is the one tasteful exception to the monochrome
/// canvas: a solid BLACK notice with WHITE copy in both light and dark mode,
/// so it reads as a system-level confirmation rather than tinted chrome. A
/// faint white bottom hairline lifts it off dark backgrounds without a full
/// surround border. It sizes to its content (a centered pill), not a
/// full-width speech-bubble, and stays horizontally centered + bottom-
/// anchored across every host so Undo is a same-finger tap (W30).
///
/// **Adoption surface.** `AuthenticatedShell` hosts a single toast slot
/// driven by `UndoCoordinator.current`. Stores enqueue actions on their
/// optimistic-delete paths so the user can roll the snapshot back through
/// a closure the store provided up-front.
///
/// **Accessibility.** The pill exposes a combined element labelled with the
/// status copy plus the TTL ("5 Sekunden"); the `Rückgängig` button carries
/// an `accessibilityAction(named:)` so VoiceOver users hit it via the
/// actions rotor without trapping inside the toast.
///
/// **Motion.** `accessibilityReduceMotion` collapses the slide-up entry to
/// a cross-fade so users who flagged that preference don't get the
/// bottom-edge translation animation.
struct HLUndoToast: View {
    let message: String
    let ttlSeconds: Int
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)
            Text(message)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onUndo) {
                Text("undo.action.undo")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, HLSpace.md)
                    .padding(.vertical, HLSpace.xs)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("undo.action.undo"))
        }
        .padding(.leading, HLSpace.lg)
        .padding(.trailing, HLSpace.sm)
        .padding(.vertical, HLSpace.sm)
        // Intrinsic-width centered pill: cap the width so a long message
        // truncates rather than stretching into a full-width speech-bubble,
        // but never spill past the screen edge on compact widths.
        .frame(minHeight: 52)
        .background(
            Capsule(style: .continuous)
                .fill(HLColor.inkScrim)
                .shadow(
                    color: HLShadow.card.color,
                    radius: HLShadow.card.radius,
                    x: HLShadow.card.x,
                    y: HLShadow.card.y
                )
        )
        // Faint white bottom hairline — lifts the pill off dark canvas
        // without a full surround border (on-doctrine exception, W30).
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(Capsule(style: .continuous))
        // Tap on background dismisses without triggering undo so a user
        // who already noticed the deletion doesn't have to wait out the
        // TTL to clear the affordance.
        .onTapGesture {
            onDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(combinedAccessibilityLabel))
        .accessibilityAction(named: Text("undo.action.undo")) {
            onUndo()
        }
        .transition(toastTransition)
    }

    /// Reduce-motion collapses the slide-up entry to a fade so the toast
    /// still appears + disappears cleanly without translating the pill.
    private var toastTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    private var combinedAccessibilityLabel: String {
        let template = String(localized: "undo.toast.a11y.label")
        return String(format: template, message, ttlSeconds)
    }
}

#if DEBUG
    #Preview("Default") {
        ZStack(alignment: .bottom) {
            HLColor.background.ignoresSafeArea()
            HLUndoToast(
                message: "Messung entfernt",
                ttlSeconds: 5,
                onUndo: {},
                onDismiss: {}
            )
            .padding(.horizontal, HLSpace.lg)
            .padding(.bottom, HLSpace.md)
        }
    }

    #Preview("Long message") {
        ZStack(alignment: .bottom) {
            HLColor.background.ignoresSafeArea()
            HLUndoToast(
                message: "Verlaufseintrag vom 2. Juni entfernt",
                ttlSeconds: 5,
                onUndo: {},
                onDismiss: {}
            )
            .padding(.horizontal, HLSpace.lg)
            .padding(.bottom, HLSpace.md)
        }
    }
#endif
