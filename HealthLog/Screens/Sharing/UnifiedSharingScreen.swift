import SwiftUI

/// **The one sharing surface.**
///
/// Three cards in the order ``UnifiedSharingStore/questionOrder`` names: what
/// rides, for which period, and — last — in which form. The four old cards
/// (Gesundheitsakte ZIP, Arzt-Link, Gesundheitsbericht PDF, FHIR-Export) are
/// the four values of the last question, not four flows.
///
/// **No presentation modifier lives on this screen, on purpose.** Everything
/// renders in place: no sheet, no dialog, no overlay. That is partly the calmer
/// design — a share flow that opens a modal to ask a question it could ask in
/// line is the "four surfaces" problem in miniature — and partly Phase 06's
/// frozen PHI-presentation census, which is fail-closed against new hits. A
/// surface that needs no modal owes that census nothing.
struct UnifiedSharingScreen: View {
    /// Which output the entry point implied, or `nil` for the general doors:
    /// they open with no form chosen, and the action stays locked until one is.
    let preselectedForm: UnifiedSharingStore.OutputForm?
    /// VISIT — the next visit's window, preset by "visit.next.report" on
    /// "Nächster Termin"; `nil` from every other door.
    let presetWindow: ReportWindow?

    @Environment(BackendAvailability.self) private var backend
    @Environment(DoctorReportStore.self) private var serverReportStore
    @Environment(LocalDoctorReportStore.self) private var localReportStore
    @Environment(MeasurementsStore.self) private var measurementsStore
    @Environment(MedicationsStore.self) private var medicationsStore
    @Environment(MoodStore.self) private var moodStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.appContainer) private var container

    @State private var store: UnifiedSharingStore?
    @State private var linkStore: ShareLinkStore?
    /// CU-35 (2) — the account's last practice name, offered as a prefill while
    /// the box is untouched. Kept through the consolidation: dropping it would
    /// have been a silent feature loss on the PDF path.
    @State private var practiceStore: ReportPracticeNameStore?

    init(preselectedForm: UnifiedSharingStore.OutputForm? = nil, presetWindow: ReportWindow? = nil) {
        self.preselectedForm = preselectedForm
        self.presetWindow = presetWindow
    }

    var body: some View {
        HLPage {
            if let store {
                whatCard(store)
                periodCard(store)
                formCard(store)
                formDetailCard(store)
                actionCard(store)
                manageCard
                // R1 (A360-6 App Store) — the not-a-medical-document caveat,
                // on the surface that hands the document over.
                HealthExportDisclaimerCard()
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("sharing.unified.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if store == nil {
                store = container?.makeUnifiedSharingStore(form: preselectedForm)
                store?.presetWindow(presetWindow)
            }
            if practiceStore == nil {
                practiceStore = container?.makeReportPracticeNameStore()
            }
            // Fail-soft and self-suppressing: the store short-circuits once the
            // field is the user's, so a re-entry never re-suggests over a value
            // they typed.
            await practiceStore?.loadPrefill()
            if linkStore == nil, let api = container?.api {
                linkStore = ShareLinkStore(
                    repo: ShareLinkRepository(api: api),
                    capabilities: ServerCapabilitiesRepository(api: api)
                )
            }
            await store?.load()
        }
    }

    // MARK: - 1. What

    private func whatCard(_ store: UnifiedSharingStore) -> some View {
        // No subtitle: a ticked row reads as "included" without
        // being told, and where the list comes from is not the reader's
        // question.
        HLCard("sharing.unified.what.title") {
            UnifiedSharingSelectionSection(store: store)
        }
    }

    // MARK: - 2. Period

    private func periodCard(_ store: UnifiedSharingStore) -> some View {
        // No footer: the expiry is its own card further down, so
        // "the period is content, not the link's life" needs no sentence.
        HLCard("sharing.unified.period.title") {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // The span the content covers, on every way here: a look-back
                // and a visit's preset window alike, and never past today.
                // With a preset window none of the look-backs is selected;
                // tapping one ends it.
                if let line = Self.periodLine(store.windowInterval ?? Self.lookBack(days: store.periodDays)) {
                    Text(verbatim: line)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sharing.unified.period.window")
                }
                HLAdaptiveSegmentedPicker(
                    "sharing.unified.period.title",
                    selection: Binding(
                        get: { store.window == nil ? store.periodDays : nil },
                        set: { if let days = $0 { store.chooseLookBack(days) } }
                    ),
                    labels: UnifiedSharingStore.periodOptions.map(UnifiedSharingCopy.periodLabel)
                ) {
                    ForEach(UnifiedSharingStore.periodOptions, id: \.self) { days in
                        Text(UnifiedSharingCopy.periodLabel(days)).tag(Int?.some(days))
                    }
                }
                .accessibilityIdentifier("sharing.unified.period")
            }
        }
    }

    /// The look-back as an interval ending now.
    static func lookBack(days: Int, now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        guard let start = calendar.date(byAdding: .day, value: -days, to: now) else { return nil }
        return DateInterval(start: calendar.startOfDay(for: start), end: now)
    }

    /// "21. Aug. 2026 bis 15. Nov. 2026": first and last day of the span.
    /// The interval's end is exclusive, so the last day is the one before
    /// it.
    static func periodLine(_ interval: DateInterval?) -> String? {
        guard let interval, interval.duration > 0 else { return nil }
        let last = interval.end.addingTimeInterval(-1)
        return String(localized: "sharing.unified.period.window \(HLDateFormat.date(interval.start)) \(HLDateFormat.date(last))")
    }

    // MARK: - 3. Form (last)

    private func formCard(_ store: UnifiedSharingStore) -> some View {
        // The forms as one-line choices; what the chosen one is follows in
        // full under them, where a sentence can wrap.
        HLCard("sharing.unified.form.title") {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // The row pitch of every row card, so wrapped titles at the
                // largest sizes keep apart.
                VStack(alignment: .leading, spacing: HLLayout.rowSpacing) {
                    ForEach(UnifiedSharingStore.OutputForm.allCases) { form in
                        formRow(form, store: store)
                    }
                }
                if let chosen = store.outputForm {
                    Text(UnifiedSharingCopy.formBody(chosen))
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sharing.unified.form.body")
                }
            }
        }
    }

    /// One output form: a single choice with the form's glyph. Nothing is
    /// chosen on opening (a chosen "Link" skipped the steps after it), so
    /// every row shows its open circle until one is.
    private func formRow(_ form: UnifiedSharingStore.OutputForm, store: UnifiedSharingStore) -> some View {
        HLChoiceRow(
            title: Text(UnifiedSharingCopy.formTitle(form)),
            symbol: UnifiedSharingCopy.formSymbol(form),
            isSelected: store.outputForm == form,
            mode: .singleOpen
        ) {
            store.setOutputForm(form)
        }
        .accessibilityIdentifier("sharing.unified.form.\(form.rawValue)")
    }

    // MARK: - 3b. What the chosen form still needs

    @ViewBuilder
    private func formDetailCard(_ store: UnifiedSharingStore) -> some View {
        switch store.outputForm {
        case .link:
            linkDetailCard(store)
            expiryCard(store)
        case .pdf:
            practiceCard(store)
            UnifiedSharingReportLanguageSection(store: store)
        case .zip:
            chartsCard(store)
        case .fhir, nil:
            // FHIR has nothing more to ask; with no form chosen there is
            // nothing to ask yet.
            EmptyView()
        }
    }

    private func linkDetailCard(_ store: UnifiedSharingStore) -> some View {
        @Bindable var store = store
        return HLCard("Label") {
            // The placeholder example says what a label is for.
            TextField(
                String(localized: "e.g. Dr. Schmidt — cardiology"),
                text: $store.linkLabel
            )
            .accessibilityIdentifier("sharing.unified.link.label")
        }
    }

    /// CU-35 (2) — the optional practice, with the account's last one offered
    /// while the box is untouched. Kept through the consolidation: dropping the
    /// prefill would have been a silent feature loss on the PDF path.
    private func practiceCard(_ store: UnifiedSharingStore) -> some View {
        HLCard(
            "doctorReport.practice.title",
            subtitle: "doctorReport.practice.subtitle"
        ) {
            // The prefilled name shows itself in the field; the
            // line saying where it came from is gone.
            TextField(
                String(localized: "doctorReport.practice.placeholder"),
                text: Binding(
                    get: { practiceStore?.draft ?? store.practiceName },
                    // Every keystroke goes through the prefill store so the
                    // "typed beats suggested" latch is set at the source,
                    // and through the model so the request carries it.
                    set: { typed in
                        practiceStore?.setDraftFromUser(typed)
                        store.practiceName = typed
                    }
                )
            )
            .textContentType(.organizationName)
            .autocorrectionDisabled()
            .accessibilityIdentifier("sharing.unified.practiceName")
        }
    }

    private func chartsCard(_ store: UnifiedSharingStore) -> some View {
        @Bindable var store = store
        // The card's title was the switch's own label; one heading.
        return HLCard(layout: .rows) {
            HLSettingsToggleRow(
                title: "Include charts",
                description: nil,
                isOn: $store.includeCharts,
                accessibilityID: "sharing.unified.includeCharts"
            )
        }
    }

    private func expiryCard(_ store: UnifiedSharingStore) -> some View {
        @Bindable var store = store
        // The server's rule (tomorrow at the earliest, 90 days at
        // the most) is the picker's range now, not a footer under it.
        // "Ablauf" over "Läuft ab" named it twice; the row alone.
        return HLCard {
            DatePicker(
                selection: Binding(
                    get: { store.expiresAt ?? Date.now },
                    set: { store.expiresAt = $0 }
                ),
                in: Self.expiryRange(),
                displayedComponents: .date
            ) {
                HLRowTitle("Expires")
            }
            .accessibilityIdentifier("sharing.unified.expiry")
        }
    }

    /// Tomorrow to ``UnifiedSharingStore/maxExpiryDays`` from now: the dates
    /// the server accepts for a link's expiry.
    static func expiryRange(now: Date = .now, calendar: Calendar = .current) -> ClosedRange<Date> {
        let first = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let last = calendar.date(byAdding: .day, value: UnifiedSharingStore.maxExpiryDays, to: now) ?? first
        return first ... max(first, last)
    }

    // MARK: - 4. The one action, and one feedback shape

    private func actionCard(_ store: UnifiedSharingStore) -> some View {
        HLCard("sharing.unified.action.title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // The honesty half of E1.2, next to the button that acts on it.
                // Said once, here; the copy in the selection card
                // above is gone.
                if store.isDocumentsOnly {
                    Text("sharing.unified.emptyMeaning")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sharing.unified.emptyMeaning")
                }

                HLButton(
                    Text(String(localized: UnifiedSharingCopy.actionTitle(store.outputForm))),
                    systemImage: "paperplane.fill",
                    variant: .primary,
                    isLoading: store.outcome == .working
                ) {
                    Task { await produce(store) }
                }
                .disabled(!store.canProduce || store.outcome == .working)
                .accessibilityIdentifier("sharing.unified.produce")
                // A link the server wants a fresh proof for:
                // confirm, then mint again with the elevation.
                .stepUpConfirmation(linkStore?.stepUp) { await produce(store) }
                // A grey button says why it is grey.
                if store.outputForm == nil {
                    Text("sharing.unified.produce.needsForm")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sharing.unified.produce.needsForm")
                }

                UnifiedSharingResultSection(
                    store: store,
                    linkStore: linkStore,
                    baseURL: container?.environment.baseURL
                )
            }
        }
    }

    // MARK: - What was already shared

    /// **A different question, and therefore a different surface.** This one
    /// answers "what do I want to share"; the link list answers "what have I
    /// already shared, and how do I stop it". Folding the second into the first
    /// would have made the consolidation bigger, not clearer — and revoking is
    /// the one action a user reaches for in a hurry.
    private var manageCard: some View {
        // One row, one heading: the row names its screen.
        HLCard(layout: .rows) {
            HLSettingsActionRow(
                title: "Active links",
                presents: .push
            ) {
                ShareWithClinicianScreen()
            }
            .accessibilityIdentifier("sharing.unified.manageLinks")
        }
    }

    // MARK: - Pipeline

    private func produce(_ store: UnifiedSharingStore) async {
        guard let exportStore = container?.makeExportStore(), let linkStore else { return }
        await store.produce(
            UnifiedSharingStore.OutputContext(
                exportStore: exportStore,
                reportStore: serverReportStore,
                localReportStore: localReportStore,
                linkStore: linkStore,
                snapshot: makeSnapshot(),
                locale: store.reportLanguage.rawValue,
                isBackendReachable: backend.isReachable
            )
        )
    }

    private func makeSnapshot() -> DoctorReportSpecBuilder.Snapshot {
        DoctorReportSpecBuilder.Snapshot(
            patientName: settingsStore.profile?.displayName ?? settingsStore.profile?.username ?? "",
            appVersion: Self.appVersion(),
            measurements: measurementsStore.recent,
            medications: medicationsStore.medications,
            // The FHIR bundle carries no adherence block; the
            // PDF path reads the server's adherence itself.
            moodEntries: moodStore.entries
        )
    }

    private static func appVersion() -> String {
        let bundle = Foundation.Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
