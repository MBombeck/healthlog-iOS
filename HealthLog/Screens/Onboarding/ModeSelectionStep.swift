import SwiftUI

/// Onboarding mode-selection step — the adaptive "Connect a server / Use
/// without an account" fork, front-and-centre.
///
/// v0.11 W5: this is now a real RELEASE affordance (the standalone door).
/// Before W5 the standalone card was `#if DEBUG`-gated and Release
/// jumped Welcome → ServerURL directly; now the fork is the first real choice
/// the user makes. The standalone stack (W1 local store, W2 read-union, W3
/// placeholders, W4 adopt-on-pair upload) is complete, so the local-only path
/// is safe and a "connect later" upgrade is wired (Settings → pairing).
///
/// Design (v0.11 QUALITY-DOCTRINE): calm, premium, monochrome. Two equal-weight
/// path cards with a tasteful staggered entrance (reduce-motion-gated), a calm
/// footnote that explains what "use without a server" means (local-only; some
/// cloud features need a server — stated plainly, never a dead button). The
struct ModeSelectionStep: View {
    enum Choice: Equatable {
        case server
        case standalone
    }

    let onChoose: (Choice) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                header
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)

                VStack(spacing: HLSpace.md) {
                    PathCard(
                        symbol: "externaldrive.badge.icloud",
                        title: String(localized: "onboarding.mode.server.title"),
                        subtitle: String(localized: "onboarding.mode.server.subtitle"),
                        identifier: "onboarding.modeServer"
                    ) {
                        select(.server)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)
                    .animation(cardAnimation(index: 0), value: appeared)

                    // v0.15 — the standalone ("use without a server") door is
                    // gated behind `FeatureFlags.standaloneModeAvailable`. With
                    // a mandatory server connection the card is hidden so the
                    // fork only offers the server path. The standalone runtime
                    // is untouched; flip the flag to restore the door.
                    // (In server-mandatory builds the flow normally skips this
                    // whole step — this guard is the belt-and-suspenders.)
                    if FeatureFlags.standaloneModeAvailable {
                        PathCard(
                            symbol: "iphone.gen3",
                            title: String(localized: "onboarding.mode.standalone.title"),
                            subtitle: String(localized: "onboarding.mode.standalone.subtitle"),
                            identifier: "onboarding.modeStandalone"
                        ) {
                            select(.standalone)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : entranceOffset)
                        .animation(cardAnimation(index: 1), value: appeared)
                    }
                }

                footnote
                    .opacity(appeared ? 1 : 0)
                    .animation(cardAnimation(index: 2), value: appeared)

                Spacer(minLength: HLSpace.xxl)
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.top, HLSpace.xxl)
        }
        .background(HLColor.background)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("onboarding.mode.title")
                .font(.hlTitle1)
                .foregroundStyle(HLText.primary)
            Text("onboarding.mode.subtitle")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: some View {
        // Calm, mass-market explanation of "use without a server": local-only,
        // some cloud features need a server. No dead buttons — the upgrade path
        // is real (Settings → connect a server later).
        HStack(alignment: .top, spacing: HLSpace.sm) {
            // Fixed-size leading glyph in a caption row — pairs visually with
            // the caption text; not a body run that needs to scale on its own.
            Image(systemName: "lock.shield")
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            Text("onboarding.mode.footnote")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Entrance

    private var entranceOffset: CGFloat {
        reduceMotion ? 0 : 14
    }

    private func cardAnimation(index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.3, dampingFraction: 0.85)
            .delay(0.05 * Double(index + 1))
    }

    private func select(_ choice: Choice) {
        onChoose(choice)
    }
}

/// One equal-weight path card. Monochrome, glass-free content card (glass
/// discipline: glass only on nav/floating controls). Dynamic-Type-safe — the
/// icon and chevron align to the top so the row grows downward at AX5.
private struct PathCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let identifier: String
    let action: () -> Void

    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: HLSpace.md) {
                // Icon inside a fixed 44pt chip — the chip frame is constant by
                // design, so the glyph is pixel-locked to fit it (HIG tappable
                // size); the surrounding text scales with Dynamic Type.
                Image(systemName: symbol)
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(HLText.primary)
                    .frame(width: 44, height: 44)
                    .background(HLText.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text(title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text(subtitle)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: HLSpace.sm)
                // Canonical trailing disclosure chevron (STANDARDS §3).
                HLDisclosureChevron()
                    .padding(.top, HLSpace.xs)
            }
            .padding(HLSpace.md)
            .background(HLSurface.secondary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                    .stroke(HLColor.separator.opacity(0.4), lineWidth: 1)
            )
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1.0)
            .hlAnimation(.spring(response: 0.18, dampingFraction: 0.85), value: pressed)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(String(localized: "Tap to choose this option")))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
