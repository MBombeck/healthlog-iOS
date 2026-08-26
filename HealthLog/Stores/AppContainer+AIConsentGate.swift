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

    /// PB1 H1 — Builds the @MainActor consent-gate closure used by the
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
        // PB1 H1 — gate the per-metric "Befunde" path with the same closure.
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

    /// Applies the AI-consent gates to the insights + briefing stores, wires the
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
        insightsStore: InsightsStore,
        dailyBriefingStore: DailyBriefingStore,
        dashboardRepo: DashboardRepository,
        consentStore: AIConsentStore,
        providerStore: AIProviderStore
    ) -> @Sendable () async -> Bool {
        // RECONCILE-CELEBRATE — bind the PR snapshot box to the live
        // `PersonalRecordsStore.enrichedRecords` accessor. The box hides the
        // store reference so the store stays free to refresh / replace its list
        // without re-wiring.
        personalRecordsSnapshotBox.read = { [weak personalRecordsStore] in
            personalRecordsStore?.enrichedRecords ?? []
        }
        // S7 / QA3 BLOCKER 2 — paired consent gates (sync + async). v0.5.0+
        // F5/PA9 RC5 — the sync gate is mirrored on DailyBriefingStore so the
        // /api/insights/generate POST also respects consent (Guideline 5.1.2(i)).
        let consentGates = makeInsightsConsentGates(
            consentStore: consentStore,
            providerStore: providerStore
        )
        insightsStore.consentGate = consentGates.sync
        dailyBriefingStore.consentGate = consentGates.sync
        // v1.16.x (GH issue #15) — tolerant briefing slot off
        // `GET /api/dashboard/snapshot`. Read-only lift, no LLM server-side →
        // NOT consent-gated; standalone mode returns nil inside the repo.
        dailyBriefingStore.snapshotFetch = {
            try await dashboardRepo.snapshotBriefing()
        }
        return consentGates.async
    }

    // MARK: - Task #49 — single remote-AI master opt-in

    /// The currently server-resolved AI provider (`.unconfigured` when none is
    /// set or in standalone). Reading it inside a SwiftUI body establishes
    /// observation on `AIProviderStore.config`, so the master toggle + render
    /// gates re-evaluate when the operator (or the server) changes the provider.
    var resolvedAIProvider: AIProvider {
        aiProviderStore.config?.resolvedProvider ?? .unconfigured
    }

    /// Task #49 — the **single** master opt-in that drives every remote-AI
    /// surface (the per-metric / overview server-generated assessment texts and
    /// the ✦ Coach). True iff the user has granted remote-AI consent for any
    /// real provider — the existing per-provider grant record IS the opt-in, so
    /// a prior grant via `AIConsentSheet` reads as ON with no parallel flag.
    ///
    /// This is the *intent* flag only. Surfaces still AND it with their own
    /// availability (`BackendAvailability.hasServer`, the server envelope's
    /// `hasProvider`) so standalone / no-provider stays hidden even when ON —
    /// nothing to show, never an empty box.
    var remoteAIEnabled: Bool {
        aiConsentStore.isAnyProviderGranted()
    }

    // MARK: - Task #53 — three-way AI source choice

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

    /// v0.13 — true when the client-side BYO-key arm is active
    /// (`aiMode == .byoKey`). Surfaces with a wired BYO generation path (Coach,
    /// and later the briefing) read this to route through `BYOLLMService`
    /// (device→provider directly), distinct from `.online` (server-mediated).
    var byoKeyAIEnabled: Bool {
        aiConsentStore.aiMode == .byoKey
    }

    /// v0.13 — true when the user picked "Own key" but has not yet completed key
    /// entry + consent, so the choice is held as a pending intent. Read ONLY by
    /// the Settings picker (keep "Own key" selected) and the inline key-entry
    /// card (stay expanded) — mirrors ``aiOnlineIntentPending``. Does NOT open any
    /// app-wide AI gate until a real BYO grant lands.
    var aiBYOKeyIntentPending: Bool {
        aiConsentStore.isBYOKeyIntentPending
    }

    /// v0.13 W4 — builds the ``BYOKeyEntryModel`` backing the inline "Own key"
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

    /// v0.13 — current on-device AI availability (Apple FoundationModels),
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

    /// v0.13 — true only when the on-device path can serve a request right now.
    var onDeviceAICapable: Bool {
        localLLMService.availability == .available
    }

    /// M1 (Audit-2) — true when the user picked `.online` but no provider is
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
        // v0.13 D5 — capability guard. Never persist a non-functional on-device
        // choice on an incapable device (pre-iOS-26, ineligible hardware, Apple
        // Intelligence off, model not downloaded): coerce to `.none` so the user
        // is never left with a silently-dead assistant. The picker already
        // hides/disables the card, but this closes the back door for any other
        // caller (deep links, re-onboarding after a device change).
        if mode == .onDevice, localLLMService.availability != .available {
            aiConsentStore.setMode(.none, activeProvider: resolvedAIProvider)
        } else {
            aiConsentStore.setMode(mode, activeProvider: resolvedAIProvider)
        }
        // v0.14.10 W-INSIGHTSDATA — keep the SERVER-side consent receipt in
        // lockstep with an explicit switch away from External AI (the store
        // revokes the device grant when the arms flip). See
        // `revokeServerAIConsentReceiptIfGrantDropped`.
        revokeServerAIConsentReceiptIfGrantDropped(wasGranted: wasGranted)
    }

    /// Flips the master opt-in. ON routes through the informed-consent flow
    /// (`AIConsentSheet` for the resolved provider, per Apple 5.1.2(i)) when a
    /// provider is configured; OFF revokes consent for the resolved provider so
    /// every gate closes immediately. When no provider is configured there is
    /// nothing to consent to — the request is a no-op and `remoteAIEnabled`
    /// stays false until a provider is wired (standalone calm-state).
    func setRemoteAIEnabled(_ enabled: Bool) {
        let provider = resolvedAIProvider
        if enabled {
            guard provider != .unconfigured else { return }
            // Reuse the explicit-prompt path so the shell presents the
            // informed-consent sheet; its `onAccept` calls `grant(for:)`.
            aiConsentStore.requestExplicitPrompt()
        } else {
            let wasGranted = aiConsentStore.isAnyProviderGranted()
            // Revoke the active provider (and, defensively, any other granted
            // provider) so a single OFF closes every remote-AI gate.
            for granted in AIProvider.allCases where granted != .unconfigured {
                aiConsentStore.revoke(for: granted)
            }
            // W-B186 COACH-1 (#24) — the server-managed scope has no concrete
            // provider, so the loop above can't reach it; revoke it explicitly.
            aiConsentStore.revokeServerManaged()
            // v0.14.10 W-INSIGHTSDATA — the master OFF is the explicit
            // revocation act, so the account-level server receipt falls too.
            revokeServerAIConsentReceiptIfGrantDropped(wasGranted: wasGranted)
        }
    }

    // MARK: - v0.14.10 W-INSIGHTSDATA — server-side consent receipts

    /// Thin wire wrapper for the server's SB-10 consent-receipt routes.
    /// Stateless — built fresh per call (mirrors `makeBYOKeyEntryModel`), so
    /// the main `AppContainer` init stays untouched.
    func makeConsentReceiptRepository() -> ConsentReceiptRepository {
        ConsentReceiptRepository(api: api)
    }

    /// Reconciles the SERVER-side AI consent receipt with the device grant.
    ///
    /// **Why (RCA Bug 2, per-metric Einschätzung gone).** Server v1.12.1
    /// enforcement (live since ~2026-06-05) requires an active
    /// `ConsentReceipt` before any LLM egress on a server-managed provider
    /// chain — and the default chain ends in the operator's global key, so the
    /// per-metric `*-status` family fails closed to the no-key fallback for an
    /// account with no receipt on file. The receipt API was built for the iOS
    /// client to call, but no client ever minted one, so every metric sub-page
    /// lost its Einschätzung prose (the overview Tagesbriefing survived via
    /// the deterministic narrative fallback).
    ///
    /// Called (a) right after a grant lands (the shell + Coach consent-sheet
    /// accept paths) and (b) once per shell mount while a grant exists — the
    /// launch pass heals installs whose grant predates this fix without any
    /// re-consent dance (the device grant record IS the user's informed
    /// consent act; the receipt re-asserts it server-side for the audit
    /// trail). No-op when no device grant exists or no server is reachable
    /// (best-effort; the next launch retries).
    func syncServerAIConsentReceipt() async {
        guard aiConsentStore.isAnyProviderGranted() else { return }
        let repo = makeConsentReceiptRepository()
        await repo.ensureFullConsentReceipt(artefact: aiConsentArtefact())
    }

    /// Fires the best-effort server-side master revoke when a mutation dropped
    /// the device grant (`wasGranted` captured before the mutation). Wired to
    /// the EXPLICIT user revocation choke points only (`setRemoteAIEnabled(false)`,
    /// `setAIMode` away from a granted External-AI arm) — deliberately NOT to
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
        // W-B186 COACH-1 (#24) — name the server-managed scope honestly in the
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
