import SwiftUI

/// **GH #47 — the small "aus Apple Health" provenance mark.**
///
/// Rendered on a medication that is a read-only mirror of an Apple Health
/// (HealthKit) medication. Signals WHY the manual dose-logging controls are
/// absent on that card: the doses are owned by Apple Health (source-exclusive),
/// so logging here would double-count. Purely presentational.
struct AppleHealthProvenanceBadge: View {
    var body: some View {
        HStack(spacing: HLSpace.xxs) {
            Image(systemName: "heart.text.square.fill")
                .font(.hlCaption2)
                .foregroundStyle(HLColor.red)
            Text("medications.appleHealth.provenance")
                .font(.hlCaption2.weight(.semibold))
                .foregroundStyle(HLText.secondary)
        }
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xxs)
        .background(HLSurface.tertiary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("medications.appleHealth.provenance"))
    }
}
