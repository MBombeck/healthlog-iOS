import SwiftUI

struct WelcomeStep: View {
    let onNext: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        // v0.10.0 (W-Onboarding) — one-screen Welcome. The CTA is pinned in a
        // bottom `safeAreaInset` so it is ALWAYS reachable regardless of
        // Dynamic Type / device height; the hero + 3 feature rows scroll
        // underneath. Replaces the v0.7.0 layout where four feature rows +
        // hero + paragraph pushed the "Get started" button below the fold,
        // forcing a hunt-and-scroll (HIG: primary action must be reachable).
        ScrollView {
            VStack(spacing: HLSpace.lg) {
                Spacer(minLength: HLSpace.lg)

                // v0.6.1 brand-anchor: the App Icon is the identity now —
                // monochrome everywhere else means the brand mark carries the
                // recognition moment alone, without an SF Symbol stand-in.
                // Shrunk 120→96 (v0.10.0) so the hero + 3 rows fit above the
                // fold on a Pro-sized viewport.
                Image("BrandMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.lg, style: .continuous))
                    .accessibilityHidden(true)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)
                    .animation(entranceAnimation(index: 0), value: appeared)

                VStack(spacing: HLSpace.md) {
                    // v0.12 W7-2 — headline lifted out of a hardcoded literal
                    // into `onboarding.welcome.headline` (EN+DE).
                    Text("onboarding.welcome.headline")
                        .font(.hlLargeTitle)
                        .foregroundStyle(HLText.primary)
                        .multilineTextAlignment(.center)

                    // Existing string-literal catalog key (full EN+DE).
                    Text("Values, medications, mood — in one place, at your pace.")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)

                    // v0.12 W7-2 — orientation paragraph rewritten: the next
                    // step is the connect-or-standalone CHOICE
                    // (`ModeSelectionStep`), not a server-address prompt. The
                    // old copy promised "enter your server address next" and
                    // contradicted the very next screen's "use without an
                    // account" door.
                    Text("onboarding.welcome.serverRequired")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, HLSpace.xs)
                        .accessibilityIdentifier("onboarding.welcome.serverRequired")
                }
                .padding(.horizontal, HLSpace.xl)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : entranceOffset)
                .animation(entranceAnimation(index: 1), value: appeared)

                // v0.10.0 — trimmed 4 → 3 feature rows (HIG brevity); the
                // dropped "Assistant Insights" row is sold again later in the
                // flow. All copy now lives in Localizable.xcstrings (de + en).
                VStack(spacing: HLSpace.md) {
                    FeatureRow(
                        symbol: "waveform.path.ecg",
                        title: String(localized: "onboarding.welcome.feature.vitals.title"),
                        subtitle: String(localized: "onboarding.welcome.feature.vitals.subtitle")
                    )
                    FeatureRow(
                        symbol: "pills.fill",
                        title: String(localized: "onboarding.welcome.feature.meds.title"),
                        subtitle: String(localized: "onboarding.welcome.feature.meds.subtitle")
                    )
                    FeatureRow(
                        symbol: "lock.shield.fill",
                        title: String(localized: "onboarding.welcome.feature.selfhosted.title"),
                        subtitle: String(localized: "onboarding.welcome.feature.selfhosted.subtitle")
                    )
                }
                .padding(.horizontal, HLSpace.xl)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : entranceOffset)
                .animation(entranceAnimation(index: 2), value: appeared)

                Spacer(minLength: HLSpace.md)
            }
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            // Pinned-CTA bar — matches the canonical primitive used by
            // `MiniCoachOnboardingSheet` / `AIConsentSheet`: 1pt separator
            // hairline above a `.thinMaterial` backing so the button reads as
            // a fixed action shelf while the hero scrolls underneath it.
            VStack(spacing: 0) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(HLColor.separator)
                HLButton("Get started", icon: "arrow.right", variant: .primary, size: .large, action: onNext)
                    // Stable, locale-independent hook for the welcome-CTA UI
                    // test — the visible label localises (EN "Get started" /
                    // DE "Loslegen"), so the test must query by identifier,
                    // not by the localised label string.
                    .accessibilityIdentifier("onboarding.welcome.cta")
                    .padding(.horizontal, HLSpace.xl)
                    .padding(.top, HLSpace.md)
                    .padding(.bottom, HLSpace.sm)
            }
            // Reduce Transparency first, material second: the shelf keeps the
            // exact `.thinMaterial` it has always painted, and hands the user
            // who asked for opacity the elevated surface underneath it instead.
            .background(HLMaterialBackground(.thinMaterial))
        }
        // v0.12 W7-2 (folds in W3-5) — staged, reduce-motion-gated entrance
        // matching `ModeSelectionStep` / `AISourceStep`: BrandMark → title →
        // rows fade + rise over ~400ms (3 stages × 0.05s stagger inside the
        // 0.3s spring). Under Reduce-Motion `appeared` flips instantly and
        // every `animation(_:value:)` resolves to `nil`, so VoiceOver users
        // land on the final layout immediately. Flattest screen in the app
        // before this — the cheapest award surface, now with an entrance.
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

    // MARK: - Entrance

    private var entranceOffset: CGFloat {
        reduceMotion ? 0 : 14
    }

    private func entranceAnimation(index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.3, dampingFraction: 0.85)
            .delay(0.05 * Double(index + 1))
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        // T2-4: feature-row icon-rings are mono (Theme-2.0 — the BrandMark
        // above carries the brand-identity moment; tinted chips below it would
        // stack the accent too high). Symbol on textSecondary, no tinted backing.
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: symbol)
                .font(.hlIcon(HLIconSize.lg))
                .foregroundStyle(HLText.secondary)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(title).font(.hlHeadline).foregroundStyle(HLText.primary)
                Text(subtitle).font(.hlSubhead).foregroundStyle(HLText.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
