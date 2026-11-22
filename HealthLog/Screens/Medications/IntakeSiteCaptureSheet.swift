import SwiftUI

/// **Quick-path injection-site capture interstitial.**
///
/// Bug #60: tapping **"Genommen"** on the quick take surfaces (med card CTA,
/// medication list ✓/swipe, Dashboard "Anstehende Einnahmen" sheet) recorded
/// the dose with **no** injection-site capture, even for an injection-tracked
/// medication. Only the central *Erfassen* `MedicationQuickIntakeConfirm`
/// captured a site. Web fires the popup from the card's primary mark-taken
/// handler, so the quick paths must too.
///
/// This is the small, non-blocking interstitial those quick paths present when
/// the medication is `injectionSiteCaptureEnabled`. It reuses the exact picker
/// (`IntakeSitePickerSection`) the Erfassen confirm sheet uses — same effective
/// allowed-set (per-med allow-list minus user deny-list) and rotation hint — so
/// there is one canonical site-picker across every take surface.
///
/// Flow: tap "Genommen" → this sheet → pick a site → "Als genommen markieren"
/// records WITH the site. A **skip** path ("Ohne Stelle") lets the user log the
/// dose with no site so they are never trapped. On confirm the sheet hands the
/// chosen `InjectionSite?` back to the caller, which threads it through the
/// normal `markIntakeQuick` optimistic-write + Outbox path — preserving the
/// undo-toast behaviour.
///
/// Non-eligible (oral) meds never present this sheet; the caller records
/// immediately as before, so Lisinopril keeps recording with no popup.
struct IntakeSiteCaptureSheet: View {
    @Environment(MedicationsStore.self) private var store
    @Environment(InjectionSitePrefsStore.self) private var injectionPrefs

    let medication: Medication
    /// Confirm callback — carries the chosen site (or `nil` for the skip path).
    /// The caller fires the actual `markIntakeQuick` so the optimistic-write +
    /// Outbox + undo-toast semantics stay owned by the existing store path.
    let onConfirm: (InjectionSite?) -> Void
    let onCancel: () -> Void

    @State private var selectedSite: InjectionSite?
    @State private var recentSites: [InjectionSite] = []

    var body: some View {
        // Logging the dose is the sheet's one confirmation: the check mark in
        // the bar, like every sheet. Logging without a site stays below.
        HLSheetScaffold(
            "Injektionsstelle",
            size: .standard,
            action: .confirm("meds.quick.commit") {
                onConfirm(selectedSite)
                return true
            },
            confirmIdentifier: "meds.quick.site.commit"
        ) {
            HLPage {
                summaryCard
                // Primary selector is the anatomical body map
                // (reuses the GLP1 `InjectionBodyMap`), matching the web's
                // injection-site picker. The text-tile grid stays below as a
                // secondary / accessibility fallback so every allowed site is
                // always reachable even if a dot is hard to hit.
                bodyMapCard
                // The redundant site LIST under the body
                // graphic was removed; the body map (with its legend) is the
                // single selector. Every allowed site is reachable as a dot.
                HLButton("meds.quick.site.skip", variant: .secondary) {
                    onConfirm(nil)
                }
                .accessibilityIdentifier("meds.quick.site.skip")
                // The one moment somebody thinks "never this site":
                // the deny-list is one push away, on this sheet's own stack.
                // The push rides the shared HLButton carrier (FREEZE-A,
                // 1.0.4): the sheet names no presenter of its own.
                HLButton(
                    "Manage sites",
                    systemImage: "circle.grid.cross",
                    variant: .secondary,
                    destination: { SettingsInjectionSitesScreen() }
                )
                .accessibilityIdentifier("meds.quick.site.manage")
            }
        }
        .task {
            await injectionPrefs.refresh()
            recentSites = await store.recentInjectionSites(medicationID: medication.id)
        }
    }

    /// Effective allowed set = the medication's per-med allow-list minus the
    /// user-level global deny-list (deny always wins). Mirrors the Erfassen
    /// confirm sheet so the picker offers an identical set on every surface.
    private var effectiveAllowedSites: [InjectionSite] {
        injectionPrefs.effectiveAllowed(for: medication.allowedInjectionSites)
    }

    /// Body-graphic site selector. Filters dot taps to the
    /// effective allowed set so a disallowed site can never be staged (mirrors
    /// the tile grid's allow-list). Selecting the same dot twice clears it, so
    /// the dose can still be logged with no site.
    private var bodyMapCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLCardLabel("Injektionsstelle")
                if let suggestedSite {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(HLText.secondary)
                        Text(String(
                            format: String(localized: "Vorschlag laut Rotationsplan: %@"),
                            suggestedSite.localizedLabel
                        ))
                        .hlText(.footnote)
                    }
                }
                InjectionBodyMap(
                    lastUsed: lastUsedSite,
                    suggested: suggestedSite,
                    selected: selectedSite
                ) { site in
                    guard effectiveAllowedSites.contains(site) else { return }
                    selectedSite = selectedSite == site ? nil : site
                }
            }
        }
    }

    /// Rotation suggestion, constrained to the effective allowed set — same
    /// rule the tile picker uses so both selectors agree on the hint.
    private var suggestedSite: InjectionSite? {
        guard let next = InjectionSiteRotation.suggestNext(recent: recentSites),
              effectiveAllowedSites.contains(next) else { return nil }
        return next
    }

    /// Most-recent logged site (newest-first list), surfaced as the warn-tinted
    /// "last used" dot on the body map.
    private var lastUsedSite: InjectionSite? {
        recentSites.first
    }

    /// The med name no longer renders as a huge title at
    /// the top of the confirm popup (operator: "Trulicity" was redundant). It
    /// stays as a quiet single-line caption (name · dose) so the context is
    /// still present without dominating the sheet; the navigation title
    /// ("Injektionsstelle") already names the task.
    private var summaryCard: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "pills.fill")
                .hlText(.footnote)
                .accessibilityHidden(true)
            Text(medication.dose.isEmpty
                ? medication.name
                : "\(medication.name), \(medication.dose)")
                .hlText(.factLabel)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
