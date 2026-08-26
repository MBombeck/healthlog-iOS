import Foundation
import Observation

/// v0.13 W4 — the testable, View-free engine behind ``BYOKeyEntryCard``.
///
/// Owns the BYO key-entry draft state + the **validate → save → grant** flow so
/// the non-trivial logic (which provider, which field is required, what a
/// successful validation does) is unit-pinned rather than buried in a `body`.
/// The card binds to this `@Observable`; the card never talks to `BYOLLMService`
/// / `BYOKeyStore` / `AIConsentStore` directly.
///
/// **Consent ordering (Apple 5.1.2(i)):** a key is validated against the
/// provider, then saved to the Keychain, and only THEN does the host present the
/// BYO informed-consent sheet. The grant (`grantBYO`, which flips `aiMode` to
/// `.byoKey`) lands on the sheet's accept callback — never silently on save. The
/// model exposes ``confirmConsent()`` for that callback and ``cancelConsent()``
/// for decline.
///
/// **Why `@MainActor @Observable`?** SwiftUI reads the inline state
/// (`phase`, `provider`, field drafts) synchronously per body pass; the
/// `validate` round-trip is an `async` hop the model awaits without blocking.
@MainActor
@Observable
public final class BYOKeyEntryModel {
    /// Inline lifecycle the card renders from. Each state maps to one honest
    /// affordance — no spinner-forever, no dead button.
    public enum Phase: Equatable {
        /// Editing the fields, nothing in flight.
        case editing
        /// `validate(...)` is awaiting the provider.
        case validating
        /// Validation failed — carries an honest, already-mapped message.
        case invalid(message: String)
        /// Validation + save succeeded; the consent sheet should be presented.
        case awaitingConsent
        /// The consent grant landed — the BYO arm is now active.
        case saved
    }

    /// The chosen provider. Defaults to OpenAI (cheapest, most common). Changing
    /// it resets the inline phase so a stale error doesn't carry across.
    public var provider: BYOProviderID = .openAI {
        didSet {
            guard provider != oldValue else { return }
            phase = .editing
            // v0.13 WR — re-sync the override drafts to the newly-selected
            // provider: clear the prior provider's model/baseURL drafts (the
            // secret key draft is never carried) and re-hydrate from THIS
            // provider's saved config so the fields show its persisted
            // overrides, not the previous provider's stale values.
            modelDraft = ""
            baseURLDraft = ""
            hydrateExistingConfig()
        }
    }

    /// Secret API key draft (bound to a `SecureField`). Cleared after a
    /// successful save so it never lingers in the view model.
    public var keyDraft: String = ""
    /// Optional model override draft. Empty → the provider default is used.
    public var modelDraft: String = ""
    /// Base-URL draft — only meaningful when ``provider`` requires it.
    public var baseURLDraft: String = ""

    public private(set) var phase: Phase = .editing

    private let service: BYOLLMService
    private let keyStore: BYOKeyStore
    private let consent: AIConsentStore

    public init(service: BYOLLMService, keyStore: BYOKeyStore, consent: AIConsentStore) {
        self.service = service
        self.keyStore = keyStore
        self.consent = consent
        hydrateExistingConfig()
    }

    /// True when a key is already saved + granted for the current provider —
    /// the card shows the "configured" state (provider + last-4 + model) with a
    /// Remove action instead of the entry fields.
    public var isConfigured: Bool {
        keyStore.hasKey(for: provider) && consent.hasBYOConsent(for: provider)
    }

    /// Last-4 of the saved key for the configured-state display. `nil` when no
    /// key is saved. Only the last 4 chars are ever surfaced — never the key.
    public var savedKeyLast4: String? {
        guard let key = keyStore.key(for: provider), key.count >= 4 else { return nil }
        return String(key.suffix(4))
    }

    /// The resolved model id shown in the configured state.
    public var resolvedModel: String {
        keyStore.resolvedModel(for: provider)
    }

    /// Whether the Validate & save action can fire (non-empty key; base URL
    /// present when the provider requires it).
    public var canSubmit: Bool {
        guard !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if provider.requiresBaseURL {
            return parsedBaseURL != nil
        }
        return true
    }

    private var parsedBaseURL: URL? {
        let trimmed = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        // https-only (D9): reject anything that isn't an https URL up front so
        // the user gets an honest inline error before any request.
        guard url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    private var resolvedModelDraft: String? {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// **validate → save** (consent is the host's next step). Validates the
    /// draft key against the provider; on success persists key + model + baseURL
    /// to the Keychain and moves to ``Phase/awaitingConsent`` so the host
    /// presents the BYO consent sheet. On failure surfaces an honest mapped
    /// message and stays in ``Phase/invalid(message:)``.
    public func validateAndSave() async {
        guard canSubmit else {
            phase = .invalid(message: Self.invalidConfigMessage(requiresBaseURL: provider.requiresBaseURL))
            return
        }
        phase = .validating
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await service.validate(
            provider: provider,
            key: key,
            model: resolvedModelDraft,
            baseURL: parsedBaseURL
        )
        switch result {
        case .success:
            do {
                try keyStore.setKey(key, for: provider)
                try keyStore.setModel(resolvedModelDraft, for: provider)
                if provider.requiresBaseURL {
                    try keyStore.setBaseURL(parsedBaseURL, for: provider)
                }
                // Clear the secret draft the moment it is persisted.
                keyDraft = ""
                phase = .awaitingConsent
            } catch {
                phase = .invalid(message: Self.saveFailedMessage)
            }
        case let .failure(error):
            phase = .invalid(message: Self.message(for: error))
        }
    }

    /// Consent accepted — record the per-provider BYO grant (flips `aiMode` to
    /// `.byoKey` + revokes the other arms). Called from the consent sheet's
    /// accept callback. Idempotent.
    public func confirmConsent() {
        consent.grantBYO(for: provider)
        phase = .saved
    }

    /// Consent declined — the key is already saved but no transmission may
    /// happen without a grant (the service fails closed). Roll back the saved
    /// key so we never leave a key with no consent dangling, and return to
    /// editing.
    public func cancelConsent() {
        try? keyStore.removeKey(for: provider)
        phase = .editing
    }

    /// Removes the saved key + model + baseURL for the current provider AND
    /// revokes the BYO consent grant. The single teardown the "Remove key"
    /// action calls.
    public func removeKey() {
        try? keyStore.removeKey(for: provider)
        try? keyStore.setModel(nil, for: provider)
        try? keyStore.setBaseURL(nil, for: provider)
        consent.revokeBYO(for: provider)
        // If no BYO provider remains granted, the pending intent should also
        // clear so the picker doesn't keep "Own key" stuck selected.
        if !consent.isAnyBYOKeyGranted() {
            consent.setBYOKeyIntentPending(false)
        }
        keyDraft = ""
        modelDraft = ""
        baseURLDraft = ""
        phase = .editing
    }

    /// Pre-fills the model + baseURL drafts from a previously-saved config so
    /// re-opening the card shows the user's prior overrides (the key itself is
    /// never read back into an editable field — only its last-4 is shown).
    private func hydrateExistingConfig() {
        if let model = keyStore.model(for: provider) {
            modelDraft = model
        }
        if let baseURL = keyStore.baseURL(for: provider) {
            baseURLDraft = baseURL.absoluteString
        }
    }

    // MARK: - Honest copy

    static func message(for error: BYOLLMError) -> String {
        switch error {
        case .invalidKey, .invalidConfiguration:
            String(localized: "That key was rejected. Check it and try again.")
        case .rateLimited:
            String(localized: "Your provider is rate-limiting requests. Try again shortly.")
        case .quotaExhausted:
            String(localized: "Your provider quota is used up. Check your account.")
        case .modelNotFound:
            String(localized: "That model is unknown to your provider. Pick another.")
        case .unreachable:
            String(localized: "Couldn't reach your provider. Check your connection.")
        case .providerUnavailable:
            String(localized: "Your provider is temporarily unavailable. Try again later.")
        case .safetyRefused:
            String(localized: "Your provider declined this validation request.")
        case .badRequest, .decode:
            String(localized: "Validation failed. Please try again.")
        }
    }

    static func invalidConfigMessage(requiresBaseURL: Bool) -> String {
        if requiresBaseURL {
            return String(localized: "Enter your key and an https base URL.")
        }
        return String(localized: "Enter your API key.")
    }

    static let saveFailedMessage = String(localized: "Could not save your key. Please try again.")
}
