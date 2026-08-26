import SwiftUI

/// **Phase 18 / E1.1 — the one sharing surface.**
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
    /// Which output the entry point implied. The four old doors preselect
    /// their own form so a user who tapped "FHIR-Export" still lands on FHIR.
    let preselectedForm: UnifiedSharingStore.OutputForm

    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
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

    init(preselectedForm: UnifiedSharingStore.OutputForm = .link) {
        self.preselectedForm = preselectedForm
    }

    var body: some View {
        HLSettingsPage(title: "sharing.unified.title") {
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
        HLSettingsCard(
            icon: "checklist",
            title: "sharing.unified.what.title",
            subtitle: "sharing.unified.what.subtitle"
        ) {
            UnifiedSharingSelectionSection(
                store: store,
                hasServer: backend.hasServer,
                onConnect: { authStore.beginServerPairing() }
            )
        }
    }

    // MARK: - 2. Period

    private func periodCard(_ store: UnifiedSharingStore) -> some View {
        @Bindable var store = store
        // R5 — one text slot. The footer carries the consequence a user cannot
        // read off the control: that this is content, not the link's life.
        return HLSettingsCard(
            icon: "calendar",
            title: "sharing.unified.period.title",
            footer: "sharing.unified.period.footer"
        ) {
            Picker(selection: $store.periodDays) {
                ForEach(UnifiedSharingStore.periodOptions, id: \.self) { days in
                    Text(UnifiedSharingCopy.periodLabel(days)).tag(days)
                }
            } label: {
                Text("sharing.unified.period.title")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sharing.unified.period")
        }
    }

    // MARK: - 3. Form (last)

    private func formCard(_ store: UnifiedSharingStore) -> some View {
        HLSettingsCard(
            icon: "square.and.arrow.up",
            title: "sharing.unified.form.title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                ForEach(UnifiedSharingStore.OutputForm.allCases) { form in
                    formRow(form, store: store)
                }
            }
        }
    }

    private func formRow(_ form: UnifiedSharingStore.OutputForm, store: UnifiedSharingStore) -> some View {
        Button {
            store.setOutputForm(form)
        } label: {
            HStack(alignment: .top, spacing: HLSpace.md) {
                Image(systemName: store.outputForm == form ? "largecircle.fill.circle" : "circle")
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(store.outputForm == form ? HLColor.statusOK : HLText.tertiary)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(UnifiedSharingCopy.formTitle(form))
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(UnifiedSharingCopy.formBody(form))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case .zip:
            chartsCard(store)
        case .fhir:
            fhirScopeCard
        }
    }

    private func linkDetailCard(_ store: UnifiedSharingStore) -> some View {
        @Bindable var store = store
        return HLSettingsCard(icon: "link.badge.plus", title: "Label") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                TextField(
                    String(localized: "e.g. Dr. Schmidt — cardiology"),
                    text: $store.linkLabel
                )
                .accessibilityIdentifier("sharing.unified.link.label")
                Text("A name to recognise this link later (1–120 characters).")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// CU-35 (2) — the optional practice, with the account's last one offered
    /// while the box is untouched. Kept through the consolidation: dropping the
    /// prefill would have been a silent feature loss on the PDF path.
    private func practiceCard(_ store: UnifiedSharingStore) -> some View {
        HLSettingsCard(
            icon: "building.2",
            title: "doctorReport.practice.title",
            subtitle: "doctorReport.practice.subtitle"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
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

                if practiceStore?.didPrefill == true {
                    Text("doctorReport.practice.prefilled")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sharing.unified.practicePrefilled")
                }
            }
        }
    }

    private func chartsCard(_ store: UnifiedSharingStore) -> some View {
        @Bindable var store = store
        return HLSettingsCard(icon: "chart.xyaxis.line", title: "Include charts") {
            HLSettingsToggleRow(
                title: "Include charts",
                description: nil,
                isOn: $store.includeCharts,
                accessibilityID: "sharing.unified.includeCharts"
            )
        }
    }

    private var fhirScopeCard: some View {
        HLSettingsCard(icon: "doc.text.fill.viewfinder", title: "sharing.unified.form.fhir.title") {
            Text("sharing.unified.fhir.scopeNote")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sharing.unified.fhir.scopeNote")
        }
    }

    private func expiryCard(_ store: UnifiedSharingStore) -> some View {
        @Bindable var store = store
        // R5 — one text slot; the footer carries the server's rule, which is
        // the thing the picker itself cannot say.
        return HLSettingsCard(
            icon: "clock.badge.xmark",
            title: "Expiry",
            footer: "Required. The link stops working after this date (at most 90 days from now)."
        ) {
            DatePicker(
                "Expires",
                selection: Binding(
                    get: { store.expiresAt ?? Date.now },
                    set: { store.expiresAt = $0 }
                ),
                displayedComponents: .date
            )
            .accessibilityIdentifier("sharing.unified.expiry")
        }
    }

    // MARK: - 4. The one action, and one feedback shape

    private func actionCard(_ store: UnifiedSharingStore) -> some View {
        HLSettingsCard(icon: "paperplane.fill", title: "sharing.unified.action.title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // The honesty half of E1.2, next to the button that acts on it.
                if store.isDocumentsOnly {
                    Text("sharing.unified.emptyMeaning")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sharing.unified.action.emptyMeaning")
                }

                HLButton(
                    String(localized: UnifiedSharingCopy.actionTitle(store.outputForm)),
                    icon: "paperplane.fill",
                    variant: .primary,
                    isLoading: store.outcome == .working
                ) {
                    Task { await produce(store) }
                }
                .disabled(!store.canProduce || store.outcome == .working)
                .accessibilityIdentifier("sharing.unified.produce")

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
        HLSettingsCard(
            icon: "list.bullet.rectangle",
            title: "Active links"
        ) {
            HLSettingsActionRow(
                title: "sharing.unified.manage.row",
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
                locale: Locale.current.language.languageCode?.identifier ?? "de",
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
            compliance: medicationsStore.compliance,
            intakes: medicationsStore.todayIntakes,
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
