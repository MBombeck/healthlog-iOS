import SwiftUI

/// `/settings/ai` — KI & Insights. Mirrors `ai-section.tsx`.
///
/// **UI-Standard R12 — die größte Einzelabweichung ist aufgelöst.**
/// Dieser Screen war der einzige Einstellungs-Screen ohne Kartenhülle auf
/// oberster Ebene: ein `ScrollView { VStack(spacing: 0) }`, dessen
/// Blockstruktur nur dadurch entstand, dass die Seitenränder pro Block dreimal
/// von Hand wiederholt wurden. Er trug als einziger in den Einstellungen
/// versale Mikro-Überschriften statt Kartentitel, und
/// er bettete mit `AIProviderScreen` einen kompletten anderen Screen **samt
/// eigenem Scrollbereich** mitten auf der Seite ein — die Formensprache
/// wechselte im Scrollen.
///
/// Jetzt: ein `HLPage`, ein Scrollbereich, ein Kartenrhythmus. Die
/// Abschnittsmarken sind Kartentitel, die Ränder kommen ausschließlich
/// vom Primitive, und der Provider-Teil ist zu einer Karten-Sektion
/// (``AIProviderSection``) geworden, die das Gerüst des Hosts benutzt statt ein
/// zweites mitzubringen.
struct SettingsAIScreen: View {
    @Environment(\.appContainer) private var appContainer
    /// Re-probe on-device availability on foreground so a disabled
    /// On-device card unlocks live after the user toggles Apple Intelligence.
    @Environment(\.scenePhase) private var scenePhase
    /// Recovery deep-link for the disabled On-device card.
    @Environment(\.openURL) private var openURL
    /// The inline "Own key" entry model, built lazily on first reveal
    /// so the drafts persist across body re-evaluations while the card is open.
    @State private var byoKeyEntryModel: BYOKeyEntryModel?

    /// b182 (AUDIT-COACH-PARITY F2 / RCA-ai-consent-flow Commit C) — one-shot
    /// guard so the onboarding online-intent carry-through fires the consent sheet
    /// AT MOST once per Settings → Assistant visit (never a re-prompt loop).
    @State private var didCarryThroughOnlineIntent = false

    /// Erfolgs-Tick für Pull-to-Refresh — vom früher eingebetteten
    /// Provider-Screen hierher gewandert (R12: das `refreshable` sitzt jetzt am
    /// Scrollbereich dieser Seite).
    @State private var refreshTick: Int = 0

    /// The Coach's thinking depth, read once per visit. `nil`
    /// until the read lands; a server without `coachReasoning` shows nothing.
    @State private var reasoning: CoachReasoningSettingsModel?

    var body: some View {
        // Bug 3 — anchor the body to `AIConsentStore.revision` so
        // it re-renders on every mode/consent change. `displayedMode` reads
        // `aiMode`, which is *computed* from UserDefaults + Keychain (neither
        // tracked by Observation) — so without this the picker did not visibly
        // move to None after tapping "No assistant" (the grant was revoked, but
        // the body never re-evaluated). `revision` is the @Observable-tracked
        // dependency anchor every mode-input mutator bumps. Mirrors the Coach
        // surface pattern (`AIConsentStore.revision` doc-comment).
        // swiftlint:disable:next redundant_discardable_let
        let _ = appContainer?.aiConsentStore.revision
        // EIN Gerüst, EIN Scrollbereich. Der frühere handgebaute
        // `ScrollView { VStack(spacing: 0) }` mit dreimal von Hand wiederholten
        // Seitenrändern und einem zweiten, eingebetteten Scrollbereich ist
        // ersatzlos gefallen; Ränder, Rhythmus und Canvas kommen jetzt aus
        // `HLPage`. Die Y9.2-E2- und Bug-6-Reparaturen von 2026-05-23
        // waren Kompensationen genau dieser Verschachtelung und sind mit ihr
        // hinfällig.
        HLPage {
            sourceCard

            // Reveal the inline "Own key" (BYO) entry card when the
            // user picked it (resolved `.byoKey` OR a pending intent). Works in
            // BOTH operating modes — BYO is client-side, so it never needs a
            // server. Eigene Karte statt eingeschobener Block: sie ist eine
            // Folge der Auswahl darüber, kein Teil des Auswahl-Bedienelements.
            if displayedMode == .byoKey, let model = byoKeyEntryModel {
                BYOKeyEntryCard(model: model)
            }

            // v0.17 settings-hygiene — the "On-device intelligence" section
            // that housed the "Daily briefing" + "On-device trend hints"
            // operator toggles was removed. Both were dead: the briefing
            // key had no production render-gate reader (Insights reads its
            // own gate), and the trend-hints key was a no-op (the live gate
            // reads the server flag map, never this UserDefaults key). With
            // both toggles gone the section header stood empty, so the whole
            // block was dropped. On-device generation stays gated by the
            // server `assistant.*` flags + the mode picker above.

            coachCard

            // Rare, so it waits under „Erweitert".
            if let reasoning, reasoning.state != nil {
                CoachReasoningAdvanced(model: reasoning)
            }

            if let usage = appContainer?.aiCapabilityGate.account?.usage {
                AIUsageCard(usage: usage) { level in try await AIUsageCard.choose(level, in: appContainer) }
            }

            AIProviderSection()
        }
        // Pull-to-Refresh gehört an den Scrollbereich, und den besitzt
        // jetzt diese Seite. Vorher hing es am eingebetteten Provider-Screen
        // und aktualisierte nur dessen Ausschnitt.
        .refreshable {
            guard let store = appContainer?.aiProviderStore else { return }
            await store.load()
            refreshTick &+= 1
        }
        // Success-tick confirms pull-to-refresh round-trip.
        .sensoryFeedback(.success, trigger: refreshTick)
        .task {
            guard reasoning == nil, let container = appContainer else { return }
            let model = CoachReasoningSettingsModel(repo: AICoachSettingsRepository(api: container.api))
            await model.load()
            reasoning = model
        }
        .onAppear {
            // If the screen opens already in "Own key" mode (prior
            // grant or pending intent), build the entry model so the card shows
            // its configured/entry state without requiring a re-pick.
            if displayedMode == .byoKey { ensureBYOKeyEntryModel() }
            // b182 (F2 / RCA Commit C) — carry the onboarding online-intent through
            // to a real grant, in context.
            carryThroughOnlineIntentIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-probe on-device availability when returning from
            // System Settings so a disabled On-device card unlocks without a
            // relaunch (e.g. the user just enabled Apple Intelligence).
            if phase == .active { appContainer?.localLLMService.refresh() }
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cards

    /// The single, elegant AI-source choice. The user picks WHETHER
    /// + WHICH assistant — None / On-device / External AI / Own key (mode- +
    /// capability-gated) — in one place, mirroring the onboarding step exactly.
    /// `.none` hides every AI surface; `.onDevice` drives local generation;
    /// `.online` routes through the informed-consent sheet.
    ///
    /// Die Abschnittsmarke ist der Kartentitel.
    ///
    /// Der frühere „Dein Server stellt den KI-Anbieter bereit …"-Hinweis
    /// unter dem Picker ist gefallen: die Status-Karte der Provider-Sektion
    /// **auf derselben scrollenden Seite** sagt dasselbe, und zwar dort, wo das
    /// Bedienelement steht, das den Zustand ändert. Die Bug-4-Bedingung
    /// (niemals „nicht konfiguriert" behaupten, solange die Konfiguration erst
    /// lädt) lebt unverändert in ``AIProviderSection`` weiter.
    private var sourceCard: some View {
        HLCard("Assistant source") {
            AISourceChoicePicker(
                selection: displayedMode,
                options: offeredOptions,
                onSelect: { mode in handleModePick(mode) },
                onRecover: { recovery in handleRecover(recovery) }
            )
        }
    }

    /// SET-V2-C (B.3) — the single Coach entry point. Coach toggle (+ kill-switch
    /// caption) and the About-me link used to live inline on this screen,
    /// fragmenting the Coach across four surfaces (audit AUDIT-SETTINGS-V2 B.3);
    /// both moved onto the consolidated `SettingsCoachScreen`.
    ///
    /// R8/R10 — `HLSettingsRow` ist das Zuhause der Hub-Zeilen; innerhalb einer
    /// Karte ist eine Navigation eine `HLSettingsActionRow(presents: .push)`.
    /// Der Untertitel „Alles zum Coach an einem Ort." ist gefallen: er stand
    /// wortgleich noch einmal auf der Zielseite, einen Navigationsschritt später
    /// (R3), und sagte nichts, was der Titel nicht sagt.
    /// One row, one heading: "Coach" with its chevron.
    private var coachCard: some View {
        HLCard(layout: .rows) {
            HLSettingsActionRow(title: "Coach", presents: .push) {
                SettingsCoachScreen()
            }
            .accessibilityIdentifier("SettingsAIScreen.coach.row")
        }
    }

    /// The mode the picker should DISPLAY. Normally the resolved
    /// ``AppContainer/aiMode``; but when the user picked `.online` without a
    /// configured provider, `aiMode` legitimately stays `.none` (no grant could
    /// land) — so we surface the persisted pending intent instead, keeping the
    /// picker on Online + the add-provider hint visible across navigation rather
    /// than snapping silently back to None.
    private var displayedMode: AIMode {
        let resolved = appContainer?.aiMode ?? .none
        // A pending "Own key" intent keeps the picker on byoKey + the
        // inline entry card revealed until a grant lands (mirrors the online
        // intent). Checked first: a user mid-key-entry hasn't granted yet, so
        // `aiMode` is still on the prior arm.
        if appContainer?.aiBYOKeyIntentPending == true {
            return .byoKey
        }
        if resolved == .none, appContainer?.aiOnlineIntentPending == true {
            return .online
        }
        return resolved
    }

    /// Apply a three-way `AIMode` pick. `.none` / `.onDevice` persist
    /// immediately (no off-device traffic); `.online` routes through the
    /// informed-consent sheet (`AIConsentSheet`, Apple 5.1.2(i)) for the
    /// resolved provider via `AppContainer.setAIMode`. When `.online` is
    /// picked without a configured provider the choice is persisted as a pending
    /// intent (`AIConsentStore.onlineIntentDefaultsKey`) so ``displayedMode``
    /// keeps the picker on Online and the inline hint + embedded
    /// `AIProviderScreen` below surface the add-provider path — never an empty
    /// box, never a silent revert. The intent feeds only the picker/hint; the
    /// per-provider consent grant stays the source of truth for the app-wide
    /// AI gates.
    private func handleModePick(_ mode: AIMode) {
        appContainer?.setAIMode(mode)
        // Build the BYO entry model on first pick so the card has a
        // stable model to bind to (drafts survive re-renders while open).
        if mode == .byoKey {
            ensureBYOKeyEntryModel()
        }
        // RCA-coach-ai — close the SERVER-MANAGED dead pick. For the
        // admin/server-managed external-AI case (`managedBy:"server"`, per-user
        // `provider:null`) `setAIMode(.online)` resolves `activeProvider ==
        // .unconfigured`, so `setMode(.online, …)` falls to the intent-only
        // branch — no consent sheet, `aiMode` stays `.none`, and the Coach
        // surfaces stay hidden (the operator's "External AI selected but Coach
        // nowhere"). The shell already knows how to present + grant the
        // server-managed consent (`presentExplicitConsentIfNeeded` →
        // `grantServerManaged()` + `recordAcceptedAIConsent()`); it just was
        // never asked. Asking it here makes the pick actually reach
        // consent → receipt → `aiMode == .online`. Consent is NOT bypassed —
        // the user still accepts the sheet; this only opens it.
        if mode == .online, let container = appContainer,
           Self.shouldRequestServerManagedConsent(
               isServerManagedAvailable: container.aiProviderStore.config?.usesProviderOpaqueAIConsent == true,
               hasServerManagedConsent: container.aiConsentStore.hasServerManagedConsent()
           )
        {
            container.aiConsentStore.requestExplicitPrompt()
        }
    }

    /// RCA-coach-ai — the testable decision behind both the
    /// External-AI pick (``handleModePick``) and the online-intent carry-through
    /// (``carryThroughOnlineIntentIfNeeded``): should picking External AI route
    /// to the server-managed consent sheet? True iff the server reports
    /// server/admin-managed AI is available AND it isn't already consented.
    ///
    /// Deliberately does NOT consult ``AIConsentStore/wasServerManagedDeclined``:
    /// this fires only from an *explicit user pick*, so a prior decline must be
    /// re-engageable (mirrors the per-provider explicit-CTA path, which also
    /// bypasses the wasDeclined auto-suppression). Skipping when already
    /// consented avoids re-prompting a working setup.
    static func shouldRequestServerManagedConsent(
        isServerManagedAvailable: Bool,
        hasServerManagedConsent: Bool
    ) -> Bool {
        isServerManagedAvailable && !hasServerManagedConsent
    }

    /// b182 (AUDIT-COACH-PARITY F2 / RCA-ai-consent-flow Commit C) — honour the
    /// onboarding "External AI" pick by presenting the informed-consent sheet ONCE,
    /// in context, on first Settings → Assistant entry. Onboarding records an
    /// `onlineIntentPending` flag only (it can't host the consent sheet — the
    /// authenticated shell isn't mounted yet, `AISourceStep.commit`), so a user who
    /// picked External AI with a *configured* provider used to land at `.none` with
    /// no Coach until they happened to re-pick. This carries the intent to a real
    /// `grant(for:)` via `requestExplicitPrompt()` (the shell's explicit-CTA path,
    /// which bypasses the `wasDeclined` auto-suppression).
    ///
    /// Conditions (all must hold):
    ///   - the picker is showing `.online` (a pending intent or a resolved grant),
    ///   - a *user-configured* provider is resolved (`!= .unconfigured`) — the
    ///     admin/server-managed `null`-provider case is GH #24 and out of scope; we
    ///     never present a sheet that would `grant(.unconfigured)` (a no-op),
    ///   - the user hasn't already consented (`!hasConsent`) and hasn't actively
    ///     declined (`!wasDeclined`) — a decline is honoured; the F1 re-engage
    ///     affordance is the explicit path back from there,
    ///   - this hasn't already fired this visit (`!didCarryThroughOnlineIntent`).
    private func carryThroughOnlineIntentIfNeeded() {
        guard !didCarryThroughOnlineIntent,
              let container = appContainer,
              displayedMode == .online,
              container.aiOnlineIntentPending else { return }
        guard container.aiProviderStore.config?.isServerAIAvailable == true else { return }
        // RCA-coach-ai — SERVER-MANAGED branch. When the displayed
        // online pick is server/admin-managed (`managedBy:"server"`, per-user
        // `provider:null` → `resolvedAIProvider == .unconfigured`), the
        // per-provider carry-through below can never fire (its `provider !=
        // .unconfigured` guard excludes it — historically GH #24 "out of
        // scope"). That left an onboarding/Settings online intent stranded at
        // `aiMode == .none` (the dead pick). Route it to the shell's explicit
        // consent path instead, which presents the server-managed sheet and, on
        // accept, grants the scope + mints the `ai_full` ConsentReceipt →
        // `aiMode == .online`. `requestExplicitPrompt()` deliberately bypasses
        // the `wasServerManagedDeclined()` auto-suppression, so a user who
        // declined once but re-picks External AI is re-engaged (not silently
        // stuck on-device). Consent is still required — this only opens it.
        if Self.shouldRequestServerManagedConsent(
            isServerManagedAvailable: container.aiProviderStore.config?.usesProviderOpaqueAIConsent == true,
            hasServerManagedConsent: container.aiConsentStore.hasServerManagedConsent()
        ) {
            didCarryThroughOnlineIntent = true
            container.aiConsentStore.requestExplicitPrompt()
            return
        }
        // Server-managed but already consented: nothing to carry through.
        if container.aiProviderStore.config?.usesProviderOpaqueAIConsent == true { return }
        let provider = container.resolvedAIProvider
        guard provider != .unconfigured,
              !container.aiConsentStore.hasConsent(for: provider),
              !container.aiConsentStore.wasDeclined(for: provider) else { return }
        didCarryThroughOnlineIntent = true
        container.aiConsentStore.requestExplicitPrompt()
    }

    /// Lazily build the BYO entry model if not already present.
    private func ensureBYOKeyEntryModel() {
        guard byoKeyEntryModel == nil, let container = appContainer else { return }
        byoKeyEntryModel = container.makeBYOKeyEntryModel()
    }

    /// The capability-aware option list driving the picker.
    /// On-device is capability-gated (hidden when permanently incapable,
    /// disabled-with-reason when recoverable).
    private var offeredOptions: [AISourceOption] {
        AISourceOptions.offered(
            onDeviceAvailability: appContainer?.onDeviceAIAvailability ?? .unsupported
        )
    }

    /// Recovery action from a disabled On-device card. Opens the
    /// app's System Settings page so the user can enable Apple Intelligence
    /// (no public deep-link to the Apple Intelligence pane exists; the app
    /// settings page is the standard recovery affordance). The scenePhase
    /// re-probe above unlocks the card on return.
    private func handleRecover(_ recovery: AISourceRecovery) {
        switch recovery {
        case .openAppleIntelligenceSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        case .openAssistantSettings:
            // No-op here: this screen IS the Assistant hub, so the
            // provider/BYO config is already on-screen below. The recovery only
            // routes meaningfully from the Coach chooser (a different host).
            break
        }
    }
}
