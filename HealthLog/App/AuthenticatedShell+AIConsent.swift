import SwiftUI

// MARK: - AI consent gate

/// The AI-consent gate cluster, lifted verbatim out of
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
    /// Previously this method re-presented the sheet on every
    /// tab change after a decline, nag-looping the user. The
    /// `wasDeclined(for:)` check below suppresses the auto-prompt; the
    /// user can re-engage via the explicit-CTA path
    /// (`requestExplicitConsentPrompt`).
    func evaluateConsentGate() {
        // The automatic gate never raises its sheet over a shell sheet that
        // is up or animating (that would preempt it); the next tab change
        // re-evaluates.
        guard let container,
              pendingConsentProvider == nil,
              sheetGate.isIdle else { return }
        // Bug 2 — don't gate against a provider that isn't loaded yet
        // (`config == nil`); the shell `.task` loads it and the
        // `.onChange(of: config)` re-runs this once it arrives. The decision
        // itself is `AIConsentRequest.pending(config:consent:honourDecline:standing:)`
        // (J1 — pure, so the relaunch round trip is testable).
        pendingConsentProvider = AIConsentRequest.pending(
            config: container.aiProviderStore.config,
            consent: container.aiConsentStore,
            honourDecline: true,
            standing: container.aiCapabilityGate.standingConsent
        )
    }

    /// The shell mount and every change of the server's
    /// `ai.consent`: local consent follows the server (read-only, never sends a
    /// receipt; see `AppContainer.reconcileAIConsentWithServer()`), then the
    /// automatic gate decides whether to ask.
    func reconcileConsentWithServer() {
        container?.reconcileAIConsentWithServer()
        evaluateConsentGate()
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
        // Bug 2 — if config hasn't loaded, fetch it first, then evaluate
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

    /// Bug 2 — terminal step of `requestExplicitConsentPrompt`: presents
    /// the sheet for a real, not-yet-granted provider. Split out so the load-first
    /// path cannot recurse.
    func presentExplicitConsentIfNeeded() {
        guard let container,
              pendingConsentProvider == nil else { return }
        pendingConsentProvider = AIConsentRequest.pending(
            config: container.aiProviderStore.config,
            consent: container.aiConsentStore,
            honourDecline: false,
            standing: container.aiCapabilityGate.standingConsent
        )
    }
}

/// Wraps an `AIProvider` so it can drive a SwiftUI `.sheet(item:)` modifier
/// without requiring `AIProvider` itself to be `Identifiable` (which would
/// add `id` semantics the wire-codable type shouldn't have). The wrapper's
/// own `id` re-uses the provider's `rawValue` so identical providers don't
/// re-present the sheet on rapid `pendingConsentProvider` re-assignments.
struct AIConsentRequest: Identifiable, Hashable {
    let provider: AIProvider
    /// `true` when this consent governs the
    /// **server-managed** AI scope (no per-user provider; `aiAvailable == true`,
    /// `managedBy == "server"`). The accept path then grants the server-managed
    /// scope instead of a concrete provider, and the sheet uses the
    /// provider-agnostic `.serverMediated` copy.
    var serverManaged: Bool = false
    /// The operator-held services the server named in
    /// `ai.consent.recipients` while it reported `needed`; the sheet names
    /// them as where the data goes. Empty otherwise.
    var recipients: [String] = []
    var id: String {
        serverManaged ? "__server_managed__" : provider.rawValue
    }
}

extension AIConsentRequest {
    /// The consent the shell still has to ask for, or `nil`.
    ///
    /// - `config == nil` — not loaded yet, never gate against a phantom.
    /// - provider-opaque (server AI whose provider this build cannot name) —
    ///   the server-managed scope.
    /// - a concrete provider — that provider's grant.
    /// - `honourDecline` — the automatic gate respects an earlier decline; the
    ///   explicit prompt (Settings, AI CTA) does not.
    ///
    /// A grant already on file always wins: this is what keeps the sheet from
    /// coming back on the next launch once Accept landed.
    ///
    /// `standing` is the server's `ai.consent` (v1.43.2, `nil`
    /// before). `not_needed` never raises the sheet by itself (the explicit
    /// prompt still does, for the device-side disclosure); `needed` names its
    /// recipients. A local grant the server no longer backs is set aside by
    /// `AppContainer.reconcileAIConsentWithServer()` before this runs.
    @MainActor
    static func pending(
        config: AIProviderConfig?,
        consent: AIConsentStore,
        honourDecline: Bool,
        standing: AIStandingConsent? = nil
    ) -> AIConsentRequest? {
        guard let config else { return nil }
        if honourDecline, standing?.verdict == .notNeeded { return nil }
        let recipients = standing?.verdict == .needed ? standing?.recipientNames ?? [] : []
        if config.usesProviderOpaqueAIConsent {
            guard !consent.hasServerManagedConsent() else { return nil }
            if honourDecline, consent.wasServerManagedDeclined() { return nil }
            return AIConsentRequest(provider: .unconfigured, serverManaged: true, recipients: recipients)
        }
        guard case let .provider(provider) = config.aiConsentTarget else { return nil }
        guard !consent.hasConsent(for: provider) else { return nil }
        if honourDecline, consent.wasDeclined(for: provider) { return nil }
        return AIConsentRequest(provider: provider, recipients: recipients)
    }
}
