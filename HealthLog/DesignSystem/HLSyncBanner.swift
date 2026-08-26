import SwiftUI

/// v0.14.8 W2-SYNCUX — the **shared quiet sync banner** (AUDIT-QOL-UX §4).
///
/// Extracted from the v0.11 W5 `AdoptUploadIndicator` banner layout so the
/// first-login sync indicator in `AuthenticatedShell` and the adopt-on-pair
/// upload indicator in `OnboardingFlow` speak the exact same visual language:
/// a calm, monochrome, full-width `.thinMaterial` strip pinned above the
/// bottom safe area — mini spinner (or status glyph) + `.hlCaption` text +
/// optional trailing action. No new visual language was invented here; this
/// is byte-for-byte the operator-approved Adopt-Banner chrome.
///
/// Hosts mount it inside `.safeAreaInset(edge: .bottom)` and drive
/// show/hide themselves (the banner carries the canonical
/// bottom-slide + opacity transition; the host owns the `.animation`,
/// reduce-motion-gated).
struct HLSyncBanner: View {
    /// The caption line (already-localized — hosts resolve their state-
    /// specific keys, e.g. `sync.status.syncing` / `onboarding.adopt.done`).
    let text: String
    /// `true` renders the leading mini `ProgressView` (in-flight states).
    var showsSpinner: Bool = false
    /// Status glyph for settled states (e.g. `checkmark.circle.fill`).
    /// Ignored while `showsSpinner` is `true`; when `action` is set the
    /// symbol moves into the trailing action button instead.
    var symbol: String?
    /// Optional trailing action (the adopt-upload retry affordance).
    var actionLabel: String?
    var action: (() -> Void)?
    /// Accessibility identifier for the trailing action button.
    var actionAccessibilityIdentifier: String?

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else if let symbol, action == nil {
                // Fixed-size status glyph paired with the caption text.
                Image(systemName: symbol)
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HLText.secondary)
            }
            Text(text)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action, let actionLabel, let symbol {
                Button(action: action) {
                    Label {
                        Text(actionLabel)
                            .font(.hlCaption.weight(.semibold))
                    } icon: {
                        Image(systemName: symbol)
                            // swiftlint:disable:next dynamic_type_bypass
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(actionAccessibilityIdentifier ?? "")
            }
        }
        .padding(.horizontal, HLSpace.xl)
        .padding(.vertical, HLSpace.sm)
        .frame(maxWidth: .infinity)
        // The banner is shared chrome, so it is the one place the two hosts
        // (`AuthenticatedShell`, `OnboardingFlow`) can get the preference wrong
        // together. Routed through the policy once, here.
        .background(HLMaterialBackground(.thinMaterial))
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
