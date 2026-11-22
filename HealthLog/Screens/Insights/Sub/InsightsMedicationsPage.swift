import SwiftUI

/// The Insights **Medications** special page (web
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
/// **Lives inside the Insights pager.** Owns no `NavigationStack`. The page
/// wrapper pins it `.containerRelativeFrame(.horizontal)` ONLY (the W44
/// contract).
///
/// **Self-suppress:** rendered only when the operator has ≥1 medication (gated by
/// `availableSpecials`); the defensive empty branch is a calm
/// `ContentUnavailableView`, never a dead box.
struct InsightsMedicationsPage: View {
    @Environment(MedicationsStore.self) private var store
    /// I-1 D — the BP × medication-compliance correlation card was relocated here
    /// off the Insights overview (it concerns adherence's effect on blood
    /// pressure, so the Medications page is its home). Reads the server
    /// `comprehensive` digest, so the page needs `InsightsStore`.
    @Environment(InsightsStore.self) private var insightsStore
    /// Resolves a tapped `MedicationDetailRoute` to the canonical
    /// `MedicationDetailScreen` (repos live on the container). The push runs on
    /// the Insights container's shared `NavigationStack`.
    @Environment(\.appContainer) private var appContainer
    /// Routes the empty-state CTA to the Medications tab so a
    /// first-time user has a next step instead of a dead-end empty card.
    @Environment(AppRouter.self) private var router

    /// Drives the AskCoachSheet opened from the BP × medication-
    /// compliance correlation card's "Ask the coach about this" link. The
    /// pair-specific seed/scope is set before presenting; reset on dismiss.
    @State private var presentCoach = false
    /// The coach sheet grows out of the coach button in the bar.
    @Namespace private var coachZoom
    @State private var coachSeedOverride: String?
    @State private var coachScopeOverride: CoachLaunchScope?

    var body: some View {
        content
            // The header's coach and the bp×med correlation card's link. The
            // sheet self-gates the arm / placeholder per user (same canonical sheet
            // the metric pages open); the page itself opens on adherence.
            .sheet(isPresented: $presentCoach, onDismiss: {
                coachSeedOverride = nil
                coachScopeOverride = nil
            }, content: {
                AskCoachSheet(
                    seed: coachSeedOverride,
                    launchScope: coachScopeOverride ?? CoachLaunchScope(metric: .compliance)
                )
                .hlZoomTransition(from: HLTabHeaderAction.Role.coach, in: coachZoom)
            })
            .environment(\.hlActionZoomNamespace, coachZoom)
            // Make the Insights med cards tap through (they were a
            // navigational dead-end while the sibling Mood/Workouts pages cross-link;
            // STANDARDS §8: every tile taps through). Pushes the SAME
            // `MedicationDetailScreen` the Meds-tab card reaches, via the shared
            // Insights `NavigationStack` and the typed `MedicationDetailRoute` (the
            // same route W0 wired for the Meds tab).
            .navigationDestination(for: MedicationDetailRoute.self) { route in
                medicationDetailDestination(for: route)
            }
    }

    /// Whether the assistant is on and the server offers the coach; the
    /// header shows no dead coach circle otherwise.
    private var coachVisible: Bool {
        appContainer?.aiMode != AIMode.none && appContainer?.aiMode != nil && appContainer.offersCoach
    }

    /// The (i) with the adherence method, then the coach.
    private var headerActions: HLTabHeaderActions {
        var items: [HLTabHeaderAction] = [
            .info(
                InsightsSpecialPageInfo.medications(showsCorrelation: medicationCorrelationPanel != nil),
                identifier: "insights.medications.info"
            )
        ]
        if coachVisible {
            items.append(.coach(identifier: "insights.medications.coach") { presentCoach = true })
        }
        return HLTabHeaderActions(items)
    }

    /// Resolves a `MedicationDetailRoute` to the detail screen.
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
                therapyLogRepo: container.medicationTherapyLogRepo,
                // Bucket the Verlauf track on the server-profile zone
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

    /// In the Insights pager the head is pinned above the strip.
    @Environment(\.insightsInPager) private var inPager

    /// The page's head: pinned above the strip in the pager, at the top
    /// of the content elsewhere.
    private var pageHeader: some View {
        HLTabHeader(
            "Medications",
            titleIdentifier: "insights.page.header.title.medications",
            actions: headerActions
        )
    }

    /// The page stands in every state, so the title does not jump when the
    /// medications arrive; without any the empty state sits in the free area.
    private var content: some View {
        HLPage {
            // Canonical per-page header, the same anatomy as the metric pages
            // so the header does not jump across the pager. The cards below
            // already show how many medications there are.
            if !inPager {
                pageHeader
            }
            HLStateContainer(store.activeMedications.isEmpty ? .empty : .loaded) {
                EmptyView()
            } empty: {
                emptyState
            } content: {
                ForEach(store.activeMedications) { medication in
                    medicationCard(medication)
                }

                // Aggregate compliance heatmap (window per Settings → Erscheinungsbild,
                // #13). Self-suppresses below
                // 90 days of history (`ComplianceHeatmapSection` renders an
                // `EmptyView()`), so a fresh user sees only the per-med bars.
                if !store.compliance.isEmpty {
                    HLCard {
                        // The day cells stay inert: the grid sums all
                        // medications, and a push from here would need a
                        // presenter outside the frozen presentation census.
                        ComplianceHeatmapSection(days: store.compliance)
                    }
                }

                // I-1 D — the BP × medication-compliance correlation card,
                // relocated off the overview onto the Medications page (it speaks
                // to adherence's effect on blood pressure). Self-suppresses when
                // there's no ok pairing (no empty card).
                correlationBlock

                // Canonical sync-status footer (same
                // primitive as Dashboard/Insights, self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        // WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh { await store.load() }
        // In the pager the head stands fixed at the top, over the strip.
        .insightsPageHead(enabled: inPager) { pageHeader }
    }

    private func medicationCard(_ medication: Medication) -> some View {
        let snapshot = store.cardComplianceSnapshot(for: medication)
        // The whole card opens the detail screen, with press feedback and no
        // chevron. It is an object card, so the name stands at 17 semibold as
        // on the Meds tab and in the detail head.
        return NavigationLink(value: MedicationDetailRoute(id: medication.id)) {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text("\(medication.name) \(medication.dose)")
                            .hlText(.objectName)
                        // An as-needed medication says so in this line
                        // instead of a sentence where the bars would be.
                        if let line = Self.categoryLine(medication, isAsNeeded: snapshot.map {
                            !$0.serverUnavailable && $0.displayRows.isEmpty
                        } ?? false) {
                            Text(line)
                                .hlText(.tileLabel)
                        }
                    }

                    // Render the server's cadence-scaled
                    // `complianceDisplay` windows (weekly med → 30/90) with the
                    // server-supplied day count as label, matching the med card.
                    // `nil` while the server fetch is
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
                        if snapshot.serverUnavailable {
                            // The server gave no answer; say so
                            // instead of computing a rate on the device.
                            Text("med.compliance.unavailable")
                                .hlText(.footnote)
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
        .hlPressable(hover: .lift) // Press feedback, the card rises under the pointer
        .accessibilityIdentifier("insights.medications.card.\(medication.id)")
        .accessibilityHint(Text(String(localized: "medications.row.detail_hint")))
    }

    /// I-1 D — the relocated BP × medication-compliance correlation card. Same
    /// render contract as `InsightsMetricScreen.correlationBlock`.
    @ViewBuilder
    private var correlationBlock: some View {
        if let panel = medicationCorrelationPanel {
            Group {
                HLSectionHeader("Relationships", rank: .area)
                panel
            }
        }
    }

    /// The bp x medication panel, `nil` when it has no card; the (i) explains
    /// the correlation only when the card is on the page.
    private var medicationCorrelationPanel: CorrelationsPanel? {
        guard let digest = insightsStore.digest else { return nil }
        // The bp×med card carries an "Ask the coach about this"
        // link, pre-scoped to blood pressure + compliance.
        let panel = CorrelationsPanel(
            digest: digest,
            pairs: [.bpMedication],
            onAskCoach: { pair in
                coachSeedOverride = pair.coachSeed
                coachScopeOverride = pair.coachLaunchScope
                presentCoach = true
            }
        )
        return panel.hasAnyCard ? panel : nil
    }

    /// "Blutdrucksenker", or "Blutdrucksenker, bei Bedarf" for a medication
    /// without a fixed plan (no adherence to show).
    /// The medication list's rule (`MedicationCard.categoryPillLabel`):
    /// a kind only when there is a real one. "Medikament" under every name in
    /// a page of medications said nothing, and neither did "Sonstige".
    static func categoryLine(_ medication: Medication, isAsNeeded: Bool) -> String? {
        let category = MedicationCard.categoryPillLabel(category: medication.category, label: medication.categoryLabel)
        guard isAsNeeded else { return category }
        let asNeeded = String(localized: "insights.compliance.asNeeded")
        guard let category else { return asNeeded.prefix(1).uppercased() + asNeeded.dropFirst() }
        return category + ", " + asNeeded
    }

    private var emptyState: some View {
        // Title and action; the sentence repeated the button.
        HLEmptyState(icon: "pills", title: "No medications yet") {
            // A next-step CTA so the empty page isn't a dead-end: land
            // the user on the Medications tab where "+" adds the first med.
            HLButton(
                "Add medication",
                systemImage: "plus",
                variant: .secondary
            ) {
                router.selectedTab = .meds
            }
            .accessibilityIdentifier("insights.medications.empty.add")
        }
        .accessibilityIdentifier("insights.medications.empty")
    }
}
