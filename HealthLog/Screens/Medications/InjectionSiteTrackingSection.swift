import SwiftUI

/// Shared editor controls for v1.8.5 injection-site tracking. Rendered inside
/// the medication Add / Edit sheets' advanced section, gated on the delivery
/// form being `INJECTION`.
///
/// - A `trackInjectionSites` toggle.
/// - When on, an `allowedInjectionSites` multi-select (preferred-site
///   allow-list). No selection = all eight allowed (no restriction).
///
/// The caller passes bindings so the parent owns the persisted state and the
/// POST/PUT body construction.
struct InjectionSiteTrackingSection: View {
    @Binding var isInjection: Bool
    @Binding var trackInjectionSites: Bool
    @Binding var allowedInjectionSites: Set<InjectionSite>

    var body: some View {
        if isInjection {
            Toggle("med.injection.track.toggle", isOn: $trackInjectionSites)
            if trackInjectionSites {
                ForEach(InjectionSite.allCases, id: \.self) { site in
                    Toggle(isOn: binding(for: site)) {
                        Text(site.localizedLabel)
                    }
                }
            }
        }
    }

    /// A site is "allowed" when either it's explicitly selected OR the set is
    /// empty (empty = no restriction). Toggling the last selected site OFF is
    /// allowed and simply re-broadens to "all" only if the user clears the
    /// whole set; an explicit partial set stays restrictive.
    private func binding(for site: InjectionSite) -> Binding<Bool> {
        Binding(
            get: { allowedInjectionSites.isEmpty || allowedInjectionSites.contains(site) },
            set: { isOn in
                // First explicit toggle off from the "empty = all" state seeds
                // the set with every-other-site so the choice is meaningful.
                if allowedInjectionSites.isEmpty {
                    allowedInjectionSites = Set(InjectionSite.allCases)
                }
                if isOn {
                    allowedInjectionSites.insert(site)
                } else {
                    allowedInjectionSites.remove(site)
                }
                // A full set is equivalent to "no restriction" — normalise back
                // to empty so the wire body sends `[]` (server default).
                if allowedInjectionSites.count == InjectionSite.allCases.count {
                    allowedInjectionSites = []
                }
            }
        )
    }
}
