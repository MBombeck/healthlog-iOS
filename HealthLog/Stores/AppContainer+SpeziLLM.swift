import Foundation

// v0.5.7 G.3 — composition-root accessors for the `LocalLLMService` +
// `CoachConversationStore` pair that drives the AskCoachSheet chat
// surface. The Spezi-specific SPI resolve (booted LLMRunner lookup)
// lives behind the `canImport(Spezi)` gate further down; the
// `LocalLLMService` + store are platform-agnostic and need to be
// reachable on every build configuration so the AskCoachSheet view
// compiles uniformly.

public extension AppContainer {
    /// Lazy-instantiated singleton `LocalLLMService`. First read on
    /// MainActor wires the FoundationModels availability probe;
    /// subsequent reads return the same instance so `availability`
    /// + `isReady` stay consistent across re-entries to the AskCoach
    /// sheet. Cached on the `LocalLLMBox` keyed by container identity
    /// so per-test containers get isolated lifetimes.
    var localLLMService: LocalLLMService {
        if let existing = LocalLLMBox.shared.service(for: self) {
            return existing
        }
        let created = LocalLLMService()
        LocalLLMBox.shared.set(created, for: self)
        // G.1 reserved the seam; the actual SpeziLLM LLMRunner resolve
        // path lives in the Spezi-only extension below. The call is a
        // no-op when Spezi is not linked into the build configuration.
        #if canImport(Spezi) && canImport(SpeziLLM)
            AppContainer.resolveSpeziLLMIfAvailable(service: created)
        #endif
        return created
    }

    /// **v0.5.7 G.5** — Lazy-instantiated `CoachChatStore`. Owns the
    /// dedicated SwiftData container that backs the coach chat
    /// transcript. Recovery-wrapped the same way the Outbox / Inbox /
    /// Cache stores are — corrupt store wipes + retries, falls back
    /// to in-memory so app launch never crashes here.
    var coachChatStore: CoachChatStore {
        if let existing = LocalLLMBox.shared.chatStore(for: self) {
            return existing
        }
        let created = CoachChatStore.makeWithRecovery()
        LocalLLMBox.shared.set(created, for: self)
        return created
    }

    /// Lazy-instantiated `CoachConversationStore`. Resolved on the
    /// first AskCoachSheet open; the transcript + `isResponding`
    /// state persist across sheet-dismissal within a single session
    /// (mirrors the `MiniCoachStore` cache pattern in
    /// `AppContainer+MiniCoach.swift`).
    ///
    /// **v0.5.7 G.5 — SwiftData hydrate on first read:** the store
    /// now takes a `CoachChatStore` + a `userIDProvider` closure, so
    /// the init hydrate populates `chat` from disk before the
    /// AskCoachSheet's first body pass. The closure reads the
    /// keychain `userID` on every call (no caching) so a logout +
    /// re-login under a different account in the same process surfaces
    /// the new partition transparently — `LocalLLMBox` clears the
    /// cached store on logout via `clearAll(for:)` so a fresh
    /// hydrate runs on the next access regardless.
    var coachConversationStore: CoachConversationStore {
        if let existing = LocalLLMBox.shared.store(for: self) {
            return existing
        }
        let keychainRef = keychain
        let persistence = coachChatStore
        // **v0.7.1 W-COACH-FALLBACK** — wire the server Coach so devices
        // without Apple Intelligence get a working conversation instead
        // of the kill-card. The service routes through the existing
        // APIClient primitives (`POST /api/insights/chat` SSE) — no new
        // write path, no APIClient edits.
        let serverService = CoachServerService(api: api)
        // Consent gate: the server path sends health data off-device, so
        // it must respect the same per-provider AI-consent gate the
        // `/api/insights/*` surfaces use. The feature flag is folded in
        // too — when the operator disabled the Coach surface the gate
        // returns `false` and the sheet surfaces the disabled state
        // rather than transmitting. Reads both lazily so a mid-session
        // provider switch / flag change is picked up on the next send.
        let consentStore = aiConsentStore
        let providerStore = aiProviderStore
        let flagsStore = featureFlagsStore
        // **v0.13 W4 — BYO-key arm.** The client-side device→provider service.
        // Its consent gate is the per-provider BYO grant (Apple 5.1.2(i)) read
        // from the same `AIConsentStore` — so `generate` throws before any
        // network call if consent is absent (fail-closed, never an un-consented
        // transmission). The key bytes live in `BYOKeyStore` (Keychain) and are
        // read inside the actor at call time. `consentGate` is `@Sendable` and
        // reads the keychain synchronously (no MainActor hop needed — the
        // grant check is a plain keychain read).
        let byoKeychain = keychain
        let byoService = BYOLLMService(
            keyStore: BYOKeyStore(keychain: byoKeychain),
            consentGate: { provider in
                byoKeychain.getString(forKey: AIConsentStore.byoKeyPrefix + provider.rawValue) == "granted"
            }
        )
        // **v0.5.7 G.4** — bind the privacy-first snapshot provider so
        // every `send(_:)` / `respondToLastUserTurn(prompt:)` enriches
        // the on-device LLM prompt with the local HealthSnapshot. The
        // closure captures `self` weakly so the store doesn't hold the
        // container alive past logout (logout already wipes the
        // `LocalLLMBox` cache via the standard cleanup path).
        let created = CoachConversationStore(
            service: localLLMService,
            snapshotProvider: { [weak self] in
                guard let self else { return .empty }
                return PrivacyFirstPromptBuilder.snapshot(from: self)
            },
            persistence: persistence,
            serverService: serverService,
            serverConsentGate: { [weak consentStore, weak providerStore, weak flagsStore] in
                guard let consentStore, let providerStore else { return false }
                // Operator can disable the Coach surface app-wide — never
                // transmit when the flag is off.
                if let flagsStore, !flagsStore.isEnabled(.assistantCoach) {
                    return false
                }
                guard let config = providerStore.config else { return false }
                return AppContainer.hasRequiredServerAIConsent(config: config, consentStore: consentStore)
            },
            byoService: byoService,
            // **v0.13 W4** — resolves the active BYO provider when the user's
            // mode is `.byoKey` (a grant exists). `nil` → the BYO arm is never
            // selected, so the on-device / server arms keep their behaviour.
            byoProviderResolver: { [weak consentStore] in
                consentStore?.activeBYOProvider()
            },
            userIDProvider: {
                keychainRef.getString(forKey: KeychainKey.userID)
                    ?? CoachChatMessage.standaloneUserID
            }
        )
        // **v0.11 marathon (AI-1)** — honour an explicit "External AI" (`.online`)
        // pick. When the user deliberately chose the server arm, it must win even
        // on an AI-capable device (mirroring the BYO precedence) instead of being
        // silently overridden by on-device. Reads `aiMode` lazily so a mid-session
        // mode switch is picked up on the next send. Consent stays fail-closed:
        // `serverConsentGate` above still gates every transmission.
        //
        // **v0152 W-COACH-CLEANUP (C3)** — the pick must win even BEFORE consent
        // has landed. The b198 on-device-reach widening (f4c90709) surfaced the
        // coach for an AI-capable device whenever `aiMode != .none || onDeviceReachable`,
        // so a user who selected External AI but whose grant hadn't yet landed
        // (`aiMode` resolves `.none` while an online intent is pending, or the
        // server-managed scope is available but not yet consented) fell through the
        // `AskCoachSheet` content branch to the on-device arm and was answered
        // LOCALLY — exactly against his explicit External-AI choice. By treating a
        // pending online intent / available server-managed scope as "prefers server"
        // too, `serverFallbackNeedsConsent` becomes true and the sheet shows the
        // consent CTA instead of silently routing on-device. Consent stays
        // fail-closed: `serverConsentGate` still gates every actual transmission, so
        // this only *prefers* the arm, it never bypasses the grant.
        created.prefersServerArm = { [weak consentStore] in
            guard let consentStore else { return false }
            // The grant landed → External AI is the active arm.
            if consentStore.aiMode == .online { return true }
            // External direction EXPRESSED but the grant hasn't resolved `.online`
            // yet (picked "External AI", consent still pending). This is the exact
            // b198 window the operator hit: he chose External, the grant hadn't
            // fully landed, so `aiMode` resolved `.none`, and the on-device-reach
            // surfacing answered him LOCALLY. Treating the pending online intent as
            // "prefers server" makes `serverFallbackNeedsConsent` win, so the sheet
            // shows the consent CTA instead of silently routing on-device. NOT set
            // for the `.onDevice` / unexpressed-`.none` user — they keep on-device.
            return consentStore.isOnlineIntentPending
        }
        // #30 — route an inline coach-turn cadence suggestion into the proactive
        // Insights card surface so the same suggestion is discoverable outside an
        // open chat. The overview store owns the opt-in / dismissed-set /
        // Focus-filter gating. Weak self so the conversation store never extends
        // the container's life past logout.
        created.onSuggestion = { [weak self] suggestion in
            self?.coachCadenceSuggestionsStore.present(suggestion)
        }
        LocalLLMBox.shared.set(created, for: self)
        return created
    }
}

/// MainActor-isolated cache for the lazily-instantiated LocalLLM
/// service + coach-conversation store + coach-chat persistence store.
/// Mirrors the `MiniCoachBox` pattern so the storage stays Swift-
/// native, strict-concurrency-clean, and per-container isolated.
@MainActor
final class LocalLLMBox {
    static let shared = LocalLLMBox()

    private var serviceByContainer: [ObjectIdentifier: LocalLLMService] = [:]
    private var storeByContainer: [ObjectIdentifier: CoachConversationStore] = [:]
    private var chatStoreByContainer: [ObjectIdentifier: CoachChatStore] = [:]

    private init() {}

    func service(for container: AppContainer) -> LocalLLMService? {
        serviceByContainer[ObjectIdentifier(container)]
    }

    func set(_ service: LocalLLMService, for container: AppContainer) {
        serviceByContainer[ObjectIdentifier(container)] = service
    }

    func store(for container: AppContainer) -> CoachConversationStore? {
        storeByContainer[ObjectIdentifier(container)]
    }

    func set(_ store: CoachConversationStore, for container: AppContainer) {
        storeByContainer[ObjectIdentifier(container)] = store
    }

    func chatStore(for container: AppContainer) -> CoachChatStore? {
        chatStoreByContainer[ObjectIdentifier(container)]
    }

    func set(_ chatStore: CoachChatStore, for container: AppContainer) {
        chatStoreByContainer[ObjectIdentifier(container)] = chatStore
    }

    /// **v0.5.7 G.5** — drop the cached conversation + chat stores for
    /// this container. Used by `AppContainer.handleLocalLogout` so the
    /// next AskCoach open re-hydrates against the new partition (or
    /// the standalone sentinel) rather than reusing the previous
    /// user's in-memory chat array. The `LocalLLMService` itself stays
    /// — the FoundationModels session is partition-agnostic, and the
    /// availability probe is expensive to redo for no reason.
    func clearStores(for container: AppContainer) {
        let key = ObjectIdentifier(container)
        storeByContainer[key] = nil
        chatStoreByContainer[key] = nil
    }
}

#if canImport(Spezi) && canImport(SpeziLLM)
    @_spi(APISupport) import Spezi
    import SpeziLLM

    extension AppContainer {
        /// Resolve the running `LLMRunner` module (booted by
        /// `HealthLogSpeziDelegate` behind the iOS-26 guard) and hand it
        /// to the supplied `LocalLLMService` — **v0.5.7 G.1 reserves the
        /// seam; the actual session-prepare wiring lands in G.3** when
        /// `AskCoachStore` opens its first `LLMLocalSession`.
        ///
        /// **Why a Spezi-scoped extension instead of an inline call in
        /// `AppContainer.init`?** Mirrors the
        /// `AppContainer+SpeziDevices.swift` rationale verbatim: the
        /// `@_spi(APISupport) import Spezi` + the SpeziLLM product would
        /// leak into the main `AppContainer.swift` file. Isolating the
        /// attach logic here keeps the SpeziLLM dependency surface
        /// explicit + grep-able + parallel to the SpeziDevices /
        /// SpeziStandard attachments.
        ///
        /// **G.3 status:** still a no-op for the LLMRunner resolve.
        /// G.3 wires the FoundationModels path via
        /// `LanguageModelSession` directly (no SpeziLLM `LLMRunner`
        /// detour) because `LocalLLMService.respond(prompt:)` already
        /// owns the per-invocation session. The SpeziLLM `LLMRunner`
        /// surface stays reachable for G.5+ when the streaming /
        /// session-hoist path needs the `LLMLocalSession` lifecycle
        /// SpeziLLM manages.
        ///
        /// Declared `static` so the call-site can run BEFORE
        /// `AppContainer.init` finishes initializing all stored
        /// properties (Swift's flow-sensitive init analysis disallows
        /// `self`-method-calls until every stored property is set),
        /// matching the `attachSpeziStandardUploader` /
        /// `resolveSpeziDevicesIfAvailable` patterns.
        ///
        /// Idempotent — safe to call multiple times; the inner Task only
        /// reads the module reference + logs.
        static func resolveSpeziLLMIfAvailable(
            service: LocalLLMService
        ) {
            // The probe intentionally does nothing with the service today —
            // keeping the parameter in the signature pins the call-site shape
            // so a future SpeziLLM session-handle pre-warm is a single-file
            // change once the LLMRunner plumbing is in place.
            _ = service
            Task {
                guard let spezi = SpeziAppDelegate.spezi else {
                    HLLog.healthKit
                        .info("Spezi not booted — SpeziLLM resolve skipped")
                    return
                }
                // The `module(_:)` lookup is type-erased upstream so we
                // ask for the LLMRunner directly. On iOS 18 / 25 (the
                // FoundationModels-ineligible floor) the
                // `HealthLogSpeziDelegate.configuration` builder skips
                // the `LLMRunner { LLMLocalPlatform() }` block entirely,
                // so the lookup returns nil — the info log captures the
                // skip without escalating to a warning.
                guard spezi.module(LLMRunner.self) != nil else {
                    HLLog.healthKit
                        .info("LLMRunner module not registered — resolve skipped (iOS 26+ only)")
                    return
                }
                HLLog.healthKit
                    .info("SpeziLLM LLMRunner module reachable (G.1 scaffolding)")
            }
        }
    }
#endif
