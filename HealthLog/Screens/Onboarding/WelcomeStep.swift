import SwiftUI

struct WelcomeStep: View {
    let onNext: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appContainer) private var container
    @State private var appeared = false

    var body: some View {
        // One-screen Welcome. The CTA is pinned in a
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
                // Shrunk 120→96 so the hero + 3 rows fit above the
                // fold on a Pro-sized viewport.
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    // The app icon's rounded mask, not a card.
                    // swiftlint:disable:next hl_no_handmade_card
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.lg, style: .continuous))
                    .accessibilityHidden(true)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)
                    .animation(entranceAnimation(index: 0), value: appeared)

                VStack(spacing: HLSpace.md) {
                    // Headline lifted out of a hardcoded literal
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

                    // Orientation paragraph: the next step asks for the
                    // server address.
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

                // Trimmed 4 → 3 feature rows (HIG brevity); the
                // dropped "Assistant Insights" row is sold again later in the
                // flow. All copy now lives in Localizable.xcstrings (de + en).
                VStack(spacing: HLSpace.md) {
                    OnboardingExplainRow(
                        symbol: "waveform.path.ecg",
                        title: String(localized: "onboarding.welcome.feature.vitals.title"),
                        subtitle: String(localized: "onboarding.welcome.feature.vitals.subtitle")
                    )
                    OnboardingExplainRow(
                        symbol: "pills.fill",
                        title: String(localized: "onboarding.welcome.feature.meds.title"),
                        subtitle: String(localized: "onboarding.welcome.feature.meds.subtitle")
                    )
                    OnboardingExplainRow(
                        symbol: "lock.shield.fill",
                        title: String(localized: "onboarding.welcome.feature.selfhosted.title"),
                        subtitle: String(localized: "onboarding.welcome.feature.selfhosted.subtitle")
                    )
                }
                .padding(.horizontal, HLSpace.xl)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : entranceOffset)
                .animation(entranceAnimation(index: 2), value: appeared)

                // Only for an install that still ran the retired offline mode
                // and carries its records; everyone else sees nothing here.
                if showsLeftoverDataNotice {
                    Text("onboarding.welcome.leftoverStandaloneData")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HLSpace.xl)
                        .accessibilityIdentifier("onboarding.welcome.leftoverStandaloneData")
                }

                Spacer(minLength: HLSpace.md)
            }
            .frame(maxWidth: .infinity)
        }
        // The pinned call to action rides the system's bottom bar; the hero
        // scrolls under it behind the system's scroll edge.
        .hlBottomBar {
            HLButton("Get started", icon: "arrow.right", variant: .primary, size: .large, action: onNext)
                // Stable, locale-independent hook for the welcome-CTA UI
                // test — the visible label localises (EN "Get started" /
                // DE "Loslegen"), so the test must query by identifier,
                // not by the localised label string.
                .accessibilityIdentifier("onboarding.welcome.cta")
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

    private var showsLeftoverDataNotice: Bool {
        StandaloneRetirement.showsLeftoverDataNotice(
            defaults: container?.legacyStandaloneDefaults ?? .standard,
            applicationSupport: container?.legacyStandaloneStoreBase
        )
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

/// A feature or a permission explained in onboarding: symbol in the row's
/// symbol column, name in the row's title type, the explanation under it in
/// the row's detail type. The explanation is a sentence, so it wraps instead
/// of ending in "…". Shared by the welcome and the notification step.
struct OnboardingExplainRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: HLRowMetrics.gap) {
            HLRowGlyph(symbol: symbol)
            VStack(alignment: .leading, spacing: HLRowMetrics.labelSpacing) {
                HLRowTitle(Text(verbatim: title))
                Text(verbatim: subtitle)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
