import SwiftUI

/// **"Über mich" — the personal / static-self hub.**
///
/// One calm home for everything a user records *about themselves* as static
/// self-info: their profile basics (name + email), their **Körperdaten**
/// (height, biological sex, date of birth / age and — read-only, if already
/// loaded — the latest weight), the two static self-medical-history modules
/// (allergies + family history) and the health insurer.
///
/// **What the hub does NOT hold (v1.26.1 W-ABOUT-ME-RECONCILE).** The
/// condition/complaint journal (Beschwerden-Tagebuch) briefly lived here after
/// b220, but the operator clarified it is an ongoing symptom LOG, not static
/// self-info — so its front door moved back to the Mehr → Health & care section
/// next to Labs. `IllnessJournalScreen` + its `.illness` module gate are
/// unchanged; only the entry point left the hub. Allergies + family history STAY
/// (those ARE static self-medical info).
///
/// **This screen does NOT rebuild those modules.** It re-parents their entry
/// points: each history row is a `NavigationLink` into the unchanged
/// `AllergiesListScreen` / `FamilyHistoryListScreen`, pushed onto the same Mehr
/// `NavigationStack` this hub lives on. The row metadata (icon + localized
/// title/subtitle + `more.row.*` accessibility id) is reused verbatim from
/// `MoreScreen.Layout`, so any existing UI-test selector for e.g.
/// `more.row.allergies` still resolves (one navigation hop deeper).
///
/// **Server-first (no local PHI).** The profile header, the Körperdaten and the
/// Krankenkasse row are read straight from the app-wide `SettingsStore.profile`
/// (`GET /api/user/profile`) — no new fetch, no local persistence. The latest
/// weight is a *measurement*, not a profile field, so it is surfaced read-only
/// only when the app-wide `DashboardStore` already holds it (no extra fetch);
/// it is honestly absent otherwise. Editing the profile-backed attributes
/// (height / sex / DOB, name / insurer) stays where it already is — the "In
/// Profil bearbeiten" row presents the existing `EditProfileSheet`; this hub
/// never duplicates the edit UI.
struct AboutMeScreen: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SyncModeStore.self) private var syncMode
    /// 25-02 (E-2026-08-29 #1) — backs the relocated glucose-targets card.
    @Environment(DiabetesStore.self) private var diabetes
    /// v1.26.1 — read the app-wide dashboard state so the latest weight can be
    /// shown read-only WITHOUT a second fetch. Populated when the Home tab has
    /// resolved its metric states; absent (→ no weight row) otherwise.
    @Environment(DashboardStore.self) private var dashboardStore

    /// Presents the canonical profile editor (`EditProfileSheet`) so the
    /// read-only Körperdaten route to the ONE existing edit surface instead of
    /// duplicating any field UI here.
    @State private var showEditProfile = false

    /// 25-02 — in-flight latch for the diabetes toggle's optimistic PATCH.
    @State private var diabetesInFlight = false

    /// The re-parented static self-medical-history entry points the hub groups,
    /// in render order (Allergien → Familienanamnese). Reuses the canonical
    /// `MoreScreen.Layout` descriptors so icons + localized copy + accessibility
    /// ids stay single-sourced; the hub-presence test asserts on this list.
    ///
    /// v1.26.1 W-ABOUT-ME-RECONCILE — the condition journal was REMOVED from
    /// this list (it is an ongoing symptom log, not static self-info) and
    /// restored to the Mehr → Health & care section.
    static var hostedHistoryRows: [MoreScreen.Layout.Row] {
        [
            MoreScreen.Layout.allergiesRow,
            MoreScreen.Layout.familyHistoryRow
        ]
    }

    private var profile: UserProfile? {
        settingsStore.profile
    }

    /// Best-available display label: the chosen display name, else the full
    /// legal name, else nothing (the row then shows the empty placeholder).
    private var displayName: String? {
        profile?.displayName?.nonBlank ?? profile?.fullName?.nonBlank
    }

    var body: some View {
        HLSettingsPage(title: "aboutMe.title") {
            profileCard
            bodyDataCard
            historyCard
            anamnesisCard
            glucoseTargetsCard
            insuranceCard
        }
        .navigationTitle("aboutMe.title")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("aboutMe.screen")
        // The editable attributes route to the ONE existing profile editor —
        // presented as a sheet exactly like every other edit surface.
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet()
        }
        .task {
            // Reuse the existing app-wide profile fetch — never a second one.
            // Standalone installs have no server profile (the call would 401,
            // which the 401-bridge reads as logout), so gate it exactly like
            // `SettingsScreen`.
            if !syncMode.isStandalone, settingsStore.profile == nil {
                await settingsStore.load()
            }
            // 25-02 — the relocated diabetes flag, TTL-guarded by the store
            // (the same call the old Datenschutz-und-Sicherheit host made).
            await diabetes.refresh()
        }
    }

    // MARK: - Profile

    /// **UI-Standard R4/R7 — die Fußnote ist ersatzlos gefallen.**
    /// Sie lautete „Name und E-Mail änderst du in den Einstellungen unter
    /// Profil." und war gleich doppelt falsch: der Weg ist drei Sprünge lang
    /// (Einstellungen → Konto → Karte „Profil" → Zeile → Sheet), und eine
    /// **E-Mail-Änderung gibt es in der App überhaupt nicht** (`EditProfileScreen`
    /// reicht `email` nur an den Avatar durch; `changeEmail`/`updateEmail`/
    /// `newEmail` finden nichts). R4: ein Wegweiser zu etwas, das es nicht gibt,
    /// wird gestrichen, nicht verlinkt — und für den Namen existiert der
    /// Absprung („In Profil bearbeiten") bereits auf diesem Bildschirm.
    private var profileCard: some View {
        HLSettingsCard(
            icon: "person.crop.circle.fill",
            title: "aboutMe.profile.title"
        ) {
            infoRow(icon: "person.fill", label: "aboutMe.profile.name", value: displayName)
            infoRow(icon: "envelope.fill", label: "aboutMe.profile.email", value: profile?.email?.nonBlank)
        }
    }

    // MARK: - Körperdaten (static body attributes)

    /// The static body attributes the operator asked to surface here — height,
    /// biological sex, date of birth (+ derived age) and, read-only, the latest
    /// weight if the dashboard already holds it. All but weight are profile
    /// fields; the "In Profil bearbeiten" row routes the editable ones to the
    /// existing `EditProfileSheet` (no duplicated edit UI, server-first).
    ///
    /// **UI-Standard R4/R2 — was aus der Fußnote wurde.** Ihr erster Satz war
    /// derselbe Wegweiser wie auf der Profil-Karte und ist gefallen; die Zeile
    /// „In Profil bearbeiten" darunter *ist* der Absprung. Ihr zweiter Satz
    /// bleibt als einzige Aussage der Fußnote stehen: „Das Gewicht kommt aus
    /// deinen Messwerten." ist eine **Herkunfts**-Angabe (R2) und beantwortet
    /// genau die Frage, die der Editor sonst aufwirft — dort gibt es kein
    /// Gewichtsfeld, weil das Gewicht eine Messung ist und kein Profilwert.
    private var bodyDataCard: some View {
        HLSettingsCard(
            icon: "figure.stand",
            title: "aboutMe.body.title",
            footer: "aboutMe.body.footer"
        ) {
            infoRow(icon: "ruler.fill", label: "aboutMe.body.height", value: heightDisplay)
            infoRow(icon: "person.fill.questionmark", label: "aboutMe.body.sex", value: sexDisplay)
            infoRow(icon: "calendar", label: "aboutMe.body.dateOfBirth", value: dateOfBirthDisplay)
            infoRow(icon: "birthday.cake.fill", label: "aboutMe.body.age", value: ageDisplay)
            // Latest weight is a measurement, not a profile field — shown only
            // when the app-wide dashboard already resolved it (no extra fetch).
            if let weight = latestWeightDisplay {
                infoRow(icon: "scalemass.fill", label: "aboutMe.body.weight", value: weight)
            }
            editInProfileRow
        }
    }

    /// Height in cm from the profile, formatted "%lld cm". Nil → empty
    /// placeholder. Height is not unit-converted anywhere in the app (the
    /// editor stores/edits it in cm), so no `UnitPreferences` conversion here.
    private var heightDisplay: String? {
        guard let cm = profile?.heightCm else { return nil }
        return String(format: String(localized: "aboutMe.body.heightValue"), cm)
    }

    /// Biological sex label (male / female / other). A nil / unspecified server
    /// value collapses to the empty placeholder rather than "Prefer not to say".
    private var sexDisplay: String? {
        switch GenderOption(serverValue: profile?.gender) {
        case .male: String(localized: "Male")
        case .female: String(localized: "Female")
        case .other: String(localized: "Other")
        case .unspecified: nil
        }
    }

    /// Date of birth rendered through the app-wide date-format preference.
    private var dateOfBirthDisplay: String? {
        guard let dob = profile?.dateOfBirth else { return nil }
        return HLDateFormat.date(dob, style: .long)
    }

    /// Whole-year age derived from the date of birth. Nil when DOB is unset or
    /// (defensively) in the future.
    private var ageDisplay: String? {
        guard let dob = profile?.dateOfBirth else { return nil }
        let years = Calendar.current.dateComponents([.year], from: dob, to: .now).year ?? -1
        guard years >= 0 else { return nil }
        return String(format: String(localized: "aboutMe.body.ageValue"), years)
    }

    /// The most recent weight reading — read straight from the app-wide
    /// `DashboardStore` unified metric state (no new fetch). Formatted through
    /// the shared `MetricValueFormatter` so the value + unit honour the user's
    /// weight-unit preference exactly like every other surface. Nil when the
    /// dashboard hasn't resolved a weight value yet.
    private var latestWeightDisplay: String? {
        guard let measurement = dashboardStore.metricStates[.weight]?.latestMeasurement else { return nil }
        let units = settingsStore.unitPreferences
        let value = MetricValueFormatter.formattedValue(measurement, units: units)
        let suffix = MetricValueFormatter.unitSuffix(for: .weight, units: units)
        return "\(value) \(suffix)"
    }

    /// Routes the read-only body attributes to the ONE existing profile editor.
    ///
    /// **UI-Standard R8/R10** — war eine handgebaute Chevron-Zeile, obwohl
    /// dahinter ein *Sheet* aufgeht. `presents: .sheet` malt jetzt das
    /// `pencil`-Glyph: die Zeile verspricht damit genau das, was sie tut.
    private var editInProfileRow: some View {
        HLSettingsActionRow(
            icon: "square.and.pencil",
            title: "aboutMe.body.editInProfile",
            presents: .sheet
        ) {
            showEditProfile = true
        }
        .accessibilityIdentifier("aboutMe.body.editInProfile")
    }

    // MARK: - Static medical history (re-parented modules)

    /// **UI-Standard R2 (Tautologie)** — der Karten-Untertitel „Allergien und
    /// Familienanamnese." stand über genau den zwei Zeilen, die „Allergien" und
    /// „Familienanamnese" heißen. Reines Inhaltsverzeichnis, ersatzlos gefallen.
    private var historyCard: some View {
        HLSettingsCard(
            icon: "heart.text.square.fill",
            title: "aboutMe.history.title"
        ) {
            // Allergies + family history carry no module gate (v1.25.0), so
            // every hosted row always renders.
            ForEach(Self.hostedHistoryRows, id: \.id) { row in
                historyRow(row)
            }
        }
    }

    /// **Warum diese Zeile (noch) handgebaut ist — R8-Restschuld, bewusst.**
    /// `HLSettingsActionRow` kennt keinen Untertitel-Slot; „Allergien" trägt
    /// mit „Stoffe und Reaktionen" aber einen, der nach R5 bleibt (er grenzt
    /// ein, statt den Titel umzuformulieren). Die Zeile auf das Primitive zu
    /// heben, hieße den Untertitel zu opfern — das wäre Kürzen um der Regel
    /// willen. Sie bleibt deshalb als einziger Eintrag dieser Datei in der
    /// `hl_no_handmade_chevron`-Ratsche stehen (3 → 1); auflösbar erst, wenn
    /// das Primitive einen Untertitel bekommt.
    private func historyRow(_ row: MoreScreen.Layout.Row) -> some View {
        NavigationLink {
            destination(for: row)
        } label: {
            HStack(spacing: HLSpace.md) {
                HLSettingsIconChip(symbol: row.icon, tint: HLAccent.userBrandTint)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(LocalizedStringKey(row.title))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                    // R5 — der Zeilen-Untertitel ist optional geworden:
                    // „Erkrankungen in der Familie" unter „Familienanamnese"
                    // war eine Umformulierung des Titels und ist gefallen,
                    // „Stoffe und Reaktionen" unter „Allergien" grenzt ein
                    // und bleibt.
                    if let subtitle = row.subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: HLSpace.sm)
                HLDisclosureChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    /// Maps a re-parented row descriptor to its unchanged destination screen.
    /// The screens are self-contained (no arguments, they read the
    /// `appContainer` from the environment the Mehr stack already provides).
    @ViewBuilder
    private func destination(for row: MoreScreen.Layout.Row) -> some View {
        switch row.id {
        case MoreScreen.Layout.allergiesRow.id:
            AllergiesListScreen()
        case MoreScreen.Layout.familyHistoryRow.id:
            FamilyHistoryListScreen()
        default:
            // Unreachable — `hostedHistoryRows` is the closed set above.
            EmptyView()
        }
    }

    // MARK: - Anamnese (CU-32)

    /// Front door to the effective-dated anamnesis facts (smoking / alcohol /
    /// shift work). It sits in this hub — next to allergies and family history
    /// — because those ARE the same class of static self-medical info, and
    /// because the three-hop route through Settings → Assistant → Coach would
    /// have buried it. The screen owns its own store; this card only pushes.
    ///
    /// **UI-Standard R2/R8** — der Karten-Untertitel zählte „Rauchen, Alkohol
    /// und Schichtarbeit" auf, direkt über der einzigen Zeile der Karte, die
    /// wortgleich „Rauchen, Alkohol, Schichtarbeit" heißt. Die tippbare Zeile
    /// ist die Heimat der Aussage (R3), der Untertitel ist gefallen; die Zeile
    /// selbst ist jetzt die kanonische `HLSettingsActionRow(presents: .push)`
    /// statt einer handgebauten Chevron-Zeile.
    private var anamnesisCard: some View {
        HLSettingsCard(
            icon: "list.clipboard.fill",
            title: "anamnesis.title"
        ) {
            HLSettingsActionRow(
                icon: "smoke.fill",
                title: "anamnesis.aboutMe.subtitle",
                presents: .push
            ) {
                SettingsAnamnesisScreen()
            }
            .accessibilityIdentifier("aboutMe.row.anamnesis")
        }
    }

    // MARK: - Glukose-Zielwerte (25-02, E-2026-08-29 #1)

    /// **The glucose-targets card, moved here from Einstellungen →
    /// Datenschutz und Sicherheit**, where it had no business. „Ich habe
    /// Diabetes" is a static self-medical fact — this hub's exact subject,
    /// beside anamnesis, allergies and family history — and its one effect is
    /// which glucose reference bands the SERVER resolves (the tighter ADA
    /// goals when on; v1.18.6). iOS only surfaces the switch; the bands are
    /// applied server-side, never recomputed here. Same catalogue keys, same
    /// `DiabetesStore`, same optimistic-write semantics as before the move.
    private var glucoseTargetsCard: some View {
        let enabled = diabetes.hasDiabetes ?? false
        return HLSettingsCard(
            icon: "drop.fill",
            title: "settings.diabetes.title"
        ) {
            HLSettingsToggleRow(
                title: "settings.diabetes.toggle_label",
                description: "settings.diabetes.toggle_caption",
                isOn: Binding(
                    get: { enabled },
                    set: { newValue in onDiabetesToggle(newValue, current: enabled) }
                ),
                isBusy: diabetesInFlight,
                isEnabled: !diabetesInFlight && diabetes.hasDiabetes != nil,
                accessibilityID: "aboutMe.diabetesToggle"
            )
        }
    }

    private func onDiabetesToggle(_ newValue: Bool, current: Bool) {
        guard newValue != current else { return }
        Task {
            diabetesInFlight = true
            defer { diabetesInFlight = false }
            await diabetes.setHasDiabetes(newValue)
        }
    }

    // MARK: - Insurance

    /// **UI-Standard R4** — „Deine Krankenkasse pflegst du in den Einstellungen
    /// unter Profil." ist gefallen. Der Absprung dorthin existiert bereits auf
    /// diesem Bildschirm (Zeile „In Profil bearbeiten" in der Körperdaten-Karte);
    /// R4 verlangt an dieser Stelle deshalb ausdrücklich **nichts**.
    private var insuranceCard: some View {
        HLSettingsCard(
            icon: "cross.case.fill",
            title: "aboutMe.insurance.title"
        ) {
            // Krankenkasse — a REAL server-backed field (`insurerName` on
            // `GET/PATCH /api/user/profile`), so it is surfaced truthfully
            // read-only, never a fake placeholder. Reuses the "Health insurer"
            // key that already renders as "Krankenkasse" (de).
            infoRow(icon: "building.2.fill", label: "Health insurer", value: profile?.insurerName?.nonBlank)
        }
    }

    // MARK: - Shared read-only row

    /// A read-only "label → value" row. A missing value collapses to the
    /// localized "Nicht hinterlegt" placeholder in tertiary text.
    private func infoRow(icon: String, label: LocalizedStringKey, value: String?) -> some View {
        HStack(spacing: HLSpace.md) {
            HLSettingsIconChip(symbol: icon, tint: HLAccent.userBrandTint)
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.sm)
            Text(value ?? String(localized: "aboutMe.value.empty"))
                .font(.hlBody)
                .foregroundStyle(value == nil ? HLText.tertiary : HLText.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    /// Trimmed self, or `nil` when the trimmed string is empty — so a
    /// whitespace-only server value collapses to the empty placeholder.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
