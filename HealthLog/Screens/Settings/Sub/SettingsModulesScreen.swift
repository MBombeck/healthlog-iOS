import SwiftUI

/// `/settings/modules` — per-user feature-module switchboard (#30 / v1.18.1 §4).
///
/// Lists every **user-toggleable** module with an optimistic toggle backed by
/// `PATCH /api/auth/me/modules` through ``ModuleGate``. Most keys are
/// default-ON; `nutrients` and `mcp` are the two genuine opt-ins (`optIn: true`
/// server-side).
///
/// DELEGATED modules (cycle / coach) are intentionally **not** offered here —
/// the server `422 modules.invalid`s a PATCH naming them (their state is owned
/// by other resolvers). The three CORE domains (weight / blood pressure /
/// pulse) are noted read-only in a closing "always on" card; they are server
/// `CORE_DOMAIN_KEYS`, not modules, so they have no toggle to offer.
///
/// Server-first: the displayed value is ``ModuleGate.isEnabled(_:)`` (default-on
/// when the server map is absent). A toggle snaps optimistically, then the PATCH
/// confirms; a non-retriable failure reverts the row and surfaces the alert.
///
/// **Audit A-7 — this screen is where a module that is off says why.** The More
/// tab keeps HIDING the rows of switched-off modules (a tab full of dead rows
/// explaining themselves would be worse than a short one), so the explanation
/// has to live somewhere a person can reach: here. Every offered module stays
/// listed whatever its state, and a module the viewer cannot switch — the
/// operator turned it off instance-wide, or the sharing grant they are inside
/// does not cover it — shows the server's own sentence
/// (``ModuleGate/offReason(_:)``) in place of its subtitle, with the switch
/// visible but inert. Before A-7 that row offered a switch that would have
/// moved nothing.
struct SettingsModulesScreen: View {
    @Environment(\.appContainer) private var container

    @State private var inFlight: Set<ModuleKey> = []
    @State private var showError = false

    var body: some View {
        HLSettingsPage(title: "Modules") {
            toggleableCard
            coreCard
        }
        .navigationTitle("Modules")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(localized: "Could not update modules. Please try again."),
            isPresented: $showError
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
    }

    /// UI-Standard R2 — der Karten-Subtitle („Jeder Schalter blendet die
    /// zugehörigen Bildschirme, Kacheln und Erinnerungen ein oder aus.")
    /// erzählte die Schalter darunter nach und stand außerdem wortgleich in
    /// der Hub-Zeile „Optionale Funktionen ein- oder ausschalten". Gefallen.
    private var toggleableCard: some View {
        HLSettingsCard(
            icon: "square.grid.2x2.fill",
            title: "Optional features"
        ) {
            ForEach(SettingsModulesScreen.offeredKeys) { key in
                moduleToggleRow(key)
            }
        }
    }

    /// The modules offered as toggles: user-toggleable keys only — excludes the
    /// DELEGATED (cycle/coach) keys the server would `422`. Since Build 2 / 2.6
    /// this includes `medications`, `environment`, `mentalHealth` and `mcp`.
    static let offeredKeys: [ModuleKey] = ModuleKey.allCases.filter(\.isUserToggleable)

    private func moduleToggleRow(_ key: ModuleKey) -> some View {
        // #30 — observe the gate map so the toggle reflects a 403-driven flip too.
        let gate = container?.moduleGate
        _ = gate?.modules
        _ = gate?.moduleAccess // Audit A-7 — re-render when the reasons change too.
        let isOn = gate?.isEnabled(key) ?? true
        let busy = inFlight.contains(key)
        // Audit A-7 (fix round 1) — one seam, and it resolves the state itself.
        // This row is the one place a reason becomes a locked switch, so it must
        // obey the same "the boolean wins on a disagreement" rule the reason
        // sentence obeys; reading the raw map here bypassed it.
        let row = SettingsModulesScreen.rowPresentation(gate: gate, key: key)
        return HLSettingsToggleRow(
            title: key.displayTitle,
            // Audit A-7 — a module the viewer cannot switch replaces its
            // marketing subtitle with the reason it is off. `disabled` (the
            // viewer's own switch) keeps the subtitle: the row is simply off.
            description: row.reasonKey.map { LocalizedStringKey($0) } ?? key.displaySubtitle,
            isOn: Binding(
                get: { isOn },
                set: { newValue in toggle(key, to: newValue) }
            ),
            isBusy: busy,
            isEnabled: !busy && gate != nil && row.isSwitchOffered,
            accessibilityID: "settings.modules.toggle.\(key.rawValue)"
        )
    }

    /// **Audit A-7 (fix round 1) — the seam the screen and the tests share.**
    ///
    /// The resolution used to live at the call site, so a test could hand
    /// ``rowPresentation(for:)`` a state it had reconciled itself and stay green
    /// over a screen that read the RAW map. Both halves — which state a row
    /// presents, and how it presents it — now sit behind one function, and the
    /// suite asserts through it.
    @MainActor
    static func rowPresentation(gate: ModuleGate?, key: ModuleKey) -> RowPresentation {
        rowPresentation(for: gate?.reconciledAccessState(key))
    }

    /// **Audit A-7 — how one switchboard row reads, given the server's verdict.**
    ///
    /// Pure and `nonisolated` so the rule can be asserted without a view: the
    /// screen's whole A-7 behaviour is this function plus the two fields it
    /// returns.
    ///
    /// - `nil` state (server < v1.38.15, or the key is not in the map) and
    ///   `enabled` / `disabled` → exactly today's row: the module subtitle, an
    ///   interactive switch.
    /// - `not_granted` / `unavailable` / an unknown future state → the switch
    ///   stays VISIBLE but disabled (a missing row is what A-7 is about), and
    ///   the reason takes the subtitle's place.
    nonisolated static func rowPresentation(for state: ModuleAccessState?) -> RowPresentation {
        guard let state, !state.offersSwitch else {
            return RowPresentation(reasonKey: nil, isSwitchOffered: true)
        }
        return RowPresentation(reasonKey: state.offReasonKey, isSwitchOffered: false)
    }

    /// Audit A-7 — the two things a module's access state changes about its row.
    struct RowPresentation: Equatable, Sendable {
        /// Catalogue key of the reason sentence, or `nil` to keep the module's
        /// own subtitle.
        let reasonKey: String?
        /// Whether the switch stays interactive.
        let isSwitchOffered: Bool
    }

    /// Build 2 / 2.6 — `medications` dropped from the copy. It is a real,
    /// user-toggleable module server-side (registry D3 / web v1.18.1), so
    /// naming it here told the user something false. What remains are the three
    /// genuine `CORE_DOMAIN_KEYS`, which are not `ModuleKey`s at all.
    ///
    /// UI-Standard R5 — die Karte belegte beide Beitext-Slots mit derselben
    /// Aussage. Der Subtitle („Kerndaten können nicht ausgeschaltet werden.")
    /// formulierte den Kartentitel „Immer aktiv" um; der Footer bleibt, weil
    /// er als einziger *nennt*, welche drei Domänen gemeint sind.
    private var coreCard: some View {
        HLSettingsCard(
            icon: "lock.fill",
            title: "Always on",
            footer: "Weight, blood pressure and pulse are always available."
        ) {
            EmptyView()
        }
    }

    private func toggle(_ key: ModuleKey, to newValue: Bool) {
        guard let gate = container?.moduleGate else { return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            let ok = await gate.setEnabled(key, enabled: newValue)
            inFlight.remove(key)
            if !ok {
                showError = true
                return
            }
            // GH #48 — the nutrients module drives a HealthKit read of the
            // Dietary* catalog types, which are deliberately kept OUT of the
            // always-on onboarding sheet. Request their read-authorization
            // lazily the moment the module is switched ON (never before), then
            // kick a first sync so the 30-day backfill starts immediately.
            if key == .nutrients, newValue {
                try? await container?.healthKit?.requestNutrientAuthorizationIfNeeded()
                await container?.nutrientDailySync?.triggerNutrientSync()
            }
        }
    }
}

// MARK: - Module display metadata

extension ModuleKey {
    /// Localized switchboard row title. Catalog keys live in
    /// `Localizable.xcstrings` (de + en).
    var displayTitle: LocalizedStringKey {
        switch self {
        case .cycle: "Cycle tracking"
        case .mood: "Mood"
        case .sleep: "Sleep"
        case .glucose: "Blood glucose"
        case .workouts: "Workouts"
        case .recovery: "Recovery"
        case .labs: "Lab values"
        case .achievements: "Achievements"
        case .coach: "AI coach"
        case .insights: "Insights overview"
        case .doctorReport: "Doctor report"
        case .illness: "Illness journal"
        case .inboundDocuments: "Documents"
        case .nutrients: "Nutrients"
        case .medications: "Medications"
        case .environment: "Environment"
        case .mentalHealth: "Mental health"
        case .mcp: "MCP connector"
        }
    }

    /// Localized switchboard row subtitle — `nil` where the row title already
    /// carries the whole statement.
    ///
    /// **UI-Standard R2/R6 — die dritte der drei parallel gepflegten
    /// Erklärtabellen, und die einzige, die bleibt.** Neun Zeilen sind gefallen,
    /// weil sie ihren eigenen Titel umformulierten: „Zyklus-Tracking" →
    /// „Zykluskalender, Phasen und Vorhersagen.", „Stimmung" → „Tägliche
    /// Stimmungserfassung und Analyse.", „Schlaf" → „Schlafdauer und
    /// -qualität.", „Blutzucker" → „Blutzuckerwerte und Trends.", „Workouts",
    /// „Laborwerte", „Erfolge", „Krankheitstagebuch", „Medikamente".
    ///
    /// Stehen bleibt, was der Titel **nicht** sagt: eine Aufzählung, die den
    /// Umfang eingrenzt (Erholung, Mental Health), eine Herkunft (Nährstoffe,
    /// Umfeld), ein Ausgabeformat (Arztbericht), eine Voreinstellung, die
    /// zugleich eine Datenschutz-Zusage ist (Nährstoffe/MCP, Klasse D) oder
    /// eine Datenweitergabe-Aussage (Dokumente, MCP — Klasse D, unangetastet).
    var displaySubtitle: LocalizedStringKey? {
        switch self {
        case .cycle, .mood, .sleep, .glucose, .workouts, .labs, .achievements, .illness, .medications:
            nil
        case .recovery: "Strain, training load and autonomic charge."
        case .coach: "On-device and AI coaching."
        case .insights: "AI summaries and wellness scores."
        case .doctorReport: "PDF report and FHIR export for your doctor."
        // `illness` + `inboundDocuments` are DEFAULT-ON server-side (registry
        // v1.29.1, no `optIn` marker). The "Off by default" tail these two
        // carried until Build 2 / 2.6 was simply wrong. `nutrients` and `mcp`
        // are the genuinely opt-in ones (`optIn: true`).
        case .inboundDocuments: "Store doctor's letters, lab reports and scans — encrypted and searchable."
        case .nutrients: "Vitamins, minerals, water and caffeine from Apple Health. Off by default."
        case .environment: "Weather and daylight context for your readings."
        case .mentalHealth: "WHO-5, PHQ-9 and GAD-7 check-ins."
        case .mcp: "Let an external assistant read your record over the MCP endpoint. Off by default."
        }
    }
}
