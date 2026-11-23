import Foundation

// MARK: - AI consent gate

public extension AppContainer {
    /// Shared resolver for every server-side AI surface. Keeping the receipt
    /// lookup next to ``AIProviderConfig/aiConsentTarget`` prevents Coach,
    /// Insights, and document processing from drifting into different provider
    /// allowlists.
    internal static func hasRequiredServerAIConsent(
        config: AIProviderConfig,
        consentStore: AIConsentStore
    ) -> Bool {
        switch config.aiConsentTarget {
        case .unavailable:
            false
        case .providerOpaque:
            consentStore.hasServerManagedConsent()
        case let .provider(provider):
            consentStore.hasConsent(for: provider)
        }
    }

    /// Current account-bound consent for server-mediated document processing.
    /// A BYO grant and the on-device mode intentionally never satisfy this: the
    /// document endpoints execute on the user's server and may forward stored
    /// originals/OCR to that server's configured provider.
    var documentExternalAIConsentGranted: Bool {
        Self.currentDocumentAIConsentLease(
            keychain: keychain,
            consentStore: aiConsentStore,
            providerStore: aiProviderStore
        ) != nil
    }

    /// Repository wiring for the transport-near document gate. The resolver is
    /// evaluated for every capture/revalidation rather than freezing a launch-
    /// time grant, so revoke, provider change, logout, token rotation, and an
    /// account switch all invalidate an in-progress preflight.
    internal func makeDocumentAIConsentLeaseProvider() -> DocumentAIConsentLeaseProvider {
        Self.makeDocumentAIConsentLeaseProvider(
            keychain: keychain,
            consentStore: aiConsentStore,
            providerStore: aiProviderStore
        )
    }

    internal static func makeDocumentAIConsentLeaseProvider(
        keychain: KeychainStoring,
        consentStore: AIConsentStore,
        providerStore: AIProviderStore
    ) -> DocumentAIConsentLeaseProvider {
        DocumentAIConsentLeaseProvider { [weak consentStore, weak providerStore] in
            await MainActor.run {
                guard let consentStore, let providerStore else { return nil }
                return Self.currentDocumentAIConsentLease(
                    keychain: keychain,
                    consentStore: consentStore,
                    providerStore: providerStore
                )
            }
        }
    }

    private static func currentDocumentAIConsentLease(
        keychain: KeychainStoring,
        consentStore: AIConsentStore,
        providerStore: AIProviderStore
    ) -> DocumentAIConsentLease? {
        guard let owner = keychain.getString(forKey: KeychainKey.userID), !owner.isEmpty,
              let bearer = keychain.getString(forKey: KeychainKey.authToken), !bearer.isEmpty,
              let config = providerStore.config else
        {
            return nil
        }

        let provider = config.resolvedProvider
        guard let scope = resolveDocumentAIConsentScope(
            config: config,
            hasServerManagedConsent: consentStore.hasServerManagedConsent(),
            hasConfiguredProviderConsent: provider != .unconfigured && consentStore.hasConsent(for: provider)
        ) else { return nil }
        return DocumentAIConsentLease(ownerUserID: owner, bearerToken: bearer, scope: scope)
    }

    /// Resolves only the consent arm that actually owns the server document
    /// route. Server-managed and concrete-provider grants are not interchangeable;
    /// BYO/on-device modes are intentionally absent and therefore cannot resolve.
    internal static func resolveDocumentAIConsentScope(
        config: AIProviderConfig,
        hasServerManagedConsent: Bool,
        hasConfiguredProviderConsent: Bool
    ) -> DocumentAIConsentLease.Scope? {
        switch config.aiConsentTarget {
        case .unavailable:
            nil
        case .providerOpaque:
            hasServerManagedConsent ? .serverManaged : nil
        case let .provider(provider):
            hasConfiguredProviderConsent ? .serverProvider(provider) : nil
        }
    }

    /// Builds the @MainActor consent-gate closure used by the
    /// chart-detail "Befunde" path (`ChartDetailStore`). The closure reads
    /// the current provider lazily so a user who switches provider mid-
    /// session hits the gate again automatically. Mirrors the wiring used
    /// in `init` for `InsightsStore` + `DailyBriefingStore`. Returns the
    /// permissive default `true` only when one of the dependencies is gone
    /// — production wiring always sets both stores, so the permissive
    /// branch is only ever hit during teardown.
    ///
    /// Extracted from `AppContainer.swift` in T-5 to keep the main file
    /// under the swiftlint 600-line ceiling.
    func makeAIConsentGate() -> @MainActor () -> Bool {
        let consent = aiConsentStore
        let providers = aiProviderStore
        return { [weak consent, weak providers] in
            guard let consent, let providers else { return true }
            guard let config = providers.config else { return false }
            return Self.hasRequiredServerAIConsent(config: config, consentStore: consent)
        }
    }

    /// S7 / QA3 BLOCKER 2 — builds the paired consent gates the `init` body
    /// wires onto `InsightsStore` / `DailyBriefingStore` (sync) and threads into
    /// `makeMetricInsights` (async). Closures moved VERBATIM from the prior
    /// inline `init` block; both weakly capture the two stores and read the
    /// provider lazily so a mid-session provider switch re-hits the gate.
    ///
    /// Both paths resolve the same provider-opaque/concrete consent target so
    /// Coach, briefings, and per-metric insights cannot disagree.
    static func makeInsightsConsentGates(
        consentStore: AIConsentStore,
        providerStore: AIProviderStore
    ) -> (sync: @MainActor () -> Bool, async: @Sendable () async -> Bool) {
        // S7 / QA3 BLOCKER 2: gate insight fetches by AI consent. The
        // closure reads the current provider lazily, so a user switching
        // providers after first launch hits the gate again automatically.
        let gate: @MainActor () -> Bool = { [weak consentStore, weak providerStore] in
            guard let consentStore, let providerStore else { return true }
            guard let config = providerStore.config else { return false }
            return hasRequiredServerAIConsent(config: config, consentStore: consentStore)
        }
        // Gate the per-metric "Befunde" path with the same closure.
        // `MetricInsightsRepository` is a Sendable actor so the gate must be
        // Sendable + async; we hop to the main actor to call the @MainActor
        // gate closure once per fetch — the hop is cheap and fail-closed:
        // if the store is gone (logout race), `weak`-capture returns false
        // and the fetch is skipped rather than leaking a request.
        let asyncGate: @Sendable () async -> Bool = { [weak consentStore, weak providerStore] in
            await MainActor.run {
                guard let consentStore, let providerStore else { return false }
                guard let config = providerStore.config else { return false }
                return hasRequiredServerAIConsent(config: config, consentStore: consentStore)
            }
        }
        return (gate, asyncGate)
    }

    /// Applies the AI-consent gate to the briefing store, wires the
    /// tolerant dashboard-snapshot briefing fetch, and binds the
    /// personal-records snapshot box to the live `PersonalRecordsStore`. Pure
    /// move of the inline init block (same closures); returns the async gate so
    /// the designated init can thread it into `metricInsightsRepo`.
    ///
    /// `static` so the designated init can call it MID-init (before all stored
    /// properties exist) — instance methods cannot run before `self` is fully
    /// initialised. The PR snapshot box is created early + captured by
    /// `MeasurementsStore`; binding its `read` accessor here (after
    /// `personalRecords` exists) is safe — PR detection only fires on a
    /// successful commit, long after init returns.
    internal static func configureInsightsConsentAndPRBox(
        personalRecordsSnapshotBox: PersonalRecordsSnapshotBox,
        personalRecordsStore: PersonalRecordsStore,
        dailyBriefingStore: DailyBriefingStore,
        dashboardRepo: DashboardRepository,
        consentStore: AIConsentStore,
        providerStore: AIProviderStore
    ) -> @Sendable () async -> Bool {
        // Bind the PR snapshot box to the live
        // `PersonalRecordsStore.enrichedRecords` accessor. The box hides the
        // store reference so the store stays free to refresh / replace its list
        // without re-wiring.
        personalRecordsSnapshotBox.read = { [weak personalRecordsStore] in
            personalRecordsStore?.enrichedRecords ?? []
        }
        // S7 / QA3 BLOCKER 2 — paired consent gates (sync + async). The sync
        // gate sits on DailyBriefingStore so the /api/insights/generate POST
        // respects consent (Guideline 5.1.2(i)). It no longer sits
        // on InsightsStore: `insights/comprehensive` is deterministic data.
        let consentGates = makeInsightsConsentGates(
            consentStore: consentStore,
            providerStore: providerStore
        )
        dailyBriefingStore.consentGate = consentGates.sync
        // v1.16.x — tolerant briefing slot off
        // `GET /api/dashboard/snapshot`. Read-only lift, no LLM server-side →
        // NOT consent-gated.
        dailyBriefingStore.snapshotFetch = {
            try await dashboardRepo.snapshotBriefing()
        }
        return consentGates.async
    }

    // MARK: - Single remote-AI master opt-in

    /// The currently server-resolved AI provider (`.unconfigured` when none is
    /// set). Reading it inside a SwiftUI body establishes
    /// observation on `AIProviderStore.config`, so the master toggle + render
    /// gates re-evaluate when the operator (or the server) changes the provider.
    var resolvedAIProvider: AIProvider {
        aiProviderStore.config?.resolvedProvider ?? .unconfigured
    }

    /// The **single** master opt-in that drives every remote-AI
    /// surface (the per-metric / overview server-generated assessment texts and
    /// the ✦ Coach). True iff the user has granted remote-AI consent for any
    /// real provider — the existing per-provider grant record IS the opt-in, so
    /// a prior grant via `AIConsentSheet` reads as ON with no parallel flag.
    ///
    /// This is the *intent* flag only. Surfaces still AND it with their own
    /// availability (the server envelope's `hasProvider`) so no-provider stays
    /// hidden even when ON —
    /// nothing to show, never an empty box.
    var remoteAIEnabled: Bool {
        aiConsentStore.isAnyProviderGranted()
    }

    // MARK: - Three-way AI source choice

    /// The user's single ``AIMode`` choice — `.none` / `.onDevice` / `.online`
    /// — resolved from `AIConsentStore`. This is the source of truth every AI
    /// surface reads: `.none` hides everything, `.onDevice` shows locally
    /// generated content, `.online` shows the server (Task #50) content.
    /// Reading it in a SwiftUI body establishes `@Observable` observation on
    /// the consent store so the gates re-evaluate when the choice changes.
    ///
    /// Back-compat: `remoteAIEnabled == (aiMode == .online)`, so a prior Task
    /// #49 grant reads back as `.online` and every existing `remoteAIEnabled`
    /// call site keeps its exact meaning.
    var aiMode: AIMode {
        aiConsentStore.aiMode
    }

    /// True when the on-device assistant arm is active (`aiMode == .onDevice`).
    /// Surfaces that have a wired on-device generation path (Daily Briefing,
    /// per-metric trend hints, the on-device Coach) read this to render their
    /// locally-generated content without any off-device traffic.
    var onDeviceAIEnabled: Bool {
        aiConsentStore.aiMode == .onDevice
    }

    /// True when the client-side BYO-key arm is active
    /// (`aiMode == .byoKey`). Surfaces with a wired BYO generation path (Coach,
    /// and later the briefing) read this to route through `BYOLLMService`
    /// (device→provider directly), distinct from `.online` (server-mediated).
    var byoKeyAIEnabled: Bool {
        aiConsentStore.aiMode == .byoKey
    }

    /// True when the user picked "Own key" but has not yet completed key
    /// entry + consent, so the choice is held as a pending intent. Read ONLY by
    /// the Settings picker (keep "Own key" selected) and the inline key-entry
    /// card (stay expanded) — mirrors ``aiOnlineIntentPending``. Does NOT open any
    /// app-wide AI gate until a real BYO grant lands.
    var aiBYOKeyIntentPending: Bool {
        aiConsentStore.isBYOKeyIntentPending
    }

    /// Builds the ``BYOKeyEntryModel`` backing the inline "Own key"
    /// entry card in Settings → Assistant. A fresh ``BYOLLMService`` is used for
    /// the **validate** round-trip (no consent gate needed — validation is a
    /// cheap pre-grant key check that the user explicitly triggered, transmitting
    /// no health data). The Coach transmit path uses a *separate*, consent-gated
    /// service (see `AppContainer+SpeziLLM`). Built fresh per call so the card's
    /// drafts never leak across presentations.
    @MainActor
    func makeBYOKeyEntryModel() -> BYOKeyEntryModel {
        let keyStore = BYOKeyStore(keychain: keychain)
        let service = BYOLLMService(keyStore: keyStore)
        return BYOKeyEntryModel(service: service, keyStore: keyStore, consent: aiConsentStore)
    }

    /// Current on-device AI availability (Apple FoundationModels),
    /// surfaced for the AI-source picker so it can hide the On-device card on
    /// permanently-incapable hardware (`.deviceNotEligible` / `.unsupported`) or
    /// show it disabled-with-reason on recoverable states
    /// (`.appleIntelligenceNotEnabled` → Settings deep-link, `.modelNotReady` →
    /// "preparing"). Reading it in a SwiftUI body tracks `LocalLLMService`'s
    /// `@Observable` availability so the picker re-evaluates live (e.g. after the
    /// user enables Apple Intelligence) without a relaunch.
    var onDeviceAIAvailability: LocalLLMService.Availability {
        localLLMService.availability
    }

    /// True only when the on-device path can serve a request right now.
    var onDeviceAICapable: Bool {
        localLLMService.availability == .available
    }

    /// True when the user picked `.online` but no provider is
    /// configured yet, so the choice is held as a pending intent. Read ONLY by
    /// the Settings AI picker + add-provider hint so the pick survives
    /// navigation instead of snapping back to None. Does NOT open any app-wide
    /// AI gate — ``aiMode`` / ``remoteAIEnabled`` stay closed until a grant lands.
    var aiOnlineIntentPending: Bool {
        aiConsentStore.isOnlineIntentPending
    }

    /// Applies a three-way ``AIMode`` pick from the onboarding step or the
    /// Settings card. Routes the `.online` arm through the informed-consent
    /// sheet (`AIConsentSheet`, Apple 5.1.2(i)) for the resolved provider; the
    /// `.onDevice` / `.none` arms persist immediately (no off-device traffic →
    /// no consent). When `.online` is picked but no provider is configured the
    /// choice is recorded as intent only and the caller surfaces the
    /// add-provider path — never an empty box.
    func setAIMode(_ mode: AIMode) {
        let wasGranted = aiConsentStore.isAnyProviderGranted()
        // Capability guard. Never persist a non-functional on-device
        // choice on an incapable device (ineligible hardware, Apple
        // Intelligence off, model not downloaded): coerce to `.none` so the user
        // is never left with a silently-dead assistant. The picker already
        // hides/disables the card, but this closes the back door for any other
        // caller (deep links, re-onboarding after a device change).
        if mode == .onDevice, localLLMService.availability != .available {
            aiConsentStore.setMode(.none, activeProvider: resolvedAIProvider)
        } else {
            aiConsentStore.setMode(mode, activeProvider: resolvedAIProvider)
        }
        // Keep the SERVER-side consent receipt in
        // lockstep with an explicit switch away from External AI (the store
        // revokes the device grant when the arms flip). See
        // `revokeServerAIConsentReceiptIfGrantDropped`.
        revokeServerAIConsentReceiptIfGrantDropped(wasGranted: wasGranted)
    }

    // MARK: - Server-side consent receipts

    /// Thin wire wrapper for the server's SB-10 consent-receipt routes.
    /// Stateless — built fresh per call (mirrors `makeBYOKeyEntryModel`), so
    /// the main `AppContainer` init stays untouched.
    func makeConsentReceiptRepository() -> ConsentReceiptRepository {
        ConsentReceiptRepository(api: api)
    }

    /// #143 (server v1.43.2) — the launch / shell-mount / Coach pass. It
    /// only READS the standing consent (`ai.consent` on `GET /api/auth/me`,
    /// already loaded by ``ModuleGate``) and never sends a receipt.
    ///
    /// **Why.** Until 1.3.0 this pass minted `ai_full` on every shell mount
    /// whenever the device held a grant. That re-created a consent the person
    /// had withdrawn on the web, and turned a grant for their own provider into
    /// consent for the operator's key. The server now refuses such a mint
    /// (400 `consent.ai.confirmRequired`); a receipt comes only from the Accept
    /// tap (``recordAcceptedAIConsent(repository:refresh:)``).
    ///
    /// Local state follows the server: when it says `needed` while the device
    /// still holds a server-route grant, the grant is dropped HERE ONLY (no
    /// server revoke, there is nothing to revoke), the choice stays visible as
    /// a pending online intent, and the shell asks once. A decline after that
    /// is honoured like any other. `given`, `not_needed` and a server without
    /// `ai.consent` change nothing. BYO-key grants (device to provider) are
    /// never touched.
    ///
    /// Returns `true` when it dropped a local grant.
    @discardableResult
    func reconcileAIConsentWithServer() -> Bool {
        guard aiCapabilityGate.standingConsent?.verdict == .needed,
              aiConsentStore.isAnyProviderGranted() else { return false }
        for provider in AIProvider.allCases where provider != .unconfigured {
            aiConsentStore.revoke(for: provider)
        }
        aiConsentStore.revokeServerManaged()
        aiConsentStore.setOnlineIntentPending(true)
        HLLog.security.info("AI consent: server reports consent needed; local grant set aside, asking once")
        return true
    }

    /// The server half of the person's **Accept tap** (shell sheet
    /// and the Coach's nested sheet). The ONLY caller of
    /// `POST /api/consent/ai`, which carries `confirm: true`, at most once per tap:
    ///
    /// - `ai.consent` says `not_needed` (own provider): nothing is sent.
    /// - `given`: nothing is sent.
    /// - `needed`: one POST.
    /// - no `ai.consent` (server before v1.43.2): the older path, read
    ///   `GET /api/consent/ai/latest` and POST only when no receipt is active.
    ///
    /// After a recorded receipt, or a 400 `consent.ai.confirmRequired`, the
    /// standing state is re-read (`refresh`, default ``ModuleGate/load()``) so
    /// the capabilities follow the server. Nothing here raises an error banner.
    ///
    /// `repository` and `refresh` are test seams only.
    @discardableResult
    func recordAcceptedAIConsent(
        repository: ConsentReceiptRepository? = nil,
        refresh: (@MainActor () async -> Void)? = nil
    ) async -> AIConsentReceiptOutcome {
        guard aiConsentStore.isAnyProviderGranted() else { return .noGrant }
        let verdict = aiCapabilityGate.standingConsent?.verdict
        switch verdict {
        case .notNeeded: return .notNeeded
        case .given: return .alreadyOnFile
        case .needed, .unknown, nil: break
        }
        let repo = repository ?? makeConsentReceiptRepository()
        let outcome = await repo.recordAcceptedConsent(
            artefact: aiConsentArtefact(),
            checkExisting: verdict != .needed
        )
        if outcome == .recorded || outcome == .needsExplicitConsent {
            if let refresh { await refresh() } else { await moduleGate.load() }
        }
        return outcome
    }

    /// The shell consent sheet's **Accept**, as one step instead of a
    /// closure body in the view. Grants the scope the request names.
    ///
    /// The receipt is best-effort by design: a refused or failed
    /// `POST /api/consent/ai` (rate limit, a demo edge allowlist, offline)
    /// leaves the device grant standing. Nothing retries it silently;
    /// the server's `ai.consent` decides whether the sheet asks again.
    ///
    /// Bug 2 — a stray `.unconfigured` never grants: the live config
    /// is re-read (it may have arrived since the sheet opened) and only a real
    /// provider is granted; otherwise ``AIConsentAcceptOutcome/noProvider``
    /// tells the sheet to stay up.
    internal func acceptAIConsent(_ request: AIConsentRequest) -> AIConsentAcceptOutcome {
        if request.serverManaged {
            aiConsentStore.grantServerManaged()
            return aiConsentStore.hasServerManagedConsent() ? .granted : .notPersisted
        }
        let resolved = aiProviderStore.config?.resolvedProvider ?? .unconfigured
        let provider = resolved == .unconfigured ? request.provider : resolved
        guard provider != .unconfigured else { return .noProvider }
        aiConsentStore.grant(for: provider)
        return aiConsentStore.hasConsent(for: provider) ? .granted : .notPersisted
    }

    /// Fires the best-effort server-side master revoke when a mutation dropped
    /// the device grant (`wasGranted` captured before the mutation). Wired to
    /// the EXPLICIT user revocation choke point only (`setAIMode` away from a
    /// granted External-AI arm) — deliberately NOT to
    /// the logout cascade, whose consent wipe is per-device hygiene while the
    /// receipt is the account-level record.
    private func revokeServerAIConsentReceiptIfGrantDropped(wasGranted: Bool) {
        guard wasGranted, !aiConsentStore.isAnyProviderGranted() else { return }
        let repo = makeConsentReceiptRepository()
        Task { await repo.revokeAll() }
    }

    /// The opaque audit artefact stored with a minted receipt — a small JSON
    /// record of the in-app consent act (no health data, no tokens).
    private func aiConsentArtefact() -> String {
        // Name the server-managed scope honestly in the
        // audit artefact when that grant is the active one (no concrete provider).
        let provider: String = if aiConsentStore.activeGrantedProvider() == nil,
                                  aiConsentStore.hasServerManagedConsent()
        {
            "server_managed"
        } else {
            aiConsentStore.activeGrantedProvider()?.rawValue ?? resolvedAIProvider.rawValue
        }
        return """
        {"source":"ios.AIConsentSheet","scope":"ai_full","provider":"\(provider)",\
        "appVersion":"\(environment.appVersion)","build":"\(environment.buildNumber)"}
        """
    }
}

/// What ``AppContainer/acceptAIConsent(_:)`` did.
enum AIConsentAcceptOutcome: Equatable {
    /// The grant is on file; the sheet closes and the tap's receipt is recorded.
    case granted
    /// The Keychain refused the write (logged by the store). The sheet closes
    /// like before; nothing leaves the device because no grant exists.
    case notPersisted
    /// No provider to grant against yet — the sheet stays up.
    case noProvider
}
