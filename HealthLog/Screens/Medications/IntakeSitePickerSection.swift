import SwiftUI

/// Compact injection-site selector shown on the **take-a-dose** confirm flow
/// for an injection medication with tracking on (server v1.8.5).
///
/// Offers ONLY the effective allowed set (per-medication allow-list minus the
/// user-level global deny-list) so the server's 422
/// `injection_site.disallowed` path stays an edge case. Surfaces a gentle,
/// monochrome rotation hint reading the last few intakes — suggesting a
/// different site to protect the skin.
///
/// **MDR boundary:** rotation is hygiene guidance (avoid lipohypertrophy from
/// repeated same-site injections), never a clinical dosing recommendation.
/// Site selection is optional — the dose records with or without it.
struct IntakeSitePickerSection: View {
    /// Effective allowed set (already filtered: allowed − globalExcluded).
    let allowed: [InjectionSite]
    /// Recent sites (newest-first) feeding the rotation suggestion.
    let recentSites: [InjectionSite]
    @Binding var selected: InjectionSite?

    private var suggested: InjectionSite? {
        // Only suggest a site that is still in the effective allowed set.
        guard let next = InjectionSiteRotation.suggestNext(recent: recentSites),
              allowed.contains(next) else { return nil }
        return next
    }

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLSectionLabel("Injektionsstelle")

                if let suggested {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(HLText.secondary)
                        Text(String(
                            format: String(localized: "Vorschlag laut Rotationsplan: %@"),
                            suggested.localizedLabel
                        ))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: HLSpace.sm
                ) {
                    ForEach(allowed, id: \.self) { site in
                        tile(for: site)
                    }
                }
            }
        }
    }

    private func tile(for site: InjectionSite) -> some View {
        Button {
            // Toggle — a second tap clears (site is optional).
            selected = selected == site ? nil : site
        } label: {
            Text(site.localizedLabel)
                .font(.hlSubhead)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HLSpace.md)
                .background(background(for: site))
                .foregroundStyle(HLText.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: HLRadius.md)
                        .stroke(
                            selected == site ? HLText.primary : HLColor.separator,
                            lineWidth: selected == site ? 2 : 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(site.localizedLabel))
        .accessibilityAddTraits(selected == site ? [.isSelected] : [])
        .accessibilityHint(Text(
            suggested == site
                ? String(localized: "Empfohlene Stelle laut Rotationsplan")
                : String(localized: "Double-tap to select")
        ))
    }

    private func background(for site: InjectionSite) -> Color {
        if selected == site { return HLText.primary.opacity(HLOpacity.surfaceTintStrong) }
        if suggested == site { return HLSurface.tertiary }
        return HLColor.backgroundEleva
    }
}
