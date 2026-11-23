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
                HLCardLabel("Injektionsstelle")

                if let suggested {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(HLText.secondary)
                        Text(String(
                            format: String(localized: "Vorschlag laut Rotationsplan: %@"),
                            suggested.localizedLabel
                        ))
                        .hlText(.footnote)
                    }
                }

                HLFlowLayout {
                    ForEach(allowed, id: \.self) { site in
                        chip(for: site)
                    }
                }
            }
        }
    }

    /// The suggested site carries the rotation symbol, so the hint above
    /// points at a chip and not only at a name.
    private func chip(for site: InjectionSite) -> some View {
        HLChip(
            verbatim: site.localizedLabel,
            systemImage: suggested == site ? "arrow.triangle.2.circlepath" : nil,
            isSelected: selected == site
        ) {
            // Toggle — a second tap clears (site is optional).
            selected = selected == site ? nil : site
        }
        .accessibilityHint(Text(
            suggested == site
                ? String(localized: "Empfohlene Stelle laut Rotationsplan")
                : String(localized: "Double-tap to select")
        ))
    }
}
