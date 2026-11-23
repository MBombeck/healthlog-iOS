import SwiftUI

/// Drug-detail screen — pushed from `MedicationsScreen` rows.
///
/// Layout mirrors Apple Health → Browse → Medications → drug detail: vertical
/// scroll, sectioned, rounded cards. The PK chart sits on the brightest
/// regulatory edge — see `MDRGatedDrugLevelSection` for the gate logic.
///
/// **MDR boundary reminders (`14-coach-mental-model.md` + GROUND RULE 15):**
/// the Y-axis is unit-less, no tick labels, no clinical interpretation. Do
/// not surface a "predicted next peak" marker. Do not auto-resolve a "next
/// dose" suggestion. Every actionable observation defers to the prescriber.
public struct MedicationDetailScreen: View {
    /// `internal` (not `private`) so the
    /// `MedicationDetailScreen+Actions.swift` same-module extension can read it.
    /// Pure visibility relax; no behaviour change.
    @State var store: MedicationDetailStore
    /// Operator brief 2026-06-07: an Edit button top-right so a
    /// wrong plan text ("Täglich 08:00" for a weekly med) can be corrected
    /// in place. Holds the medication being edited; non-nil presents the
    /// shared `EditMedicationSheet`.
    @State private var editing: Medication?
    /// Supply editor presentation. `.add` registers a new container,
    /// `.edit(item)` corrects an existing one. `nil` = closed.
    @State private var supplyEditor: SupplyEditorTarget?
    /// Internal so the +Actions extension can flash the queued banner.
    @State var queuedBannerShownAt: Date?
    /// v0.8.5 WFIX-COMPLIANCE fix 1 — the 90-day Verlauf history is gated
    /// behind a tap on the compliance KPI tile. Operator on-device read:
    /// "ich will den Verlauf nur sehen wenn ich auf die Compliance tippe,
    /// nicht direkt." Defaults collapsed so the detail screen lands tidy;
    /// the history reveals on the same tap that already routes here from
    /// the card's compliance value.
    @State private var isComplianceHistoryExpanded = false
    @State private var titrationStore: TitrationLadderStore
    @State private var sideEffectsStore: SideEffectsLogbookStore
    @State private var penInventoryStore: PenInventoryStore
    @State private var injectionSiteStore: InjectionSiteStore
    /// Internal so the +Actions extension can dispatch writes.
    @Environment(MedicationsStore.self) var medicationsStore
    /// Reach `NotificationService` to (re)arm the local low-supply
    /// alert once the server-stock-derived runway crosses the user's threshold.
    @Environment(\.appContainer) var appContainer
    /// QoL-A2 (Felt-craft #5) — gate the compliance-history expand on
    /// reduce-motion (app-wide "ALWAYS reduce-motion-gated" doctrine).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opt-in scroll/expand target for med-reminder deep links.
    /// A `healthlog://medications/<id>/history` tap (or any push with
    /// `MedicationDetailRoute.Focus.history`) should land on the Verlauf, not
    /// the top of the screen: the operator tapped a reminder expecting the
    /// dose/history. `.history` pre-expands the compliance-history disclosure
    /// and scrolls the named anchor into view once on appear. `.overview`
    /// (the default, used by in-app row taps) leaves the screen at the top.
    private let focus: MedicationDetailRoute.Focus
    /// One-shot guard so the deep-link scroll fires exactly once on first
    /// appearance, never again on a re-render or a back-navigation return.
    @State private var didApplyFocus = false
    /// W0-fix (review M3) — guards the post-`yield` deep-link scroll against a
    /// fast back-swipe that tears the view down during the single layout yield,
    /// so `proxy.scrollTo` + its `withAnimation` never run against a dead scroll
    /// view (benign, but avoids a stray animation transaction).
    @State private var isOnScreen = false
    /// Records related to this medication, from its single read.
    @State var related = RelatedRecordsModel()
    /// The composition per unit, from the same single read.
    @State var composition = MedicationCompositionModel()

    /// The screen's one banner also carries a failed GLP-1 journal action
    /// (delete, used up, a site that did not log), so none of them fails
    /// without a word. The journals only show for a recognised GLP-1
    /// medication (the site map also for tracked injections), so only then.
    private var bannerError: HLError? {
        if let error = store.error { return error }
        if store.isGLP1Recognised {
            return titrationStore.error ?? sideEffectsStore.error ?? penInventoryStore.error
                ?? injectionSiteStore.error
        }
        return store.medication.injectionSiteCaptureEnabled ? injectionSiteStore.error : nil
    }

    /// Loads the GLP-1 journals once per appearance or refresh. The sections
    /// swap between their add row and their full form when the first entry
    /// lands, so a `.task` on each of them loaded the same journal twice.
    private func loadGLP1Journals() async {
        await titrationStore.load(serverChanges: store.details?.doseChanges ?? [])
        await injectionSiteStore.load(serverIntakes: store.intakes)
        if store.isGLP1Recognised {
            await sideEffectsStore.load()
            await penInventoryStore.load()
        }
    }

    public init(
        medication: Medication,
        repo: MedicationsRepository,
        glp1LocalRepo: GLP1LocalRepository,
        // Server round-trip seam for side-effects + inventory.
        // `nil` (previews) → the stores stay purely local; non-nil → writes
        // mirror to the server via Outbox.
        therapyLogRepo: MedicationTherapyLogRepository? = nil,
        // Server-profile day-anchoring zone for the Verlauf glyph
        // track. Each push site passes the live `MedicationsStore`
        // profile-zone provider so a traveling user (device TZ ≠ profile TZ)
        // buckets each dose into the profile calendar day. Defaults to
        // `.current` so previews / un-wired call-sites stay device-TZ.
        profileTimeZoneProvider: @escaping () -> TimeZone = { .current },
        focus: MedicationDetailRoute.Focus = .overview
    ) {
        self.focus = focus
        // W-COMPLIANCE-INV Task 2 — the detail store now owns the generic
        // per-medication inventory read (`…/inventory`, all treatment
        // classes); `nil` keeps the fetch off.
        let detail = MedicationDetailStore(
            medication: medication,
            repo: repo,
            therapyRepo: therapyLogRepo,
            profileTimeZoneProvider: profileTimeZoneProvider
        )
        _store = State(initialValue: detail)
        // Both `.history` (reminder deep-link) and `.compliance` (in-app
        // compliance-bar tap) pre-expand the Verlauf disclosure. Only `.history`
        // also auto-scrolls (see `onAppear` below); `.compliance` opens at the top.
        _isComplianceHistoryExpanded = State(initialValue: focus == .history || focus == .compliance)
        _titrationStore = State(initialValue: TitrationLadderStore(
            medicationID: medication.id,
            catalogDrug: detail.drug,
            repo: glp1LocalRepo
        ))
        _sideEffectsStore = State(initialValue: SideEffectsLogbookStore(
            medicationID: medication.id,
            repo: glp1LocalRepo,
            serverRepo: therapyLogRepo
        ))
        _penInventoryStore = State(initialValue: PenInventoryStore(
            medicationID: medication.id,
            repo: glp1LocalRepo,
            serverRepo: therapyLogRepo
        ))
        _injectionSiteStore = State(initialValue: InjectionSiteStore(
            medicationID: medication.id,
            repo: glp1LocalRepo
        ))
    }

    /// A medication kept as a record with nothing logged shows no
    /// history card saying so; the hero already says it is a record. 1.4 B4:
    /// the same for every medication. Nothing logged and nothing due yet is no
    /// card, not a card saying "Noch keine Einnahmen erfasst."
    private var showsHistory: Bool {
        !store.intakes.isEmpty || !(store.doseHistory?.rows.isEmpty ?? true)
    }

    /// Scroll anchor for the `.history` deep-link focus. Placed on
    /// the compliance/Verlauf section so a reminder body-tap lands there.
    private enum ScrollAnchor: Hashable {
        case verlauf
    }

    public var body: some View {
        ScrollViewReader { proxy in
            scrollBody
                .onAppear {
                    isOnScreen = true
                    // One-shot deep-link focus. A `.history`
                    // reminder tap scrolls the Verlauf anchor into view after
                    // the layout settles; the disclosure is already pre-expanded
                    // via `isComplianceHistoryExpanded`'s init value.
                    guard focus == .history, !didApplyFocus else { return }
                    didApplyFocus = true
                    Task { @MainActor in
                        // Let the first layout pass commit before scrolling so
                        // the anchor has a resolved frame to target.
                        await Task.yield()
                        // Bail if a fast back-swipe tore the view
                        // down during the yield.
                        guard isOnScreen else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                            proxy.scrollTo(ScrollAnchor.verlauf, anchor: .top)
                        }
                    }
                }
                .onDisappear { isOnScreen = false }
        }
    }

    private var scrollBody: some View {
        HLPage {
            // Page order as on the Insights metric pages: the object with
            // its plan, adherence, the effect chart, the GLP-1 and site
            // blocks, the history, then supply, notes and links (Z16).
            // The plan stands in the object card itself; a medication kept
            // as a record (v1.39.1) shows it as information.
            MedicationHeroSection(
                medication: store.medication,
                drug: store.drug,
                latestHistoryTake: MedicationHeroSection.latestTake(
                    ledger: store.doseHistory?.rows,
                    intakes: store.intakes
                )
            )

            // #191 point 5: today's open dose with its state, and Take,
            // Skip and "Remind me later" right here, as on the web.
            MedicationDetailDoseActions(
                medication: store.medication,
                complianceDisplay: store.compliance?.complianceDisplay
            )

            // #191 point 6: when reminders come, in words, and the reminder
            // phases for every scheduled medication.
            MedicationReminderSettingsSection(
                medication: store.medication,
                currentDose: store.compliance?.complianceDisplay?.currentDose,
                timeZone: store.profileTimeZone
            )

            // Operator brief 2026-05-22: "kein
            // X-Salat, % in-time Compliance metric ergänzen". The
            // KPI tile reads the in-time ratio over the trailing
            // 30 days from the same intakes the Verlauf track
            // renders, so the two surfaces are consistent.
            //
            // v0.8.5 WFIX-COMPLIANCE fix 1 — the KPI tile is now a
            // disclosure that gates the Verlauf history below. The
            // operator reaches this screen by tapping the card's
            // compliance value; the history only unfolds on the
            // follow-up tap on this tile, so the screen stays a clean
            // "compliance number first" read by default.
            // The tile paints a STATE: placeholder
            // until the server compliance round-trip settles, then the
            // server-canonical number (ledger-first); the local interim
            // derivation can no longer paint mid-load (100→60→50 fix).
            ComplianceKPISection(
                state: store.complianceKPIState(),
                isHistoryExpanded: isComplianceHistoryExpanded,
                onToggleHistory: {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                        isComplianceHistoryExpanded.toggle()
                    }
                }
            )
            // Verlauf scroll target for the `.history`
            // deep-link focus (the compliance tile gates the Verlauf
            // history right below it).
            .id(ScrollAnchor.verlauf)

            // Verlauf glyph track replaces the
            // intake history's status-icon column for the at-a-
            // glance read. The detailed IntakeHistorySection
            // stays below for the per-row retro-mutate actions.
            //
            // The server's compliance payload
            // already carries a **90-day** `dailyCompliance` map; the
            // UI only ever read the trailing 14. Render the full window
            // the server computed so the operator sees a full quarter of
            // adherence instead of two weeks of an existing data set.
            // `VerlaufGlyphTrack` lays the 90 days out as a 7-column
            // weekday calendar so the dots stay legible at iPhone width.
            //
            // v0.8.5 WFIX-COMPLIANCE fix 1 + fix 3 — only rendered once
            // the operator taps the compliance tile above. The track
            // then itself defaults to the last 7 days with a "Mehr"
            // toggle to the full 90 (fix 3), so the reveal stays tidy.
            if isComplianceHistoryExpanded {
                VerlaufGlyphTrack(
                    glyphs: store.verlaufGlyphs(days: 90),
                    isWeeklyCadence: store.medication.schedule.isWeeklyCadence
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // v1.28 — the "Wirkung" (medication-efficacy)
            // section: a strictly-descriptive, ASSOCIATION-ONLY relation
            // between the medication and the outcome metric/lab its class
            // targets, around its start. Server-authoritative DTO
            // (`store.efficacy`); the section self-suppresses when the DTO
            // is absent (older server / hiccup) or the
            // medication is ineligible (one-shot / no-target). No verdict,
            // no efficacy score, no dose advice — see MedicationEfficacySection.
            if let efficacy = store.efficacy, efficacy.eligible {
                MedicationEfficacySection(
                    efficacy: efficacy,
                    onSelectTarget: { selection in
                        Task { await store.setEfficacyTarget(selection) }
                    }
                )
            }

            // A GLP-1 brand outside the EMA catalogue shows no
            // card saying the curve is unavailable; the section is absent.
            if store.isGLP1Recognised, let drug = store.drug {
                MDRGatedDrugLevelSection(store: store, drug: drug)
            }

            if store.isGLP1Recognised {
                // T-5 GLP-1 Detail Stack — four sub-sections gated
                // by isGLP1Recognised so non-GLP-1 medications stay
                // on the lean Apple-Health-style detail layout. 1.4 B2:
                // the journals without entries share one "add" card.
                GLP1DetailStack(
                    titrationStore: titrationStore,
                    sideEffectsStore: sideEffectsStore,
                    penInventoryStore: penInventoryStore,
                    injectionSiteStore: injectionSiteStore,
                    catalogPrefill: PenInventoryPrefill(
                        manufacturer: store.drug?.brands.first,
                        doseStrength: store.medication.dose
                    )
                )
            } else if store.medication.injectionSiteCaptureEnabled {
                // A non-GLP-1 injection medication with site
                // tracking on (insulin, B12, methotrexate, …) gets the
                // same body-map / rotation visual as the GLP-1 stack.
                // Web mounts the picker for any injection med with
                // tracking on, not just one catalog; mirror that here.
                // Self-suppresses for oral meds or tracking-off via
                // `injectionSiteCaptureEnabled` (isInjection && track).
                InjectionSitePicker(store: injectionSiteStore)
            }

            // Ledger-first Verlauf. When the
            // server's dose-history ledger loaded (v1.15.18+), it renders
            // the history: per-slot statuses graded by the SAME band
            // attribution the compliance % uses, era-aware across
            // schedule edits (v1.16.3). The legacy intake-page section
            // below stays the verbatim fallback for ≤ v1.15.17 servers.
            if showsHistory {
                if let ledger = store.doseHistory {
                    LedgerHistorySection(
                        rows: ledger.rows,
                        scheduledDose: store.medication.dose,
                        siteFor: { eventId in
                            store.intakes.first { $0.id == eventId }?.injectionSite
                        },
                        onMarkTaken: { row in ledgerRetroMark(row, status: .taken) },
                        onMarkSkipped: { row in ledgerRetroMark(row, status: .skipped) },
                        onDelete: { row in
                            if let event = Self.deleteCandidate(for: row) { deleteIntake(event) }
                        },
                        onPin: { row in ledgerPin(row) },
                        onUnpin: { row in ledgerUnpin(row) }
                    )
                } else {
                    IntakeHistorySection(
                        // Re-sort by `scheduledFor desc` — server's
                        // `takenAt desc` scatters past-due-pending rows above today's.
                        // The section also re-sorts internally so the
                        // filter chip stays in charge of row order regardless of caller.
                        intakes: store.intakes.sorted { $0.scheduledFor > $1.scheduledFor },
                        hasMore: store.hasMoreIntakes,
                        dose: store.medication.dose,
                        totalCount: store.intakesMeta?.total,
                        isLoading: store.isLoading,
                        onLoadMore: { Task { await store.loadMoreIntakes() } },
                        onMarkTaken: { event in retroMark(event: event, status: .taken) },
                        onMarkSkipped: { event in retroMark(event: event, status: .skipped) },
                        onDelete: { event in deleteIntake(event) },
                        onEditTime: { event, newTime in editIntakeTime(event, to: newTime) }
                    )
                }
            }

            // W-COMPLIANCE-INV Task 2 — generic per-medication inventory
            // for ALL treatment classes (web "Bestand" tab parity). The
            // server route is generic; pre-fix iOS rendered inventory only
            // via the GLP-1-gated `details?.inventory` aggregate below, so
            // stored pen/injection/tablet items were invisible for every
            // non-GLP-1 medication.
            // Render whenever a server seam exists (the section
            // carries its own register affordance now, so an empty supply
            // is no longer hidden). Falls back to the GLP-1 aggregate only
            // when no generic list is available at all.
            if let items = store.inventoryItems {
                MedicationInventorySection(
                    medication: store.medication,
                    items: items,
                    summary: store.inventorySummary,
                    // The runway is the SERVER's
                    // (v1.37.19 `runwayDays`, from the same slot-aware burn
                    // rate its low-stock push evaluates). Nothing is
                    // projected here; the only local step is the display
                    // gate, which hides a comfortable runway behind the
                    // user's threshold (the local mirror of
                    // `notificationPrefs.medication.lowStockRunwayDays`).
                    runwayDays: MedicationInventorySection.runwayWithinThreshold(
                        store.medication.runwayDays,
                        threshold: LowStockRunwayPrefStore.days()
                    ),
                    onEdit: { supplyEditor = .edit($0) },
                    onRegister: { supplyEditor = .add }
                )
            }

            if let inventory = store.details?.inventory {
                InventorySection(inventory: inventory)
            }

            if let notes = doseChangeNote(store.details) {
                NotesSection(text: notes)
            }

            MedicationCoursesSection(medication: store.medication) // Courses, under "Erweitert"

            MedicationCompositionSection(model: composition, medication: store.medication) {
                await related.reload()
            }

            RelatedRecordsLoadedSection(model: related)

            // Canonical sync-status footer (same
            // primitive as Dashboard/Insights, self-suppressing).
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
        .navigationTitle(store.medication.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.load()
            // T-5 GLP-1 Detail Stack — fan-out server data into the
            // titration + site stores so they merge with local rows.
            await loadGLP1Journals()
        }
        .task(id: store.medication.id) { await loadRelated() }
        .refreshable {
            await store.load()
            await loadGLP1Journals()
            await related.reload()
        }
        // The inventory fetch is the signal that the supply view
        // of this medication has settled (a supply edit / intake refetch
        // reloads both it and the medication row), so it is where the server's
        // runway is re-read against the user's threshold and the local alert is
        // (re)armed. Fires once per crossing via `LowSupplyAlertLedger`; a
        // recovery above threshold clears it. No runway is computed here.
        // A medication edited into a GLP-1 one shows its journals now, not
        // after the next appearance.
        .onChange(of: store.isGLP1Recognised) { _, recognised in
            if recognised { Task { await loadGLP1Journals() } }
        }
        .onChange(of: store.inventoryItems) { _, items in
            reconcileLowSupplyAlert(items: items)
        }
        // The banner below still presents as this overlay; this
        // reserves its height at the top so it covers nothing.
        .hlReserveErrorBannerSpace(bannerError)
        .overlay(alignment: .top) {
            VStack(spacing: HLSpace.sm) {
                if let error = bannerError {
                    ErrorBanner(error: error) {
                        Task {
                            await store.load()
                            await loadGLP1Journals()
                        }
                    }
                }
                if queuedBannerShownAt != nil {
                    RetroMutateQueuedBanner()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .hlAnimation(.default, value: queuedBannerShownAt)
        }
        // The delete in a history row's menu asks here, on the page.
        .hlDeleteConfirmation()
        // Edit is the page's only action, so the pencil stands on its own
        // in the bar; it opens the shared EditMedicationSheet.
        .hlPageActions([.edit { editing = store.medication }])
        .sheet(item: $editing) { medication in
            EditMedicationSheet(
                medication: medication,
                onSaved: {
                    editing = nil
                    // Reload so a corrected plan / name shows immediately on
                    // the detail screen. The sheet writes via MedicationsStore;
                    // refresh that list, swap the edited Medication into the
                    // detail store (updates hero name/dose + ScheduleSection in
                    // place), then re-fetch the GLP-1 / intake / compliance data.
                    let medId = store.medication.id
                    Task {
                        await medicationsStore.load(force: true)
                        if let updated = medicationsStore.medications.first(where: { $0.id == medId }) {
                            store.updateMedication(updated)
                        }
                        await store.load()
                    }
                }
            )
        }
        // Generic supply editor (register / correct / mark / delete).
        .sheet(item: $supplyEditor) { target in
            MedicationSupplyEditorSheet(
                medication: store.medication,
                item: target.item,
                onRegister: { body in
                    try? await store.registerContainer(body)
                    supplyEditor = nil
                },
                onUpdate: { patch in
                    try? await store.updateContainer(itemID: target.item?.id ?? "", patch: patch)
                    supplyEditor = nil
                },
                onDelete: {
                    try? await store.deleteContainer(itemID: target.item?.id ?? "")
                    supplyEditor = nil
                }
            )
        }
    }

    /// Supply-editor presentation target. `Identifiable` so it drives a
    /// `.sheet(item:)`; `.add` and `.edit(item)` are distinct presentations.
    private enum SupplyEditorTarget: Identifiable {
        case add
        case edit(MedicationInventoryItemDTO)

        var id: String {
            switch self {
            case .add: "add"
            case let .edit(item): item.id
            }
        }

        var item: MedicationInventoryItemDTO? {
            switch self {
            case .add: nil
            case let .edit(item): item
            }
        }
    }

    /// Pick the most-recent dose-change note for the Notes section.
    private func doseChangeNote(_ details: Glp1DetailsDTO?) -> String? {
        details?.doseChanges
            .reversed()
            .compactMap(\.note)
            .first { !$0.isEmpty }
    }

    // The retro-mutate / ledger-row write actions + the MED-4/C3 low-supply
    // alert reconcile — `reconcileLowSupplyAlert(items:)`,
    // `retroMark(event:status:)`, `deleteIntake(_:)`,
    // `ledgerRetroMark(_:status:)`, `ledgerPin(_:)`, `ledgerUnpin(_:)`,
    // `deleteCandidate(for:)`, `handleOutcome(_:rollback:)` — live in
    // `MedicationDetailScreen+Actions.swift` to keep this file under the
    // 600-line `file_length` swiftlint budget.
}
