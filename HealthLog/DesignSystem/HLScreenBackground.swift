import SwiftUI

/// Applies the canonical screen background — `Color.hlBackground` extended to
/// the safe-area edges — and clears the `List`/`ScrollView` system platter so
/// every screen tab renders against the same color.
///
/// **Why this exists (A6 §4 — background-color shift):**
/// User reported "Dashboard ist blau, Settings ist grau". The root cause is a
/// mismatch between `ScrollView`-rooted screens (where `.background(...)`
/// paints the whole canvas) and `List`-rooted screens (where each cell still
/// draws against `Color(.secondarySystemGroupedBackground)` even with
/// `.scrollContentBackground(.hidden)`). This modifier collapses both into a
/// single canonical call-site — every screen-root uses
/// `.hlScreenBackground()` and the visual platter never drifts.
///
/// **iOS 26 forward-compat:** When we move to a Liquid-Glass background, this
/// modifier becomes the single swap-site (`.background(Material…)` or
/// `glassEffect(.background)`) instead of refactoring 24 screens.
///
/// **List rows** keep `Color.hlBackground` underneath via `.listRowBackground`
/// so the row-platter no longer paints `secondarySystemGroupedBackground`.
public struct HLScreenBackground: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            // v0.8.1 light-palette: paints the canonical Tonal-Mono canvas
            // (`HLSurface.primary`) instead of the legacy `Background` asset.
            // The light-theme re-audit collapsed three competing background
            // systems (cool `#F5F5F8`, cool `#F7F7F8`, purple-tinted `#F8F6FB`)
            // onto one warm-neutral ramp; routing the screen background through
            // `HLSurface.primary` makes every screen-root consume the single
            // canvas hue so canvas, cards and wells harmonize.
            .background(HLSurface.primary.ignoresSafeArea())
            // List-row platter — wipes the system `secondarySystemGroupedBackground`
            // that bleeds through `.scrollContentBackground(.hidden)` on grouped lists.
            // No-op for ScrollView roots (the modifier is harmless when no List exists).
            .listRowBackground(HLSurface.primary)
    }
}

public extension View {
    /// Applies the canonical app background — see `HLScreenBackground`.
    func hlScreenBackground() -> some View {
        modifier(HLScreenBackground())
    }
}

#Preview("HLScreenBackground — ScrollView") {
    ScrollView {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            Text("ScrollView root")
                .font(.hlTitle2)
            HLCard {
                Text("Cards stay legible.")
                    .font(.hlBody)
            }
        }
        .padding()
    }
    .hlScreenBackground()
}

#Preview("HLScreenBackground — List") {
    List {
        Section("Profile") {
            Text("Anna")
            Text("anna.fischer@example.com")
        }
        Section("Health") {
            Text("HealthKit-Sync")
            Text("Withings")
        }
    }
    .hlScreenBackground()
}
