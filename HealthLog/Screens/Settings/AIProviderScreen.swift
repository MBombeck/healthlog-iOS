import SwiftUI

/// AI-Provider settings surface. **B2 rewrite per M2-A3 §2.**
///
/// The old surface was a single `Picker("AI-Provider", …)` row on
/// `SettingsScreen` that read from `insightsStore.comprehensive.provider`
/// (the rendering-model field) and wrote an invalid lowercase provider value
/// to a route that only exports `GET/PATCH` against the supported provider
/// vocabulary. Every read showed a phantom config; every write 405'd silently;
/// the user reported "ich klicke
/// woanders, dann ist es weg".
///
/// This screen:
///   1. Pulls the real configuration surface from the server (provider +
///      per-provider key/preview/model/baseUrl flags).
///   2. Lets the user pick the provider in a list with a clear configured /
///      not-configured badge per row.
///   3. Surfaces the per-provider edit fields (API key for OPENAI/ANTHROPIC,
///      base URL + key for LOCAL).
///   4. Saves with explicit user intent (only the save button writes; tapping
///      elsewhere never clears state).
///   5. Shows a "Konfiguriert via X — Fallback Y → Z" chain visualization so
///      the user understands the AI cascade (server tries primary, falls
///      back to secondary, finally `LOCAL` if available).
///
/// A refactor into helper structs would only shuffle the same code across
/// files; the local
/// `swiftlint:disable:this type_body_length` stays the smaller scar.
///
/// **UI-Standard R12 (U4) — vom Screen zur Sektion.** Dieser Typ hieß
/// `AIProviderScreen` und war ein vollständiges `HLSettingsPage` mit eigenem
/// `ScrollView`. Sein einziger Aufrufer, ``SettingsAIScreen``, bettete ihn
/// mitten auf seiner eigenen scrollenden Seite ein — ein `ScrollView` im
/// `ScrollView`, dokumentiert als Workaround für einen Scroll-Bug, mit dem
/// Nebeneffekt, dass die Formensprache mitten auf der Seite wechselte. Der Typ
/// liefert jetzt nur noch **Karten**; das Seitengerüst besitzt der Host. Damit
/// verschwindet die Verschachtelung, statt kompensiert zu werden, und der
/// `setsNavigationTitle:`-Schalter (samt `ConditionalNavigationTitle`) ist
/// überflüssig geworden — es gibt keinen Titel-Wettlauf mehr, weil es nur
/// noch einen Titel gibt.
struct AIProviderSection: View { // swiftlint:disable:this type_body_length
    @Environment(AIProviderStore.self) private var store
    @Environment(\.appContainer) private var container

    @State private var didPerformInitialLoad = false

    var body: some View {
        // Bug 3 (v0.14.8) — anchor on `AIConsentStore.revision` so the consent
        // toggle (and its presence) re-evaluate when a grant is revoked from the
        // picker's "No assistant" path. The toggle reads `hasConsent`, computed
        // from the Keychain (untracked by Observation), so without this anchor the
        // card stayed stale after a disable.
        // swiftlint:disable:next redundant_discardable_let
        let _ = container?.aiConsentStore.revision
        // W1-5 / R5 #2 — body converted from a multi-section `Form` to the
        // `HLSettingsCard` paradigm so Settings → KI feels identical to the
        // rest of the Settings hub. Every preserved field, picker, button +
        // chain visual stays; the envelope changes from
        // `Form { Section header footer }` to `HLSettingsCard(icon: title:
        // footer:)`.
        //
        // R12 (U4) — der `VStack` ersetzt das frühere `HLSettingsPage`: er
        // reiht die Karten im selben `HLSpace.lg`-Rhythmus, den der
        // `LazyVStack` des Hosts vorgibt, und trägt die Modifier der Sektion
        // genau einmal (ein `Group` würde sie auf jede Karte einzeln legen und
        // `.task` pro Karte feuern).
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            statusCard
            // A provider identifier unknown to this client is still a valid,
            // server-confirmed configuration. Do not render a misleading
            // "None" editor that could overwrite it; manage that provider on
            // the server until this app version understands its fields.
            if !store.usesProviderOpaqueAIConsent {
                providerPickerCard
                if store.draftProvider != .unconfigured {
                    providerDetailsCard
                }
            }
            // PB1 H2 / Bug 3 (v0.14.8) — consent toggle. Render it whenever there
            // is a real server provider OR an existing grant. Gating it ONLY on
            // `serverProvider != .unconfigured` made the disable affordance vanish
            // when the live `config` resolved `.unconfigured` (not loaded yet) —
            // leaving a granted user with no way to turn External AI off. Keying
            // the toggle on the *granted* provider (falling back to the server
            // provider) keeps disable always reachable.
            if let container, let toggleProvider = consentToggleProvider {
                AIConsentToggleCard(
                    provider: toggleProvider,
                    consentStore: container.aiConsentStore
                )
            }
            chainCard
            if !store.usesProviderOpaqueAIConsent {
                saveCard
            }
            if let error = store.error {
                errorCard(error)
            }
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
            // primitive as Dashboard/Insights, self-suppressing).
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
        .task {
            guard !didPerformInitialLoad else { return }
            didPerformInitialLoad = true
            await store.load()
        }
        // R12 — `.refreshable` (und der Erfolgs-Tick) liegen jetzt beim Host:
        // ein `refreshable` gehört an den ScrollView, und den besitzt seit der
        // Auflösung der Verschachtelung `SettingsAIScreen`. Pull-to-Refresh
        // aktualisiert damit die ganze Assistent-Seite statt nur ihres unteren
        // Drittels.
        .onChange(of: store.didJustSave) { _, didSave in
            guard didSave else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                store.acknowledgeSaved()
            }
        }
    }

    // MARK: - Cards (W1-5)

    private var statusCard: some View {
        HLSettingsCard(icon: "info.circle.fill", title: "Status") {
            statusRow
            if let preview = store.serverKeyPreview {
                Divider().opacity(0.5)
                HStack {
                    Text("Current key")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                    Spacer(minLength: HLSpace.sm)
                    Text(preview)
                        .font(.hlMetric(.body))
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                        .accessibilityIdentifier(Self.keyPreviewIdentifier)
                }
            }
            Divider().opacity(0.5)
            statusFooter
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusRow: some View {
        HStack(spacing: HLSpace.md) {
            HLSettingsIconChip(
                symbol: store.usesProviderOpaqueAIConsent ? "server.rack" : store.serverProvider.iconName,
                tint: store.usesProviderOpaqueAIConsent ? HLColor.cyan : store.serverProvider.iconTint
            )
            // R3 — die Anbieter-Herkunft („API-Schlüssel von console.anthropic.com")
            // stand dreimal in einer Ansicht: hier, in jeder Picker-Zeile und als
            // Footer der Detail-Karte. Heimat ist die Detail-Karte, wo sie beim
            // Eingabefeld steht; in der Status-Zeile trug sie nichts, was der
            // Footer derselben Karte zwei Zeilen tiefer nicht sagt.
            Text(store.usesProviderOpaqueAIConsent ? String(localized: "External AI") : store.serverProvider.label)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.sm)
            statusBadge
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if store.didJustSave {
            HLBadge(String(localized: "aiprovider.badge.saved"), icon: "checkmark", tone: .success)
                .accessibilityIdentifier(Self.savedBadgeIdentifier)
        } else if store.isLoading || store.config == nil {
            // Bug 4 (v0.14.8) — "Not configured" must mean "the server genuinely
            // has no provider", NOT "the client hasn't loaded the config yet".
            // While `config == nil` (load in flight or not yet started) show the
            // neutral progress affordance instead of falsely claiming the user
            // must add a provider.
            ProgressView().controlSize(.small)
        } else if store.isServerFullyConfigured {
            HLBadge(String(localized: "aiprovider.badge.configured"), icon: "checkmark.seal.fill", tone: .success)
                .accessibilityIdentifier(Self.configuredBadgeIdentifier)
        } else if store.serverProvider == .unconfigured {
            HLBadge(String(localized: "Not configured"), icon: "circle.slash", tone: .warning)
                .accessibilityIdentifier(Self.notConfiguredBadgeIdentifier)
        } else {
            HLBadge(String(localized: "Key missing"), icon: "exclamationmark.triangle.fill", tone: .warning)
                .accessibilityIdentifier(Self.missingKeyBadgeIdentifier)
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if store.usesProviderOpaqueAIConsent {
            Text("Your server provides the assistant. No provider key is stored in this app.")
        } else {
            switch store.serverProvider {
            case .unconfigured:
                // Bug 4 (v0.14.8) — the provider is a *server* concern; frame the
                // empty state as "the server has none set up yet" rather than an
                // in-app error the user is failing to resolve.
                Text(
                    "Your server doesn't have an assistant provider set up yet. Configure one below, or ask your server's operator to add one."
                )
            case .anthropic:
                Text("Anthropic processes your insights. Your API key is stored encrypted on the server.")
            case .openai:
                Text("OpenAI processes your insights. Your API key is stored encrypted on the server.")
            case .local:
                Text("A local Ollama or LM Studio instance is in use. The server has to reach this URL.")
            case .openaiCompatible:
                // CU-16 — the server resolved an OpenAI-compatible endpoint. iOS
                // cannot name the vendor behind it and has no field for its base
                // URL or key, so the line says exactly that and points at the
                // server instead of implying an in-app setting is missing.
                Text("Your server uses an OpenAI-compatible endpoint. It is configured on the server, not in this app.")
            }
        }
    }

    // MARK: - Provider picker

    @ViewBuilder
    private var providerPickerCard: some View {
        @Bindable var bindable = store
        HLSettingsCard(icon: "sparkles", title: "Select provider") {
            ForEach(providerCases, id: \.self) { provider in
                Button {
                    bindable.draftProvider = provider
                } label: {
                    HStack(spacing: HLSpace.md) {
                        HLSettingsIconChip(symbol: provider.iconName, tint: provider.iconTint)
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            Text(provider.label)
                                .font(.hlSubhead.weight(.semibold))
                                .foregroundStyle(HLText.primary)
                            Text(provider.subtitle)
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: HLSpace.sm)
                        if bindable.draftProvider == provider {
                            Image(systemName: "checkmark")
                                .font(.hlIcon(HLIconSize.rowAction))
                                .foregroundStyle(.tint)
                                .accessibilityIdentifier("aiProvider.selectionMark.\(provider.rawValue)")
                        }
                    }
                    .contentShape(Rectangle())
                }
                // W1-7: app-wide press-feedback
                .hlPressable()
                .accessibilityIdentifier("aiProvider.row.\(provider.rawValue)")
                if provider != providerCases.last {
                    Divider().opacity(0.5)
                }
            }
        }
    }

    private var providerCases: [AIProvider] {
        [.unconfigured] + AIProvider.configurableCases
    }

    /// Bug 3 (v0.14.8) — the provider the consent/disable toggle keys on.
    /// Prefers the live server provider; falls back to the granted provider so
    /// the disable affordance stays reachable even when `config` hasn't resolved
    /// a server provider yet. `nil` only when there is neither a server provider
    /// nor any grant — then there is nothing to consent to or disable.
    private var consentToggleProvider: AIProvider? {
        if store.serverProvider != .unconfigured {
            return store.serverProvider
        }
        // Reading `revision` (via container) is what re-renders this branch when a
        // grant is revoked elsewhere; the parent body already anchors on it.
        return container?.aiConsentStore.activeGrantedProvider()
    }

    // MARK: - Provider details

    private var providerDetailsCard: some View {
        HLSettingsCard(icon: "key.horizontal.fill", title: LocalizedStringKey(store.draftProvider.label)) {
            switch store.draftProvider {
            case .anthropic, .openai:
                cloudKeyField
                modelOverrideField
            case .local:
                baseURLField
                localKeyField
                modelOverrideField
            case .unconfigured, .openaiCompatible:
                // `.openaiCompatible` is operator-owned: its base
                // URL + key, no iOS field to render.
                EmptyView()
            }
            Divider().opacity(0.5)
            providerDetailsFooter
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var providerDetailsFooter: some View {
        switch store.draftProvider {
        case .anthropic:
            Text("API key: get one at console.anthropic.com under Settings → API Keys.")
        case .openai:
            Text("API key: get one at platform.openai.com under API Keys.")
        case .local:
            Text(
                "Base URL: e.g. https://ollama.example.com — the server has to reach this host publicly. Local 192.168.x.x addresses are blocked by default."
            )
        case .unconfigured, .openaiCompatible:
            // `.openaiCompatible` has no iOS-editable field.
            EmptyView()
        }
    }

    @ViewBuilder
    private var cloudKeyField: some View {
        @Bindable var bindable = store
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            if let preview = store.serverKeyPreview, store.serverProvider == store.draftProvider {
                HStack {
                    Text("Current:")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                    Text(preview)
                        .font(.hlMetric(.caption))
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await store.clearAPIKey() }
                    } label: {
                        Text("Remove")
                            .font(.hlCaption.weight(.semibold))
                    }
                    .disabled(store.isSaving)
                }
            }
            SecureField(String(localized: "New API key"), text: $bindable.draftAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(Self.apiKeyFieldIdentifier)
        }
    }

    @ViewBuilder
    private var localKeyField: some View {
        @Bindable var bindable = store
        SecureField(String(localized: "Local API key (optional)"), text: $bindable.draftAPIKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(Self.localKeyFieldIdentifier)
    }

    @ViewBuilder
    private var baseURLField: some View {
        @Bindable var bindable = store
        TextField(String(localized: "aiprovider.baseUrl.placeholder"), text: $bindable.draftBaseUrl)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(Self.baseURLFieldIdentifier)
    }

    @ViewBuilder
    private var modelOverrideField: some View {
        @Bindable var bindable = store
        TextField(String(localized: "aiprovider.model.placeholder"), text: $bindable.draftModel)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(Self.modelFieldIdentifier)
    }

    // MARK: - Chain visualisation

    /// "AI-Provider chain visualization" per the B2 brief — explains which
    /// provider is tried first and what the fallback looks like. The server
    /// today never falls back across providers (each provider uses its own
    /// key in isolation); the "fallback" is the deterministic-template
    /// response surfaced when no provider is configured AND no recent
    /// briefing exists. We visualise that truth honestly here so the user
    /// understands the cascade.
    private var chainCard: some View {
        HLSettingsCard(
            icon: "arrow.triangle.branch",
            title: "Order",
            footer: "On errors, rate limits or a missing key, the server falls back to a deterministic template that only summarises local values."
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                chainStep(
                    index: 1,
                    label: store.usesProviderOpaqueAIConsent
                        ? String(localized: "External AI")
                        : store.serverProvider == .unconfigured
                        ? String(localized: "No assistant provider active")
                        : String(localized: "Primary: \(store.serverProvider.label)"),
                    isActive: store.isServerAIAvailable,
                    tint: store.usesProviderOpaqueAIConsent ? HLColor.cyan : store.serverProvider.iconTint
                )
                chainArrow
                chainStep(
                    index: 2,
                    label: String(localized: "aiprovider.fallback.label"),
                    isActive: true,
                    tint: HLText.secondary
                )
            }
        }
    }

    private func chainStep(index: Int, label: String, isActive: Bool, tint: Color) -> some View {
        HStack(spacing: HLSpace.md) {
            ZStack {
                Circle()
                    .fill(tint.opacity(isActive ? 0.18 : 0.08))
                    .frame(width: 28, height: 28)
                Text("\(index)")
                    .font(.hlCaption.weight(.bold))
                    .foregroundStyle(isActive ? tint : HLText.tertiary)
            }
            Text(label)
                .font(.hlBody)
                .foregroundStyle(isActive ? HLText.primary : HLText.secondary)
        }
    }

    private var chainArrow: some View {
        HStack(spacing: HLSpace.md) {
            Image(systemName: "arrow.down")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.tertiary)
                .frame(width: 28)
            Spacer()
        }
    }

    // MARK: - Save

    private var saveCard: some View {
        // W1-5: save lives in a borderless container so the primary
        // CTA stays the loudest surface on the screen. Wrap in a
        // VStack inside the card paradigm to maintain rhythm with the
        // surrounding cards while preserving the full-width HLButton
        // affordance.
        //
        // R9 — „Speichern am Formularende" ist die abschließende Commit-Aktion
        // des Flows und damit `.primary`; das ist die EINZIGE `.primary`-Fläche
        // der Assistent-Seite (siehe die Begründung an `BYOKeyEntryCard`).
        VStack(spacing: 0) {
            HLButton(
                String(localized: "Save"),
                icon: store.isSaving ? nil : "checkmark.circle.fill",
                variant: .primary,
                isLoading: store.isSaving
            ) {
                Task { await store.save() }
            }
            .disabled(!store.hasUnsavedChanges || store.isSaving)
            .accessibilityIdentifier(Self.saveButtonIdentifier)
        }
        .padding(.top, HLSpace.sm)
    }

    // MARK: - Error

    private func errorCard(_ error: HLError) -> some View {
        HLSettingsCard(icon: "exclamationmark.octagon.fill", title: "Error") {
            HStack(alignment: .top, spacing: HLSpace.md) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(HLColor.statusBad)
                Text(error.userFacingDescription)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.primary)
            }
        }
    }

    // MARK: - Accessibility identifiers

    static let configuredBadgeIdentifier = "aiProvider.status.configured"
    static let notConfiguredBadgeIdentifier = "aiProvider.status.notConfigured"
    static let missingKeyBadgeIdentifier = "aiProvider.status.missingKey"
    static let savedBadgeIdentifier = "aiProvider.status.saved"
    static let keyPreviewIdentifier = "aiProvider.keyPreview"
    static let apiKeyFieldIdentifier = "aiProvider.field.apiKey"
    static let localKeyFieldIdentifier = "aiProvider.field.localKey"
    static let baseURLFieldIdentifier = "aiProvider.field.baseURL"
    static let modelFieldIdentifier = "aiProvider.field.model"
    static let saveButtonIdentifier = "aiProvider.saveButton"
    static let consentToggleIdentifier = "aiProvider.consentToggle"
}

/// PB1 H2 — Settings → KI surface for the consent toggle promised in
/// `AIConsentSheet`'s bullet 3 ("in Einstellungen → KI jederzeit
/// deaktivieren"). Bound to the current server-truth provider, NOT the
/// draft — the draft is what the user is about to save, not what is
/// currently active. Toggling off calls `AIConsentStore.revoke(for:)`
/// which clears both grant + decline records. Toggling on asks the shell
/// to re-present `AIConsentSheet` (which is also where the actual grant
/// happens — no auto-grant from the toggle; explicit affirmative consent
/// only). Extracted from `AIProviderSection` to keep the parent struct
/// under the SwiftLint type-body-length cap.
private struct AIConsentToggleCard: View {
    let provider: AIProvider
    let consentStore: AIConsentStore

    var body: some View {
        let isGranted = consentStore.hasConsent(for: provider)
        HLSettingsCard(
            icon: "checkmark.shield.fill",
            title: "Assistent-Einwilligung",
            // R18 — war ein hartkodiertes deutsches Literal ohne Katalog-
            // eintrag (PROJECT_GUIDE.md: keine hardcoded UI-Strings). Der englische
            // Quelltext ist jetzt der Schlüssel, die deutsche Fassung steht
            // wortgleich im Katalog — englische Nutzer sahen hier bislang
            // deutschen Text. Inhalt unverändert (Klasse D).
            footer: "This consent can be withdrawn at any time. Enabling shows a note about the data flow; your consent is only given by tapping “Accept”."
        ) {
            // R11 — war ein roher `Toggle` mit handgebautem Label-Block; die
            // Geometrie (Textbreite, Gap zum Schalter, Tinte der Beschreibung)
            // kommt jetzt aus dem Primitive. Bug 5 (v0.14.8) bleibt gültig: das
            // ist die SERVER-Einwilligung — die Daten gehen an den eigenen
            // Server, der sie weiterreicht; der Client kennt den Namen des
            // Dritt-Anbieters nicht und behauptet ihn deshalb nicht.
            HLSettingsToggleRow(
                title: "Send data to your server",
                description: isGranted
                    ? "Consent granted — assistant insights and findings are active."
                    : "Consent missing — assistant insights and findings are paused.",
                isOn: Binding(
                    get: { isGranted },
                    set: { newValue in
                        if newValue {
                            consentStore.requestExplicitPrompt()
                        } else {
                            consentStore.revoke(for: provider)
                        }
                    }
                ),
                accessibilityID: AIProviderSection.consentToggleIdentifier
            )
        }
    }
}
