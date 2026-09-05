import SwiftUI

/// **v0.11 #60 — quick-path injection-site capture interstitial.**
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
    /// #105 — pushes the global deny-list editor onto this sheet's own stack.
    @State private var showManageSites = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HLSpace.lg) {
                    summaryCard
                    // v0.14 BC — primary selector is the anatomical body map
                    // (reuses the GLP1 `InjectionBodyMap`), matching the web's
                    // injection-site picker. The text-tile grid stays below as a
                    // secondary / accessibility fallback so every allowed site is
                    // always reachable even if a dot is hard to hit.
                    bodyMapCard
                    // v0.14.1 ITEM-C — the redundant site LIST under the body
                    // graphic was removed; the body map (with its legend) is the
                    // single selector. Every allowed site is reachable as a dot.
                    HLButton(
                        String(localized: "meds.quick.commit"),
                        icon: "checkmark.circle.fill",
                        variant: .restrained
                    ) {
                        onConfirm(selectedSite)
                    }
                    .accessibilityIdentifier("meds.quick.site.commit")
                    HLButton(
                        String(localized: "meds.quick.site.skip"),
                        variant: .secondary,
                        size: .regular
                    ) {
                        onConfirm(nil)
                    }
                    .accessibilityIdentifier("meds.quick.site.skip")
                    // #105 — the one moment somebody thinks "never this site":
                    // the deny-list is one push away, on this sheet's own stack.
                    HLButton(
                        String(localized: "Manage sites"),
                        icon: "circle.grid.cross",
                        variant: .secondary,
                        size: .compact
                    ) {
                        showManageSites = true
                    }
                    .accessibilityIdentifier("meds.quick.site.manage")
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
                .padding(.bottom, HLSpace.xl)
            }
            .hlScreenBackground()
            .navigationDestination(isPresented: $showManageSites) {
                SettingsInjectionSitesScreen()
            }
            .navigationTitle(Text("Injektionsstelle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "meds.quick.cancel")) { onCancel() }
                        .accessibilityIdentifier("meds.quick.site.cancel")
                }
            }
        }
        .hlSheetPresentation(.standard)
        .presentationBackground(HLColor.surface)
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

    /// **v0.14 BC** — body-graphic site selector. Filters dot taps to the
    /// effective allowed set so a disallowed site can never be staged (mirrors
    /// the tile grid's allow-list). Selecting the same dot twice clears it, so
    /// the dose can still be logged with no site.
    private var bodyMapCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLSectionLabel("Injektionsstelle")
                if let suggestedSite {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(HLText.secondary)
                        Text(String(
                            format: String(localized: "Vorschlag laut Rotationsplan: %@"),
                            suggestedSite.localizedLabel
                        ))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
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

    /// **v0.14.1 ITEM-C** — the med name no longer renders as a huge title at
    /// the top of the confirm popup (operator: "Trulicity" was redundant). It
    /// stays as a quiet single-line caption (name · dose) so the context is
    /// still present without dominating the sheet; the navigation title
    /// ("Injektionsstelle") already names the task.
    private var summaryCard: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "pills.fill")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            Text(medication.dose.isEmpty
                ? medication.name
                : "\(medication.name) · \(medication.dose)")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
