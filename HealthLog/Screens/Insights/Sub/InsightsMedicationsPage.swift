import SwiftUI

/// v0.11 W28c — the Insights **Medications** special page (web
/// `/insights/medications`).
///
/// A per-medication adherence surface (NOT a single-metric chart): one card per
/// active medication carrying its 7-day + 30-day compliance bars (the same
/// server-canonical `cardComplianceSnapshot` the Medications tab uses), the
/// category label, and — once enough history exists — the aggregate
/// `ComplianceHeatmapSection` (GitHub-style grid; window length per Settings →
/// Erscheinungsbild, #13). Medication compliance
/// is event-driven, so the page reads `MedicationsStore` directly rather than a
/// measurement series.
///
/// **Lives inside the Insights pager.** Owns no `NavigationStack`. Its inner
/// `ScrollView` reports its offset to `InsightsStripVisibility` for
/// hide-on-scroll; the page wrapper pins it `.containerRelativeFrame(.horizontal)`
/// ONLY (the W44 contract).
///
/// **Self-suppress:** rendered only when the operator has ≥1 medication (gated by
/// `availableSpecials`); the defensive empty branch is a calm
/// `ContentUnavailableView`, never a dead box.
struct InsightsMedicationsPage: View {
    @Environment(MedicationsStore.self) private var store
    @Environment(InsightsStripVisibility.self) private var stripVisibility
    /// I-1 D — the BP × medication-compliance correlation card was relocated here
    /// off the Insights overview (it concerns adherence's effect on blood
    /// pressure, so the Medications page is its home). Reads the server
    /// `comprehensive` digest, so the page needs `InsightsStore`.
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(BackendAvailability.self) private var backend
    /// v0.12 W4-2 — resolves a tapped `MedicationDetailRoute` to the canonical
    /// `MedicationDetailScreen` (repos live on the container). The push runs on
    /// the Insights container's shared `NavigationStack`.
    @Environment(\.appContainer) private var appContainer
    /// QoL-4 (A360-4) — routes the empty-state CTA to the Medications tab so a
    /// first-time user has a next step instead of a dead-end empty card.
    @Environment(AppRouter.self) private var router

    /// A360 H2 (v0156) — drives the AskCoachSheet opened from the BP × medication-
    /// compliance correlation card's "Ask the coach about this" link. The
    /// pair-specific seed/scope is set before presenting; reset on dismiss.
    @State private var presentCoach = false
    @State private var coachSeedOverride: String?
    @State private var coachScopeOverride: CoachLaunchScope?

    var body: some View {
        Group {
            if store.activeMedications.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(HLSurface.primary.ignoresSafeArea())
        // A360 H2 — the relocated bp×med correlation card's coach affordance. The
        // sheet self-gates the arm / placeholder per user (same canonical sheet
        // the metric pages open).
        .sheet(isPresented: $presentCoach, onDismiss: {
            coachSeedOverride = nil
            coachScopeOverride = nil
        }, content: {
            AskCoachSheet(
                seed: coachSeedOverride,
                launchScope: coachScopeOverride
            )
        })
        // v0.12 W4-2 — make the Insights med cards tap through (they were a
        // navigational dead-end while the sibling Mood/Workouts pages cross-link;
        // STANDARDS §8: every tile taps through). Pushes the SAME
        // `MedicationDetailScreen` the Meds-tab card reaches, via the shared
        // Insights `NavigationStack` and the typed `MedicationDetailRoute` (the
        // same route W0 wired for the Meds tab).
        .navigationDestination(for: MedicationDetailRoute.self) { route in
            medicationDetailDestination(for: route)
        }
    }

    /// v0.12 W4-2 — resolves a `MedicationDetailRoute` to the detail screen.
    /// `activeMedications` is already loaded (the page only renders when it is
    /// non-empty), so a tapped row always finds its medication; the defensive
    /// branch shows a calm progress placeholder rather than a dead end if the
    /// container or medication is momentarily absent.
    @ViewBuilder
    private func medicationDetailDestination(for route: MedicationDetailRoute) -> some View {
        if let container = appContainer,
           let medication = store.medications.first(where: { $0.id == route.id })
        {
            MedicationDetailScreen(
                medication: medication,
                repo: container.medicationsRepo,
                glp1LocalRepo: container.glp1LocalRepo,
                therapyLogRepo: container.syncModeStore.isPaired ? container.medicationTherapyLogRepo : nil,
                // W-TZ-MED — bucket the Verlauf track on the server-profile zone
                // (the same provider the medications store's due-derive uses).
                profileTimeZoneProvider: store.profileTimeZoneProvider,
                focus: route.focus
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hlScreenBackground()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                // v0.13.1 UX-D8/D2 — canonical per-page header (large title +
                // sub-line + equal-circle trailing slot), IDENTICAL anatomy to
                // the metric pages so the header doesn't jump across the pager.
                // Compliance has no per-page gear/coach target, so the trailing
                // slot is empty (no dead affordance) — only the shape unifies.
                InsightsPageHeader(
                    "Medications",
                    subtitle: LocalizedStringKey(subtitle),
                    accessibilityIdentifierSuffix: "medications"
                )

                // I-0 Item 3 — the server-mirrored intro paragraph, IDENTICAL to
                // the `InsightsMetricScreen.descriptionSlot`. The Medications page
                // previously carried NO intro and read broken next to the metric
                // pages; it now opens with the same explainer body (`medications`
                // slug = the web "Medication adherence" copy).
                InsightsExplainerIntro(slug: "medications")

                ForEach(store.activeMedications) { medication in
                    medicationCard(medication)
                }

                // Aggregate compliance heatmap (window per Settings → Erscheinungsbild,
                // #13). Self-suppresses below
                // 90 days of history (`ComplianceHeatmapSection` renders an
                // `EmptyView()`), so a fresh user sees only the per-med bars.
                if !store.compliance.isEmpty {
                    HLCard {
                        ComplianceHeatmapSection(days: store.compliance)
                    }
                }

                // I-1 D — the BP × medication-compliance correlation card,
                // relocated off the overview onto the Medications page (it speaks
                // to adherence's effect on blood pressure). Self-suppresses when
                // there's no ok pairing (no empty card).
                correlationBlock

                // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
                // primitive as Dashboard/Insights, self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxl)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            stripVisibility.report(offset: newOffset)
        }
        .hlScrollEdgeSoft()
        // W-B184 — WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh { await store.load() }
    }

    private func medicationCard(_ medication: Medication) -> some View {
        let snapshot = store.cardComplianceSnapshot(
            for: medication,
            windowIntakes: store.derivedTodayIntakes
        )
        // v0.12 W4-2 — the whole card is a tap target into the detail screen
        // (was a plain HLCard dead-end). `.buttonStyle(.plain)` keeps the card
        // chrome flat — no list-row tint — while the NavigationLink supplies the
        // push + the chevron-free affordance the operator already knows from the
        // Meds-tab cards.
        return NavigationLink(value: MedicationDetailRoute(id: medication.id)) {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text("\(medication.name) \(medication.dose)")
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                        Text(categoryLabel(medication))
                            .font(.hlCaption.weight(.semibold))
                            .foregroundStyle(HLText.secondary)
                    }

                    // v0.14.1 #127 — render the server's cadence-scaled
                    // `complianceDisplay` windows (weekly med → 30/90) with the
                    // server-supplied day count as label, matching the med card.
                    // W-COMPLIANCE-INV — `nil` while the server fetch is
                    // pending: paint a redacted skeleton pair instead of a
                    // local interim value that would jump on server arrival.
                    if let snapshot {
                        ForEach(snapshot.displayRows, id: \.days) { row in
                            HLComplianceBar(
                                label: String(
                                    format: String(localized: "med.card.compliance.window.label"),
                                    row.days
                                ),
                                rate: row.rate
                            )
                        }
                        if snapshot.displayRows.isEmpty {
                            // PRN / schedule-less medication — no rate to show.
                            Text("insights.compliance.prn")
                                .font(.hlCaption)
                                .foregroundStyle(HLText.tertiary)
                        }
                    } else {
                        ForEach([7, 30], id: \.self) { days in
                            HLComplianceBar(
                                label: String(
                                    format: String(localized: "med.card.compliance.window.label"),
                                    days
                                ),
                                rate: 0
                            )
                        }
                        .redacted(reason: .placeholder)
                        .accessibilityLabel(Text(String(localized: "med.compliance.loading")))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .hlPressable() // QOL-AUDIT H1: press feedback
        .accessibilityIdentifier("insights.medications.card.\(medication.id)")
        .accessibilityHint(Text(String(localized: "medications.row.detail_hint")))
    }

    /// I-1 D — the relocated BP × medication-compliance correlation card. Same
    /// render contract as `InsightsMetricScreen.correlationBlock`.
    @ViewBuilder
    private var correlationBlock: some View {
        if backend.canShowCloudInsights, let digest = insightsStore.digest {
            // A360 H2 — the bp×med card carries an "Ask the coach about this"
            // link, pre-scoped to blood pressure + compliance.
            let panel = CorrelationsPanel(
                digest: digest,
                pairs: [.bpMedication],
                showsDisclaimer: false,
                onAskCoach: { pair in
                    coachSeedOverride = pair.coachSeed
                    coachScopeOverride = pair.coachLaunchScope
                    presentCoach = true
                }
            )
            if panel.hasAnyCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    InsightsSectionHeader("Relationships", flush: true)
                    panel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func categoryLabel(_ medication: Medication) -> String {
        guard let raw = medication.category, !raw.isEmpty else {
            return String(localized: "med.card.category.fallback")
        }
        return MedicationCard.localizedCategory(raw)
    }

    /// Localized, plural-aware count line ("3 medications" / "1 Medikament").
    private var subtitle: String {
        String(localized: "insights.medicationsCount \(store.activeMedications.count)")
    }

    private var emptyState: some View {
        HLEmptyState(
            icon: "pills",
            title: "No medications yet",
            message: "Add your first medication. Reminders, compliance heatmap and history follow automatically."
        ) {
            // QoL-4 — a next-step CTA so the empty page isn't a dead-end: land
            // the user on the Medications tab where "+" adds the first med.
            HLButton(
                String(localized: "Add medication"),
                icon: "plus",
                variant: .restrained
            ) {
                router.selectedTab = .meds
            }
            .accessibilityIdentifier("insights.medications.empty.add")
        }
        .accessibilityIdentifier("insights.medications.empty")
        .containerCentered()
    }
}
