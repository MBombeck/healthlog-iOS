import SwiftUI

// MARK: - AI consent gate

/// W-FILELEN — the AI-consent gate cluster, lifted verbatim out of
/// `AuthenticatedShell` into this same-module extension to keep the screen body
/// under the 600-line `file_length` swiftlint budget. Pure move, no behaviour
/// change. `pendingConsentProvider` is `internal` on the screen for this reason.
extension AuthenticatedShell {
    /// Inspects the current AI-provider + consent state. When the user
    /// has configured a remote LLM but not yet granted consent for it
    /// AND has not previously declined for that provider, schedules
    /// `AIConsentSheet` for presentation. `.unconfigured` providers
    /// short-circuit the gate (no off-device traffic happens).
    ///
    /// **PB1 H3:** previously this method re-presented the sheet on every
    /// tab change after a decline, nag-looping the user. The
    /// `wasDeclined(for:)` check below suppresses the auto-prompt; the
    /// user can re-engage via the explicit-CTA path
    /// (`requestExplicitConsentPrompt`).
    func evaluateConsentGate() {
        guard let container,
              pendingConsentProvider == nil else { return }
        // Bug 2 (v0.14.8) — don't gate against a provider that isn't loaded yet.
        // `config == nil` means the fetch hasn't landed (distinct from "server
        // genuinely has no provider"); opening the sheet now would capture a
        // phantom `.unconfigured`. The shell `.task` kicks off `load()` and the
        // `.onChange(of: config)` re-runs this once it arrives or its effective
        // availability changes without a provider-enum change.
        guard let config = container.aiProviderStore.config else { return }
        if config.usesProviderOpaqueAIConsent {
            guard !container.aiConsentStore.hasServerManagedConsent() else { return }
            guard !container.aiConsentStore.wasServerManagedDeclined() else { return }
            pendingConsentProvider = AIConsentRequest(provider: .unconfigured, serverManaged: true)
            return
        }
        guard case let .provider(provider) = config.aiConsentTarget else { return }
        guard !container.aiConsentStore.hasConsent(for: provider) else { return }
        // Honour the decline — no auto re-prompt until the user explicitly asks.
        guard !container.aiConsentStore.wasDeclined(for: provider) else { return }
        pendingConsentProvider = AIConsentRequest(provider: provider)
    }

    /// Explicit-CTA re-prompt path — fired when the user opted into the
    /// dialog by toggling Settings → KI → "KI-Einwilligung" back on or by
    /// tapping an AI-feature CTA after a prior decline. Bypasses the
    /// `wasDeclined` suppression because the user actively asked for it.
    /// Still respects an existing grant (no point presenting a sheet for
    /// a provider the user already consented to).
    func requestExplicitConsentPrompt() {
        guard let container,
              pendingConsentProvider == nil else { return }
        // Bug 2 (v0.14.8) — if config hasn't loaded, fetch it first, then evaluate
        // ONCE so the request resolves a real provider, not a phantom
        // `.unconfigured` (whose accept no-ops). Non-recursive: a failed load
        // leaves `config == nil` and we simply don't present (no retry loop).
        guard container.aiProviderStore.config != nil else {
            Task {
                await container.aiProviderStore.load()
                presentExplicitConsentIfNeeded()
            }
            return
        }
        presentExplicitConsentIfNeeded()
    }

    /// Bug 2 (v0.14.8) — terminal step of `requestExplicitConsentPrompt`: presents
    /// the sheet for a real, not-yet-granted provider. Split out so the load-first
    /// path cannot recurse.
    func presentExplicitConsentIfNeeded() {
        guard let container,
              pendingConsentProvider == nil else { return }
        guard let config = container.aiProviderStore.config else { return }
        if config.usesProviderOpaqueAIConsent {
            guard !container.aiConsentStore.hasServerManagedConsent() else { return }
            pendingConsentProvider = AIConsentRequest(provider: .unconfigured, serverManaged: true)
            return
        }
        guard case let .provider(provider) = config.aiConsentTarget else { return }
        guard !container.aiConsentStore.hasConsent(for: provider) else { return }
        pendingConsentProvider = AIConsentRequest(provider: provider)
    }
}

/// Wraps an `AIProvider` so it can drive a SwiftUI `.sheet(item:)` modifier
/// without requiring `AIProvider` itself to be `Identifiable` (which would
/// add `id` semantics the wire-codable type shouldn't have). The wrapper's
/// own `id` re-uses the provider's `rawValue` so identical providers don't
/// re-present the sheet on rapid `pendingConsentProvider` re-assignments.
struct AIConsentRequest: Identifiable, Hashable {
    let provider: AIProvider
    /// W-B186 COACH-1 (#24) — `true` when this consent governs the
    /// **server-managed** AI scope (no per-user provider; `aiAvailable == true`,
    /// `managedBy == "server"`). The accept path then grants the server-managed
    /// scope instead of a concrete provider, and the sheet uses the
    /// provider-agnostic `.serverMediated` copy.
    var serverManaged: Bool = false
    var id: String {
        serverManaged ? "__server_managed__" : provider.rawValue
    }
}
