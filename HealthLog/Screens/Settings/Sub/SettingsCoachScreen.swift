import SwiftUI

/// **v0.5.7 G.5 / SET-V2-C (B.3)** — THE consolidated Coach page.
///
/// Lives at `/settings/ai/coach` semantically. Pre-SET-V2-C the Coach was
/// fragmented across four surfaces (audit AUDIT-SETTINGS-V2 B.3): the
/// Mini-Coach toggle + kill-switch caption and the About-me link sat inline
/// on `SettingsAIScreen`, while this screen only hosted three thin cards
/// (hero-restore, memory link, history-clear) — making Settings → Assistant
/// → Coach → "What the assistant knows" the deepest chain in the app
/// (4 hops). Everything Coach-related now lives under this one roof
/// (max 3 hops):
///
/// 1. **Coach toggle** (moved from `SettingsAIScreen`) — gating semantics
///    preserved: shown only while the resolved AI mode is `.onDevice`;
///    hidden entirely + replaced by the kill-switch caption when the
///    server-side `assistant.coach` flag is off (operator-control
///    philosophy, F-1 surface-disabled pattern).
/// 2. **About me** (moved from `SettingsAIScreen`) — server-backed
///    `/api/coach/about-me` editor, gated on `backend.hasServer` exactly
///    as before.
/// 3. **Hero-restore** (COACH-COIN v0.5.5.7) — unchanged.
/// 4. **Memory** → `CoachMemoryScreen` (FW5-C) — unchanged.
/// 5. **History-clear** (destructive) — unchanged.
///
/// **Confirmation:** destructive operations on chat transcripts get an explicit
/// "Löschen" + "Abbrechen" confirmation, no automatic undo affordance. What the
/// wipe reaches is the transcript **on this iPhone** — server-held conversations
/// are a separate surface with its own delete (see ``historyCard``), and the
/// confirmation copy says so.
struct SettingsCoachScreen: View {
    @Environment(\.appContainer) private var appContainer
    /// COACH-COIN (v0.5.5.7) — drives the "Hero-Karte wiederherstellen" row.
    @Environment(SettingsStore.self) private var settingsStore
    /// SET-V2-C — server kill-switch gate for the toggle card (moved here
    /// together with the toggle from `SettingsAIScreen`).
    @Environment(FeatureFlagsStore.self) private var featureFlags
    /// SET-V2-C — gates the About-me card (server-backed editor).
    @Environment(BackendAvailability.self) private var backend

    /// v0.5.3 C6 — operator-control toggle for the Mini-Coach UI surface
    /// (moved from `SettingsAIScreen` in SET-V2-C). Default OFF until the
    /// C6 walkthrough is green; the toggle pushes onboarding-acknowledge
    /// before flipping ON (the sheet handles the onboarding mid-flight,
    /// this row just kicks it off).
    @AppStorage(MiniCoachDefaultsKeys.enabled)
    private var miniCoachEnabled: Bool = false

    @State private var presentMiniCoachOnboarding = false

    /// Confirmation-alert visibility. Flipped `true` by the "Verlauf
    /// löschen" row, `false` by either of the alert actions.
    @State private var showDeleteConfirmation = false

    var body: some View {
        // SET-V2-C — same Observation anchor as `SettingsAIScreen` (Bug 3,
        // RCA v0.14.8): `aiMode` is computed from UserDefaults + Keychain
        // (neither tracked by Observation), so the toggle-card gate below
        // needs `AIConsentStore.revision` as its tracked dependency to
        // re-evaluate on mode/consent changes.
        // swiftlint:disable:next redundant_discardable_let
        let _ = appContainer?.aiConsentStore.revision
        HLSettingsPage(title: "Coach") {
            if isOnDeviceMode {
                if featureFlags.isEnabled(.assistantCoach) {
                    coachToggleCard
                } else {
                    // Caption rendered when the server kill-switch is OFF —
                    // same copy + shape it had on `SettingsAIScreen`.
                    killSwitchCaption
                }
            }
            // Build 9 (9.2) — server-wide coach availability (Decision A / E-3).
            // In true server mode (not the on-device path) THE one server switch
            // "Coach aktiviert" = `!disableCoach`; hidden until the value resolves.
            if backend.hasServer, !isOnDeviceMode,
               let store = appContainer?.aiCoachSettingsStore, store.coachDisabled != nil
            {
                serverCoachToggleCard(store: store)
            }
            // #30 — proactive cadence-suggestions opt-in, now server-backed
            // (`reminderSuggestions.enabled`). Shown when the coach is reachable
            // (server present + flag on) and the value has resolved.
            if backend.hasServer, featureFlags.isEnabled(.assistantCoach),
               let store = appContainer?.aiCoachSettingsStore, store.reminderSuggestionsEnabled != nil
            {
                cadenceSuggestionsCard(store: store)
            }
            if backend.hasServer {
                aboutMeCard
            }
            // 6.6 — server-owned Coach/AI privacy flags. Both are server-first
            // settings, so the section shows only while a server is reachable;
            // the values hydrate via the `.task` below.
            if backend.hasServer, let store = appContainer?.aiCoachSettingsStore {
                CoachDocumentsAutoAICard(store: store)
                CoachInsightsPrivacyCard(store: store)
            }
            heroVisibilityCard
            memoryCard
            if backend.hasServer {
                conversationsCard
            }
            historyCard
        }
        .navigationTitle("Coach")
        .navigationBarTitleDisplayMode(.inline)
        // 6.6 — hydrate the Coach/AI privacy flags from the server on appear
        // (server-first). Skipped in standalone (no store to reach).
        .task {
            if backend.hasServer, let store = appContainer?.aiCoachSettingsStore {
                await store.load()
            }
        }
        .sheet(isPresented: $presentMiniCoachOnboarding) {
            if let store = appContainer?.miniCoachStore {
                MiniCoachOnboardingSheet(store: store) {
                    miniCoachEnabled = true
                }
                .hlSheetPresentation(.form)
            }
        }
        // R13 — `.alert` für eine destruktive Bestätigung ist verboten; die
        // Leiter nach Schwere sieht für „Einzelobjekt löschen" den
        // `confirmationDialog` vor.
        .hlConfirmDestructive(
            Text("Clear coach history?"),
            isPresented: $showDeleteConfirmation,
            // R19 — die Aussage lebt am Ort der Handlung und nennt ihren
            // Geltungsbereich: gelöscht wird die lokale Fassung, nicht die
            // serverseitig gehaltenen Unterhaltungen.
            message: Text(
                String(
                    localized: "This clears the transcript on this iPhone. Conversations kept on your server stay — delete them under “Past conversations”."
                )
            ),
            confirm: Text("Delete"),
            cancel: Text("Cancel"),
            onCancel: { showDeleteConfirmation = false },
            action: {
                appContainer?.coachConversationStore.reset()
            }
        )
    }

    /// SET-V2-C — the on-device gate the toggle had on `SettingsAIScreen`
    /// (`displayedMode == .onDevice`), replicated semantics: a pending
    /// "Own key" intent displays as `.byoKey` there, so it must suppress
    /// the toggle here too.
    private var isOnDeviceMode: Bool {
        guard let container = appContainer else { return false }
        if container.aiBYOKeyIntentPending { return false }
        return container.aiMode == .onDevice
    }

    /// SET-V2-C — the Mini-Coach on/off card (moved from `SettingsAIScreen`).
    ///
    /// R11 — war eine handgebaute Toggle-Zeile in derselben Datei, die daneben
    /// dreimal `HLSettingsToggleRow` benutzt. Jetzt überall dieselbe Geometrie.
    private var coachToggleCard: some View {
        HLSettingsCard(
            icon: "bubble.left.and.bubble.right",
            title: "Coach"
        ) {
            // R15 — der Pauschal-Schwanz („Kein medizinischer Rat.") ist eine
            // von fünf Coach-Varianten desselben Satzes; sie reduzieren sich
            // auf die aktive Bestätigungszeile im Coach-Onboarding. Der
            // informative Vorderteil trägt weiter: er sagt, welche Betriebsart
            // dieser Schalter einschaltet und dass sie ohne Cloud auskommt.
            HLSettingsToggleRow(
                title: "Enable coach",
                description: "On-device coach — explains your data without the cloud.",
                isOn: miniCoachBinding,
                accessibilityID: "settings.coach.enableToggle"
            )
        }
    }

    /// SET-V2-C — rendered instead of the toggle card when the server-side
    /// `assistant.coach` kill-switch is OFF (moved from `SettingsAIScreen`).
    private var killSwitchCaption: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "switch.2")
                .foregroundStyle(HLText.tertiary)
            Text(String(localized: "Coach is disabled by the operator."))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HLSpace.xs)
        .accessibilityIdentifier("settings.coach.killswitch")
    }

    /// SET-V2-C — server-parity v1.16 coach self-context editor
    /// (`/api/coach/about-me`), moved from `SettingsAIScreen`. Server-backed
    /// (works for every arm that can reach the server Coach), hence the
    /// `backend.hasServer` gate at the call-site.
    private var aboutMeCard: some View {
        HLSettingsCard(
            icon: "person.text.rectangle",
            title: "coachContext.title"
        ) {
            HLSettingsActionRow(title: "coachContext.open", presents: .push) {
                SettingsAboutMeScreen()
            }
            .accessibilityIdentifier("settings.coach.aboutMeRow")
        }
    }

    /// W-COACH-CADENCE (#30) — opt-in for the proactive cadence suggestions, with
    /// concrete copy (operator mandate: explain WHAT + HOW, plainly). The
    /// description states what cadence suggestions are (the coach noticing your
    /// logging rhythm and offering to set a reminder), that they're optional and
    /// you accept or dismiss each, and that no reminder is created without your
    /// tap. Uses the shared `HLSettingsToggleRow` so the row geometry matches every
    /// other settings toggle.
    private func cadenceSuggestionsCard(store: AICoachSettingsStore) -> some View {
        HLSettingsCard(
            icon: "bell.badge",
            title: "Cadence suggestions"
        ) {
            HLSettingsToggleRow(
                title: "Cadence suggestions",
                description: "settings.coach.cadenceSuggestions.description",
                isOn: Binding(
                    get: { store.reminderSuggestionsEnabled ?? true },
                    set: { newValue in Task { await store.setReminderSuggestionsEnabled(newValue) } }
                ),
                isBusy: store.isReminderWriteInFlight,
                isEnabled: store.reminderSuggestionsEnabled != nil && !store.isReminderWriteInFlight,
                accessibilityID: "settings.coach.cadenceSuggestionsToggle"
            )
        }
    }

    /// **Build 9 (9.2)** — the server-wide coach availability switch. UI semantics
    /// are inverted from the server flag: "Coach aktivieren" ON = `!disableCoach`.
    /// Flipping it PATCHes `disable-coach` and optimistically flips the `coach`
    /// module surface. Only rendered once `coachDisabled` has resolved from the
    /// server (guard 1 — never write the iOS-default up).
    private func serverCoachToggleCard(store: AICoachSettingsStore) -> some View {
        HLSettingsCard(
            icon: "bubble.left.and.bubble.right",
            title: "Coach"
        ) {
            HLSettingsToggleRow(
                title: "settings.coach.enable.title",
                description: "settings.coach.enable.description",
                isOn: Binding(
                    get: { !(store.coachDisabled ?? false) },
                    set: { newValue in Task { await store.setCoachDisabled(!newValue) } }
                ),
                isBusy: store.isCoachWriteInFlight,
                isEnabled: store.coachDisabled != nil && !store.isCoachWriteInFlight,
                accessibilityID: "settings.coach.serverEnableToggle"
            )
        }
    }

    /// COACH-COIN (v0.5.5.7) — reset affordance for the Hero-card dismiss
    /// flag. Disabled when the Hero is already visible (`dismissed == false`)
    /// so the row never looks tappable in a no-op state.
    private var heroVisibilityCard: some View {
        HLSettingsCard(
            icon: "sparkles",
            title: "Coach card",
            // R5 — eine Folge der Aktion gehört in den Footer, nicht in den
            // Subtitle („was die Karte ist").
            footer: "The hero card reappears on Insights."
        ) {
            HLSettingsActionRow(
                icon: "arrow.uturn.backward.circle",
                title: "Restore hero card",
                labelTintOverride: settingsStore.coachHeroDismissed ? HLText.primary : HLText.tertiary,
                presents: .confirm
            ) {
                settingsStore.coachHeroDismissed = false
            }
            .disabled(!settingsStore.coachHeroDismissed)
            .accessibilityIdentifier("settings.coach.restoreHeroRow")
        }
    }

    /// v0.14.2 (FW5-C) — entry point to the server-backed coach memory surface.
    /// Lists the facts the assistant has extracted about the user, with
    /// swipe-to-forget + "Forget everything". Server-only; the sub-screen degrades
    /// to the calm placeholder in standalone or when the Coach surface is disabled.
    private var memoryCard: some View {
        HLSettingsCard(
            icon: "brain.head.profile",
            title: "What the assistant knows"
        ) {
            HLSettingsActionRow(title: "Open coach memory", presents: .push) {
                CoachMemoryScreen()
            }
            .accessibilityIdentifier("settings.coach.memoryRow")
        }
    }

    /// b182 (AUDIT-COACH-PARITY §B) — entry point to the server-backed
    /// conversation-history surface. Lists the conversations the server retains and
    /// re-hydrates a selected one's full turns, so the coach's continuity is
    /// visible across launches / devices (matching web). Server-only; the
    /// sub-screen degrades to the calm placeholder in standalone or when the Coach
    /// surface is disabled. Distinct from the destructive local "Clear history"
    /// below (which wipes the on-device transcript only).
    private var conversationsCard: some View {
        HLSettingsCard(
            icon: "clock.arrow.circlepath",
            title: "Past conversations",
            subtitle: "Stored on your server by the server coach."
        ) {
            HLSettingsActionRow(title: "Open past conversations", presents: .push) {
                CoachConversationsScreen()
            }
            .accessibilityIdentifier("settings.coach.conversationsRow")
        }
    }

    /// **UI-Standard R7 / §0 „Präzision vor Kürze" — privacy-review.**
    ///
    /// Die frühere Zusage („bleiben auf diesem iPhone und werden nicht in die
    /// Cloud übertragen") stand unqualifiziert direkt unter der Karte „Frühere
    /// Unterhaltungen", die das Gegenteil versprach. Beide Sätze waren für sich
    /// genommen wahr — aber für **verschiedene Betriebsarten**, und keiner sagte,
    /// für welche. Der am Code verifizierte Sachverhalt:
    ///
    /// - **Geräteinterner Coach** (`CoachConversationStore.runOnDeviceTurn`,
    ///   FoundationModels): kein Netzverkehr, der Verlauf existiert nur als
    ///   SwiftData-Zeilen auf diesem iPhone (`CoachChatStore`).
    /// - **Eigener Schlüssel** (`runBYOTurn` → `BYOLLMService`): die Anfrage geht
    ///   direkt an den Anbieter des Nutzers, aber **kein** HealthLog-Server
    ///   speichert die Unterhaltung — der Verlauf bleibt lokal.
    /// - **Server-Coach** (`runServerTurn` → `POST /api/insights/chat`): der
    ///   Server hält die Unterhaltung (samt `conversationId` und rollierender
    ///   Zusammenfassung); `CoachConversationHistoryRepository` liest und löscht
    ///   sie geräteübergreifend.
    ///
    /// `persistMessage` schreibt in **allen** Betriebsarten zusätzlich die lokale
    /// Zeile — deshalb löscht „Verlauf löschen" (`reset()` →
    /// `persistence.clear(userID:)`) ausschließlich die Fassung auf diesem
    /// iPhone. Der Bestätigungsdialog sagt das jetzt am Ort der Handlung (R19).
    private var historyCard: some View {
        HLSettingsCard(
            icon: "bubble.left.and.bubble.right.fill",
            title: "History",
            footer: "With the server coach your conversations are also kept on your server. With the on-device coach (Apple Intelligence) and with your own key they stay on this iPhone only."
        ) {
            HLSettingsActionRow(
                icon: "trash",
                title: "Clear history",
                role: .destructive,
                presents: .confirm
            ) {
                showDeleteConfirmation = true
            }
            .accessibilityIdentifier("settings.coach.clearHistoryRow")
        }
    }

    /// Binding that intercepts ON-transitions when onboarding hasn't been
    /// acknowledged yet — presents the onboarding sheet first and only
    /// flips the persisted state after the user taps "Aktivieren".
    /// (Moved verbatim from `SettingsAIScreen` in SET-V2-C.)
    private var miniCoachBinding: Binding<Bool> {
        Binding(
            get: { miniCoachEnabled },
            set: { newValue in
                if newValue {
                    if let store = appContainer?.miniCoachStore, !store.isOnboarded {
                        presentMiniCoachOnboarding = true
                    } else {
                        miniCoachEnabled = true
                    }
                } else {
                    miniCoachEnabled = false
                }
            }
        )
    }
}

// MARK: - 6.6 Coach/AI privacy cards

/// The "read documents with AI" auto-switch (`documentsAutoAiRead`). Operator
/// decision: documents-AI is auto-only — this toggle IS the control, there is no
/// separate "read with AI" button. Turning it ON is the standing consent act
/// (the server mints the consent receipt). Optimistic; the store reverts on a
/// server rejection.
private struct CoachDocumentsAutoAICard: View {
    let store: AICoachSettingsStore

    var body: some View {
        HLSettingsCard(
            icon: "doc.text.magnifyingglass",
            title: "settings.coach.docsAutoAi.title"
        ) {
            HLSettingsToggleRow(
                title: "settings.coach.docsAutoAi.toggle",
                description: "settings.coach.docsAutoAi.description",
                isOn: Binding(
                    get: { store.documentsAutoAiRead },
                    set: { newValue in Task { await store.setDocumentsAutoAiRead(newValue) } }
                ),
                isBusy: store.isDocumentsWriteInFlight,
                isEnabled: store.didLoad && !store.isDocumentsWriteInFlight,
                accessibilityID: "settings.coach.docsAutoAiToggle"
            )
        }
    }
}

/// The Insights data-detail privacy picker (`insightsPrivacyMode`). `aggregated`
/// (default) hands only summarised data to the Insights AI; `raw` additionally
/// hands raw data points (server `includeRaw`). Monochrome menu picker matching
/// the Appearance / Layout rows.
private struct CoachInsightsPrivacyCard: View {
    let store: AICoachSettingsStore

    var body: some View {
        HLSettingsCard(
            icon: "lock.doc",
            title: "settings.coach.insightsPrivacy.title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.md) {
                    Text("settings.coach.insightsPrivacy.pickerLabel")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.isInsightsWriteInFlight {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                    Picker(
                        String(localized: "settings.coach.insightsPrivacy.pickerLabel"),
                        selection: Binding(
                            get: { store.insightsPrivacyMode },
                            set: { newValue in Task { await store.setInsightsPrivacyMode(newValue) } }
                        )
                    ) {
                        ForEach(InsightsPrivacyMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.labelKey)).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(!store.didLoad || store.isInsightsWriteInFlight)
                    .accessibilityIdentifier("settings.coach.insightsPrivacyPicker")
                }
                Text("settings.coach.insightsPrivacy.description")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("SettingsCoachScreen") {
    NavigationStack {
        SettingsCoachScreen()
    }
}
