import Foundation
import Observation

/// Task #53 — the single source-of-truth for *whether* and *which* assistant
/// the user has chosen. Generalises Task #49's `remoteAIEnabled` boolean into
/// a three-way pick presented identically in onboarding and Settings:
///
/// - ``none`` — no assistant surfaces at all (privacy-first default for an
///   undecided user). Every AI gate stays closed; nothing is generated and
///   nothing leaves the device.
/// - ``onDevice`` — local generation via Apple Foundation Models
///   (`LocalLLMService` / `OnDeviceBriefingService` / `TrendObservationsService`).
///   Works offline + standalone; nothing is transmitted, so no off-device
///   consent is required. Persisted as a UI-pref (UserDefaults), since it is a
///   pure local-generation switch the server never needs to know about.
/// - ``byoKey`` — v0.13 **bring-your-own-key**, client-side: the user supplies
///   their own LLM API key and requests go **directly device→provider** (never
///   through our server). The key lives in the device Keychain (`BYOKeyStore`,
///   W2); the per-provider BYO consent grant (Apple 5.1.2(i) — health data still
///   leaves the device to a third party) IS the `.byoKey` state. Available in
///   BOTH operating modes (standalone AND server-connected).
/// - ``online`` — the server provider path (Task #50 pre-generated texts +
///   online Coach), surfaced as **"External AI"** in v0.13's matrix. Requires a
///   configured provider AND the per-provider informed-consent grant (Apple
///   5.1.2(i)); the grant record IS the `.online` state, so a prior Task #49
///   grant reads back as `.online` with no migration. Only reachable in
///   server-connected mode (a standalone user has no server provider to grant).
///
/// **v0.13 matrix:** the operating mode (standalone vs server) is a *second*
/// axis read from `BackendAvailability.mode` — NOT duplicated into this enum.
/// Standalone offers {none, onDevice?, byoKey}; server adds {online}. On-device
/// is further capability-gated (`LocalLLMService.availability`). Keeping mode
/// out of the enum is what lets `AIConsentStore` stay the single source of truth
/// without forking a parallel system.
public enum AIMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case onDevice
    case byoKey
    case online

    public var id: String {
        rawValue
    }
}

/// AI-Consent-Gate (QA3 BLOCKER 2 / S7). Per Apple Guideline 5.1.2(i)
/// — Nov 2025 amendment — apps that send health data to off-device LLMs
/// must obtain explicit, informed consent BEFORE the first transmission,
/// per active LLM provider. Switching providers invalidates the prior
/// consent and requires a fresh prompt.
///
/// Persists consent state in Keychain (not UserDefaults — survives a
/// Settings → "Reset Privacy" sweep cleanly and stays encrypted at rest
/// alongside auth tokens). Keys are per-provider so a user who consented
/// to Anthropic but not OpenAI gets the right gate when switching.
///
/// Surface is `@MainActor` for SwiftUI; the underlying Keychain write is
/// synchronous so no `async` needed.
///
/// **v0.5.0+ PB1-Reconcile (H3):** decline is now persistent per provider
/// (Keychain entry `ai-consent-declined.<provider>` holds the ISO-8601
/// timestamp of the last decline). `AuthenticatedShell.evaluateConsentGate`
/// reads it via ``wasDeclined(for:)`` and suppresses auto-presentation of
/// the sheet — otherwise every tab switch nag-loops the user, which is a
/// dark pattern and contradicts the "Insights tab stays dim until the user
/// toggles consent" contract. The sheet only re-fires on (a) provider
/// switch (`revokeAllOthers` clears the declined flag for the new active
/// provider), (b) explicit re-prompt from Settings → KI toggle, (c)
/// explicit re-prompt from a UI CTA. `grant(for:)` also clears the
/// declined flag — a granted consent supersedes a prior decline.
@MainActor
@Observable
public final class AIConsentStore {
    /// Current provider the user is configured against — read from
    /// AIProviderStore at gate-check time. Source of truth for which
    /// keychain entry to consult.
    public private(set) var lastCheckedProvider: AIProvider?
    public private(set) var lastResult: Bool = false

    /// v0.14.7 COACH-redesign — monotonic revision bumped by EVERY mutator that
    /// changes an input ``aiMode`` resolves from (the on-device UserDefaults flag,
    /// the per-provider Keychain grants, the BYO grants, the pending intents).
    ///
    /// `aiMode` itself stays *computed* from external storage (UserDefaults +
    /// Keychain), neither of which Observation tracks — so a surface that reads
    /// only `aiMode` never re-renders when the user flips the mode (the recurring
    /// "consent did nothing until app restart" bug). This stored, `@Observable`-
    /// tracked counter is the dependency anchor. Pure UI-coupling primitive;
    /// nothing on the wire depends on it.
    ///
    /// **N5.1 (v0.14.8 tech audit):** every externally-backed getter
    /// (``hasConsent(for:)``, ``aiMode``, ``isAnyProviderGranted()``,
    /// ``hasBYOConsent(for:)``, the intent/on-device flags, ``declinedAt(for:)``)
    /// now reads `revision` itself via `trackRevisionRead()`, so a SwiftUI body
    /// is Observation-tracked by merely calling the getter — no manual
    /// `revision` read at the call site is required anymore.
    public private(set) var revision: Int = 0

    /// Bumps ``revision`` so any Observation-tracking body re-evaluates after a
    /// mode-input mutation. Wrapping-safe (`&+`); never on a hot path.
    private func bumpRevision() {
        revision &+= 1
    }

    /// N5.1 (v0.14.8 tech audit) — Observation dependency anchor for every
    /// externally-backed getter. ``hasConsent(for:)``, ``aiMode`` & friends
    /// resolve from Keychain/UserDefaults, neither of which Observation can
    /// track — so a SwiftUI body gating ONLY on those getters used to render
    /// stale until relaunch when a grant landed asynchronously (the
    /// RCA-ai-consent-flow staleness class). Reading the stored ``revision``
    /// here registers the calling body as a dependent, so any later
    /// ``bumpRevision()`` (grant / revoke / decline / intent flip) invalidates
    /// it. Call sites therefore no longer need to read `revision` manually.
    private func trackRevisionRead() {
        _ = revision
    }

    /// Monotonically increasing token bumped by ``requestExplicitPrompt()``.
    /// `AuthenticatedShell` observes this via `.onChange(of:)` so any surface
    /// (Settings KI-toggle, AI-feature CTA) can ask the shell to present
    /// `AIConsentSheet` without holding a reference to the shell or fighting
    /// with the wasDeclined() auto-suppression. Pure UI-coupling primitive;
    /// nothing on the wire depends on it.
    public private(set) var explicitPromptToken: Int = 0

    private let keychain: KeychainStoring
    private let defaults: UserDefaults
    /// Keychain account prefix for the per-provider grant record
    /// (`ai-consent.<provider>`). `internal` so the logout cascade
    /// (`AppContainer+Logout`) and the 401-bridge keychain wipe
    /// (`AuthService.deleteAccount`) can wipe the same entries this store
    /// writes, keeping the consent record in lockstep with the auth bundle
    /// (v0.12 W1 — security finding W1-1, Apple 5.1.2(i)). `nonisolated` so the
    /// `AuthService` actor can read the constant synchronously for its direct
    /// account-deletion keychain wipe — it's an immutable `String` literal.
    nonisolated static let keyPrefix = "ai-consent."
    /// Keychain account prefix for the per-provider "user actively declined"
    /// timestamp marker (`ai-consent-declined.<provider>`). Wiped alongside
    /// the grant on every logout path so a fresh sign-in starts neutral.
    nonisolated static let declinedKeyPrefix = "ai-consent-declined."

    /// v0.13 — Keychain account prefix for the per-`BYOProviderID` **BYO-key
    /// consent** grant (`byo-consent.<provider>`). Mirrors ``keyPrefix`` exactly:
    /// the grant record IS the `.byoKey` state. Separate namespace from
    /// `ai-consent.` because the BYO path covers providers the server-side
    /// `AIProvider` enum lacks (Gemini, OpenAI-compatible) and the key lives on
    /// the device, not the server. `nonisolated` so the logout/delete-account
    /// keychain cascade can wipe these in lockstep with the rest of the bundle.
    nonisolated static let byoKeyPrefix = "byo-consent."

    /// W-B186 COACH-1 (#24) — Keychain account for the **server-managed** AI
    /// consent grant. The operator's server/admin-managed provider exposes NO
    /// per-user provider (`GET /api/user/ai-provider` returns `provider: null`,
    /// `managedBy: "server"`), so there is no concrete ``AIProvider`` to key
    /// consent against — `.unconfigured` no-ops. This stable sentinel scope IS
    /// the `.online` grant for the server-managed case: granting it flips
    /// ``aiMode`` to `.online` and makes every Coach surface visible + usable.
    /// The server forwards to its own provider, so the user's data flow is
    /// server-mediated (the provider-agnostic `AIConsentSheet.Context.serverMediated`
    /// copy already covers it). `nonisolated` so the logout/delete-account
    /// keychain cascade wipes it in lockstep with the per-provider grants.
    nonisolated static let serverManagedScope = "ai-consent.__server_managed__"

    /// W-B186 COACH-1 — decline marker for the server-managed scope, mirroring
    /// ``declinedKeyPrefix`` per concrete provider so a single decline silences
    /// the shell auto-gate without nag-looping. Wiped on logout + on grant.
    nonisolated static let serverManagedDeclinedKey = "ai-consent-declined.__server_managed__"

    /// Task #53 — UserDefaults key backing the ``onDevice`` arm of ``AIMode``.
    /// On-device generation sends nothing off-device, so a UI-pref flag (per
    /// PROJECT_GUIDE.md: UserDefaults for UI-prefs only) is the right home — no
    /// Keychain round-trip, no server sync needed. The `.online` arm stays in
    /// the per-provider Keychain grant; the two are mutually exclusive (setting
    /// one clears the other) so ``aiMode`` resolves a single coherent choice.
    static let onDeviceDefaultsKey = "hl.ai.onDeviceEnabled"

    /// M1 (Audit-2) — UI-pref key backing the **pending `.online` intent**: the
    /// user picked Online but no provider is configured yet, so no grant could
    /// land and ``aiMode`` legitimately stays `.none`. Persisting the *intent*
    /// (UserDefaults — pure UI-pref, never on the wire) lets the Settings picker
    /// keep showing Online + the add-provider hint stay visible across
    /// navigation, instead of silently snapping back to None. It deliberately
    /// does NOT feed ``aiMode`` / ``remoteAIEnabled`` — the app-wide gates stay
    /// closed until a real grant lands, so nothing leaks (never an empty box).
    /// Cleared the moment a grant lands (``grant(for:)``) or the user picks
    /// `.none` / `.onDevice` (``setMode(_:activeProvider:requestOnlineConsent:)``).
    static let onlineIntentDefaultsKey = "hl.ai.onlineIntentPending"

    /// v0.13 — UI-pref key backing the **pending `.byoKey` intent**: the user
    /// picked "Own key" in the picker but has not yet saved a key + accepted the
    /// BYO consent, so no grant could land and ``aiMode`` legitimately stays at
    /// its prior value. Persisting the intent (UserDefaults — pure UI-pref) keeps
    /// the picker showing "Own key" selected and the inline key-entry card
    /// expanded across navigation, mirroring ``onlineIntentDefaultsKey``. It does
    /// NOT feed ``aiMode`` — the app-wide gates stay on the prior arm until a real
    /// ``grantBYO(for:)`` lands (never an empty box). Cleared the moment a BYO
    /// grant lands or the user picks another arm.
    static let byoKeyIntentDefaultsKey = "hl.ai.byoKeyIntentPending"

    public init(keychain: KeychainStoring, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// Returns true if the user has granted consent for the active
    /// provider. The gate should call this synchronously before any
    /// `/api/insights/*` request; if false, present `AIConsentSheet`
    /// and only proceed on the sheet's `onAccept` callback.
    public func hasConsent(for provider: AIProvider) -> Bool {
        trackRevisionRead() // N5.1 — Keychain read is untracked; anchor on `revision`.
        guard provider != .unconfigured else { return true } // no provider → no traffic anyway
        let key = Self.keyPrefix + provider.rawValue
        let stored = keychain.getString(forKey: key) ?? ""
        let granted = stored == "granted"
        lastCheckedProvider = provider
        lastResult = granted
        return granted
    }

    /// Task #49 — true when the user has granted remote-AI consent for **any**
    /// real (non-`.unconfigured`) provider. Backs the single Settings master
    /// toggle "Remote-KI-Tools aktivieren" and every remote-AI render gate
    /// (assessment read, ✦ Coach surfaces, briefing/overview insights), so a
    /// prior grant made through `AIConsentSheet` is preserved as the ON state
    /// without a parallel flag. Reads the per-provider Keychain entries
    /// directly — the grant record is the single source of truth. Cheap: a
    /// handful of synchronous Keychain reads, never on a hot path.
    public func isAnyProviderGranted() -> Bool {
        trackRevisionRead() // N5.1
        // W-B186 COACH-1 (#24) — the server-managed scope grant counts as a
        // remote-AI grant: it has no concrete provider but the Coach + per-metric
        // surfaces are served by the operator's server key, and the `ai_full`
        // ConsentReceipt is minted off this exact grant.
        if hasServerManagedConsent() { return true }
        return AIProvider.allCases.contains { provider in
            provider != .unconfigured
                && keychain.getString(forKey: Self.keyPrefix + provider.rawValue) == "granted"
        }
    }

    /// Bug 3 (v0.14.8) — the single granted server provider, or `nil` when none
    /// is granted. `grant`/`setMode` keep at most one server grant active, so the
    /// `first` match is the active provider. Backs the Settings disable toggle so
    /// it can key its revoke on the *granted* provider even when the live server
    /// `config` resolves `.unconfigured` (not yet loaded) — disabling must always
    /// be reachable. Cheap synchronous Keychain reads, never on a hot path.
    public func activeGrantedProvider() -> AIProvider? {
        trackRevisionRead() // N5.1
        return AIProvider.allCases.first { provider in
            provider != .unconfigured
                && keychain.getString(forKey: Self.keyPrefix + provider.rawValue) == "granted"
        }
    }

    // MARK: - W-B186 COACH-1 (#24) — server-managed AI consent

    /// True when the user has granted consent for the **server-managed** AI
    /// scope (the admin/operator-managed provider with no per-user key). The
    /// grant record IS the `.online` state for the server-managed case, exactly
    /// as a per-provider grant is for a user-configured provider. Reads the
    /// sentinel Keychain entry directly; cheap, never on a hot path.
    public func hasServerManagedConsent() -> Bool {
        trackRevisionRead() // N5.1 — Keychain read is untracked; anchor on `revision`.
        return keychain.getString(forKey: Self.serverManagedScope) == "granted"
    }

    /// Records the informed-consent grant for the server-managed AI scope.
    /// Called from the shell + Coach consent-sheet accept paths when the server
    /// reports `aiAvailable == true` && `managedBy == "server"` (#24). Mirrors
    /// ``grant(for:)``: clears any prior decline, drops the pending online
    /// intent, bumps the revision so gated bodies re-render. Per the #24 thread
    /// the caller ALSO mints the server-side `ai_full` ConsentReceipt — granting
    /// here does not bypass that, it is the device-side half of the same act.
    public func grantServerManaged() {
        do {
            // The grant record IS the off-device-transmission gate (Apple
            // 5.1.2(i)) — a persist failure must NOT report success; leave the
            // scope un-granted so the next gate re-prompts (v0162).
            try keychain.setString("granted", forKey: Self.serverManagedScope)
        } catch {
            HLLog.security.error(
                "AI consent grant (server-managed) failed to persist — scope left un-granted: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            lastResult = false
            bumpRevision()
            return
        }
        try? keychain.remove(forKey: Self.serverManagedDeclinedKey)
        setOnlineIntentPending(false)
        lastResult = true
        bumpRevision()
        HLLog.security.info("AI consent granted for server-managed scope")
    }

    /// User declined the server-managed consent sheet. Persists the decline so
    /// the shell auto-gate does not nag-loop on every tab switch; the explicit
    /// re-engage CTA (`requestExplicitPrompt`) still re-opens the choice.
    public func declineServerManaged() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? keychain.setString(timestamp, forKey: Self.serverManagedDeclinedKey)
        lastResult = false
        bumpRevision()
        HLLog.security.info("AI consent declined for server-managed scope")
    }

    /// True when the server-managed scope was declined and not since granted.
    /// The shell consults this before auto-presenting the consent sheet.
    public func wasServerManagedDeclined() -> Bool {
        trackRevisionRead() // N5.1
        return keychain.getString(forKey: Self.serverManagedDeclinedKey) != nil
    }

    /// Revokes the server-managed consent grant + its decline marker, returning
    /// the scope to neutral. Used by the master-off path and the per-provider
    /// revoke sweep so a single "off" closes the server-managed gate too.
    public func revokeServerManaged() {
        try? keychain.remove(forKey: Self.serverManagedScope)
        try? keychain.remove(forKey: Self.serverManagedDeclinedKey)
        lastResult = false
        bumpRevision()
        HLLog.security.info("AI consent revoked for server-managed scope")
    }

    // MARK: - v0.13 — BYO-key (client-side device→provider) consent

    /// True when the user has granted BYO-key consent for the given provider.
    /// The grant record IS the `.byoKey` arm's state — mirrors
    /// ``hasConsent(for:)`` for the server path. The actual API key lives in
    /// `BYOKeyStore` (Keychain, W2); this is the consent half required by Apple
    /// 5.1.2(i) before any health data leaves the device to a third party.
    public func hasBYOConsent(for provider: BYOProviderID) -> Bool {
        trackRevisionRead() // N5.1
        return keychain.getString(forKey: Self.byoKeyPrefix + provider.rawValue) == "granted"
    }

    /// True when ANY BYO provider is granted — backs the `.byoKey` resolution in
    /// ``aiMode`` and the master gates, exactly as ``isAnyProviderGranted()``
    /// backs `.online`. Cheap synchronous Keychain reads, never on a hot path.
    public func isAnyBYOKeyGranted() -> Bool {
        BYOProviderID.allCases.contains { hasBYOConsent(for: $0) }
    }

    /// The single granted BYO provider, or `nil` when none is granted. ``grantBYO``
    /// enforces one-active-at-a-time, so the `first` match is the active provider.
    /// Backs the Coach BYO arm's provider resolution.
    public func activeBYOProvider() -> BYOProviderID? {
        BYOProviderID.allCases.first { hasBYOConsent(for: $0) }
    }

    /// Records the BYO-key informed-consent grant for `provider`. Called by the
    /// inline key-entry flow (W3) AFTER a key has been saved to `BYOKeyStore` and
    /// the user accepted the BYO consent copy. Enforces single-arm exclusivity:
    /// granting BYO revokes every server grant and clears the on-device flag, so
    /// `aiMode` resolves a single coherent choice. Other BYO providers are
    /// revoked too — one active BYO provider at a time.
    public func grantBYO(for provider: BYOProviderID) {
        do {
            // audit-release 05 C-3 — the BYO grant record IS the off-device-
            // transmission gate (Apple 5.1.2(i): health data leaves the device
            // to a third party). A persist failure must NOT report success —
            // otherwise the picker shows a phantom "granted" with no backing
            // record. Persist FIRST, then enforce single-arm exclusivity only on
            // success, so a failed write never tears down a working arm behind a
            // grant that didn't land (mirrors ``grant(for:)`` / ``grantServerManaged()``).
            try keychain.setString("granted", forKey: Self.byoKeyPrefix + provider.rawValue)
        } catch {
            // Provider enum raw value — operator-grade.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.security.error(
                "BYO-key consent grant failed to persist — provider left un-granted \(provider.rawValue, privacy: .public): \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            lastResult = false
            bumpRevision()
            return
        }
        for other in BYOProviderID.allCases where other != provider {
            revokeBYO(for: other)
        }
        // Switching to client-side BYO must stop all server-mediated AI traffic
        // and the on-device arm, keeping the arms mutually exclusive.
        setOnDeviceEnabled(false)
        setOnlineIntentPending(false)
        setBYOKeyIntentPending(false)
        for granted in AIProvider.allCases where granted != .unconfigured {
            revoke(for: granted)
        }
        // W-B186 COACH-1 — switching to client-side BYO must also drop any
        // server-managed grant so the arms stay mutually exclusive.
        revokeServerManaged()
        lastResult = true
        bumpRevision()
        // Provider enum raw value — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.security.info("BYO-key consent granted for \(provider.rawValue, privacy: .public)")
    }

    /// Revokes the BYO-key consent grant for `provider`. The key bytes in
    /// `BYOKeyStore` are cleared separately by the caller (W2/W3) so a revoke
    /// here is purely the consent half.
    public func revokeBYO(for provider: BYOProviderID) {
        try? keychain.remove(forKey: Self.byoKeyPrefix + provider.rawValue)
        bumpRevision()
    }

    /// Revokes every BYO-key consent grant. Used when the user switches to a
    /// different arm (`.none` / `.onDevice` / `.online`).
    public func revokeAllBYO() {
        for provider in BYOProviderID.allCases {
            revokeBYO(for: provider)
        }
    }

    /// v0.13 — true when the user picked "Own key" but has not yet saved a key +
    /// accepted consent. Read ONLY by the picker (keep "Own key" selected) and
    /// the inline entry card (stay expanded). Does NOT feed ``aiMode``.
    public var isBYOKeyIntentPending: Bool {
        trackRevisionRead() // N5.1
        return defaults.bool(forKey: Self.byoKeyIntentDefaultsKey)
    }

    /// Sets/clears the pending-`.byoKey`-intent UI-pref.
    public func setBYOKeyIntentPending(_ pending: Bool) {
        defaults.set(pending, forKey: Self.byoKeyIntentDefaultsKey)
        bumpRevision()
    }

    // MARK: - Task #53 — three-way AI mode

    /// True when the on-device assistant arm is enabled (UI-pref flag). Reads
    /// the UserDefaults flag directly so the resolution stays a single source
    /// of truth. Independent of any provider grant — on-device transmits
    /// nothing, so it never touches the consent Keychain entries.
    public var isOnDeviceEnabled: Bool {
        trackRevisionRead() // N5.1
        return defaults.bool(forKey: Self.onDeviceDefaultsKey)
    }

    /// M1 (Audit-2) — true when the user picked `.online` while no provider was
    /// configured, so the choice is held as a pending intent. Read ONLY by the
    /// Settings AI picker (to keep showing Online) and the add-provider hint (to
    /// stay visible). Intentionally NOT consulted by ``aiMode`` — the app-wide
    /// gates resolve `.none` until a real grant lands.
    public var isOnlineIntentPending: Bool {
        trackRevisionRead() // N5.1
        return defaults.bool(forKey: Self.onlineIntentDefaultsKey)
    }

    /// Sets/clears the pending-`.online`-intent UI-pref. Used by
    /// ``setMode(_:activeProvider:requestOnlineConsent:)`` and ``grant(for:)``;
    /// exposed for tests.
    public func setOnlineIntentPending(_ pending: Bool) {
        defaults.set(pending, forKey: Self.onlineIntentDefaultsKey)
        bumpRevision()
    }

    /// The currently chosen ``AIMode``. Resolution ladder:
    /// `.byoKey` (any client BYO grant) → `.online` (any server provider grant)
    /// → `.onDevice` (local flag) → `.none`. `setMode` / `grantBYO` / `grant`
    /// keep the arms mutually exclusive so at most one is ever active; the
    /// ladder order is a *defensive* tiebreak (client-key-wins, the most-private
    /// configured arm) for the theoretically-impossible both-granted state.
    ///
    /// Back-compat invariant preserved: `remoteAIEnabled == (aiMode == .online)`
    /// still holds because granting BYO revokes all server grants (and vice
    /// versa), so the two never coexist in practice.
    public var aiMode: AIMode {
        trackRevisionRead() // N5.1 — resolves from Keychain + UserDefaults only.
        if isAnyBYOKeyGranted() {
            return .byoKey
        }
        if isAnyProviderGranted() {
            return .online
        }
        if isOnDeviceEnabled {
            return .onDevice
        }
        return .none
    }

    /// Sets the local on-device flag without touching provider consent. Used by
    /// ``setMode(_:requestOnlineConsent:)``; exposed for tests + direct toggles.
    public func setOnDeviceEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.onDeviceDefaultsKey)
        lastResult = enabled
        bumpRevision()
    }

    /// Per-provider "user actively declined" timestamp. `nil` when the
    /// provider has never been declined (or was declined and then
    /// later granted — `grant(for:)` clears the flag). Drives the
    /// nag-loop guard in `AuthenticatedShell.evaluateConsentGate`.
    public func declinedAt(for provider: AIProvider) -> Date? {
        trackRevisionRead() // N5.1
        guard provider != .unconfigured else { return nil }
        let key = Self.declinedKeyPrefix + provider.rawValue
        guard let stored = keychain.getString(forKey: key) else { return nil }
        return ISO8601DateFormatter().date(from: stored)
    }

    /// Convenience predicate — true when the user has declined this
    /// provider at any point and has not yet explicitly granted it.
    /// `evaluateConsentGate` consults this BEFORE auto-presenting the
    /// sheet so a single Decline silences the automatic prompt until
    /// the user explicitly re-engages (Settings toggle, AI feature CTA).
    public func wasDeclined(for provider: AIProvider) -> Bool {
        declinedAt(for: provider) != nil
    }

    /// User tapped "Akzeptieren" on the sheet. Persists "granted" for
    /// the specific provider and clears any prior decline (granting
    /// supersedes — the user can change their mind in either direction).
    public func grant(for provider: AIProvider) {
        guard provider != .unconfigured else {
            // Bug 2 (v0.14.8) — observability for the silent no-op. A grant for
            // `.unconfigured` has no provider scope to write against, so it
            // returns without persisting. That is exactly the shape that drove
            // the "I accepted but it still says consent missing" trust break:
            // the gate fired before the provider config loaded, captured
            // `.unconfigured`, and accept did nothing. Callers MUST guard
            // `.unconfigured` upstream (shell + Coach both do now); this log
            // surfaces any stray no-op instead of swallowing it.
            HLLog.security.warning("AI consent grant skipped — provider .unconfigured (no scope to grant)")
            return
        }
        let key = Self.keyPrefix + provider.rawValue
        do {
            // Same 5.1.2(i) contract as ``grantServerManaged()`` — a persist
            // failure must NOT be logged as success; leave the provider
            // un-granted so the gate re-prompts (v0162).
            try keychain.setString("granted", forKey: key)
        } catch {
            HLLog.security.error(
                "AI consent grant failed to persist — provider left un-granted: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            lastCheckedProvider = provider
            lastResult = false
            bumpRevision()
            return
        }
        // Clearing the declined flag is important — otherwise the next
        // tab switch would still suppress auto-presentation needlessly
        // and the user could not re-engage via the standard CTA flow.
        try? keychain.remove(forKey: Self.declinedKeyPrefix + provider.rawValue)
        // M1 — a real grant fulfils any pending `.online` intent; aiMode now
        // resolves `.online` via the grant itself, so drop the stale intent.
        setOnlineIntentPending(false)
        lastCheckedProvider = provider
        lastResult = true
        bumpRevision()
        // Provider enum raw value — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.security.info("AI consent granted for \(provider.rawValue, privacy: .public)")
    }

    /// User tapped "Ablehnen" on the sheet. Persists the decline
    /// timestamp so subsequent tab-switch gate evaluations do not
    /// nag-loop the user. Does NOT clear an existing grant — decline
    /// is a "do not auto-present" signal, not a revocation. The user
    /// must use ``revoke(for:)`` (Settings toggle off) to clear an
    /// active grant.
    public func decline(for provider: AIProvider) {
        guard provider != .unconfigured else { return }
        let key = Self.declinedKeyPrefix + provider.rawValue
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? keychain.setString(timestamp, forKey: key)
        lastCheckedProvider = provider
        lastResult = false
        // N5.1 — `wasDeclined`/`declinedAt` output changed; invalidate readers.
        bumpRevision()
        // Provider enum raw value — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.security.info("AI consent declined for \(provider.rawValue, privacy: .public)")
    }

    /// User revoked from Settings. Clears both the grant AND the
    /// declined marker — the user explicitly returned to a neutral
    /// state and the next CTA flow can re-present the sheet without
    /// being suppressed. Future insights calls hit the gate again
    /// and fall back to deterministic local-only output.
    public func revoke(for provider: AIProvider) {
        let key = Self.keyPrefix + provider.rawValue
        try? keychain.remove(forKey: key)
        try? keychain.remove(forKey: Self.declinedKeyPrefix + provider.rawValue)
        lastCheckedProvider = provider
        lastResult = false
        bumpRevision()
        // Provider enum raw value — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.security.info("AI consent revoked for \(provider.rawValue, privacy: .public)")
    }

    /// Provider changed (user switched Anthropic → OpenAI). Old consent
    /// is irrelevant — wipe the prior provider's record so a future
    /// switch-back also re-prompts. Per App Store Review: each provider
    /// switch is a new data-flow contract the user agrees to.
    public func revokeAllOthers(keep: AIProvider) {
        for provider in AIProvider.allCases where provider != keep && provider != .unconfigured {
            revoke(for: provider)
        }
    }

    /// Asks `AuthenticatedShell` to present `AIConsentSheet` regardless of
    /// the wasDeclined() auto-suppression. The shell observes
    /// ``explicitPromptToken`` via `.onChange(of:)` and decides whether to
    /// actually present (no-op when already granted or provider is
    /// `.unconfigured`). Use this from any AI-feature CTA that wants to
    /// re-engage a user who previously declined.
    public func requestExplicitPrompt() {
        explicitPromptToken &+= 1
    }

    /// Task #53 — apply a three-way ``AIMode`` choice from the onboarding step
    /// or the Settings card. The arms are mutually exclusive:
    ///
    /// - `.none` — clears the on-device flag AND revokes every provider grant,
    ///   so every AI gate closes immediately.
    /// - `.onDevice` — sets the local flag and revokes every provider grant
    ///   (a switch away from online must stop off-device traffic). No consent
    ///   sheet — nothing leaves the device.
    /// - `.byoKey` (v0.13) — clears the on-device flag and holds a pending
    ///   intent; the inline key-entry card (W3) saves the key + calls
    ///   ``grantBYO(for:)``, which is what actually flips `aiMode` to `.byoKey`
    ///   and revokes the other arms. Existing server grants are left intact until
    ///   that grant lands, so tapping the card never destroys a working setup.
    /// - `.online` — clears the on-device flag and (when `requestOnlineConsent`
    ///   is true and `activeProvider` is a real provider) fires the informed-
    ///   consent prompt via ``requestExplicitPrompt()``; the sheet's `onAccept`
    ///   calls ``grant(for:)`` which is what actually flips `aiMode` to
    ///   `.online`. When no provider is configured the choice is recorded as an
    ///   *intent* only — the caller routes the user to the add-provider path —
    ///   and `aiMode` stays `.none` until a grant lands (never an empty box).
    ///
    /// Returns the mode resolved *synchronously* after the call. For `.online`
    /// with a pending consent sheet this is still the pre-grant value; the UI
    /// observes the grant landing through `AIConsentStore`'s `@Observable`
    /// tracking.
    @discardableResult
    func setMode(
        _ mode: AIMode,
        activeProvider: AIProvider,
        requestOnlineConsent: Bool = true
    ) -> AIMode {
        switch mode {
        case .none:
            setOnDeviceEnabled(false)
            setOnlineIntentPending(false)
            setBYOKeyIntentPending(false)
            revokeAllBYO()
            for provider in AIProvider.allCases where provider != .unconfigured {
                revoke(for: provider)
            }
            // W-B186 COACH-1 — `.none` closes EVERY remote-AI gate, server-managed included.
            revokeServerManaged()
        case .onDevice:
            setOnDeviceEnabled(true)
            setOnlineIntentPending(false)
            setBYOKeyIntentPending(false)
            revokeAllBYO()
            for provider in AIProvider.allCases where provider != .unconfigured {
                revoke(for: provider)
            }
            // W-B186 COACH-1 — switching to on-device stops all server-mediated AI.
            revokeServerManaged()
        case .byoKey:
            // v0.13 — pick "Own key". Like `.online`, the actual grant lands
            // later: the inline key-entry card (W3) saves the key to BYOKeyStore
            // and calls ``grantBYO(for:)``, which is what flips `aiMode` to
            // `.byoKey` and revokes the other arms. Here we only switch away from
            // the on-device arm and hold the pending intent so the picker keeps
            // "Own key" selected + the entry card expanded (mirrors the M1 online
            // intent). Existing server grants are left untouched until a real BYO
            // grant lands, so merely tapping the card never destroys a working
            // configuration (never an empty box).
            setOnDeviceEnabled(false)
            setOnlineIntentPending(false)
            setBYOKeyIntentPending(true)
        case .online:
            setOnDeviceEnabled(false)
            setBYOKeyIntentPending(false)
            revokeAllBYO()
            if activeProvider != .unconfigured {
                if requestOnlineConsent {
                    // A provider exists and we CAN host the consent sheet → kick
                    // off the informed-consent prompt; its onAccept calls
                    // grant(for:), which flips aiMode to .online and clears the
                    // pending intent. No lingering intent needed once a grant lands.
                    setOnlineIntentPending(false)
                    requestExplicitPrompt()
                } else if !isAnyProviderGranted() {
                    // Bug 1 (RCA v0.14.8) — onboarding context: the shell isn't
                    // mounted so we deliberately DON'T fire the sheet
                    // (`requestOnlineConsent == false`). Previously this branch
                    // cleared the online intent even though no grant landed, so the
                    // operator's onboarding pick evaporated and Settings later fired
                    // the *first* real consent — perceived as a second, unrelated
                    // nag ("doppelt gemoppelt"). Record the choice as a pending
                    // intent instead, so `displayedMode` shows .online and Settings
                    // can fulfil it once, in context. The intent is cleared only by
                    // an actual grant(for:) or an explicit switch to another arm.
                    // (No clobber when a grant already exists — that already
                    // resolves .online, so the intent is moot.)
                    setOnlineIntentPending(true)
                }
            } else {
                // M1 — no provider yet: hold the choice as a pending intent so
                // the Settings picker keeps showing Online + the add-provider
                // hint stays visible, instead of snapping back to None. aiMode
                // still resolves .none until a grant lands (never an empty box).
                setOnlineIntentPending(true)
            }
        }
        return aiMode
    }
}
