import Foundation
import Observation

/// `@Observable` store backing `AIProviderScreen`. Owns the read-then-PATCH
/// lifecycle against `/api/user/ai-provider` and surfaces the UI affordances
/// the M2-A3 audit specifies:
///
/// - "Konfiguriert" / "Nicht konfiguriert" badge based on real server state,
/// - per-provider key/model/baseUrl edit fields,
/// - explicit save-button gating (tap-elsewhere never clears state — only
///   an explicit save round-trip changes anything server-side, per the
///   "Tap anywhere on the row doesn't clear state — only explicit edit/save"
///   acceptance criterion).
///
/// **Concurrency:** `@MainActor @Observable` — Repo is an `actor`, all writes
/// go through `Task { ... }` from the SwiftUI side.
///
/// **SWR adoption (PA5 Bottleneck #2, v0.5.x):** the AI-provider screen
/// used to fire a fresh `/api/user/ai-provider` GET on every mount with
/// zero cache-paint capability — empty `ProgressView` until the network
/// landed. The new `.aiProviderConfig` CacheKey (`staleAfter: 5 * 60`)
/// + this store's SWR-aware `load()` give the screen a cached paint
/// sub-100ms; the revalidate refreshes the badge behind the curtain
/// without clobbering in-flight drafts.
@MainActor
@Observable
public final class AIProviderStore {
    /// Last config read from the server. `nil` until the first `load()`
    /// completes — UI shows a `ProgressView` while this is `nil` and not
    /// `isLoading`.
    public private(set) var config: AIProviderConfig?

    /// Loading flag — flips to `true` for every load + save. Editors stay
    /// editable while loading; save button is disabled.
    public private(set) var isLoading: Bool = false

    /// Saving flag — separate from `isLoading` so the UI can show a different
    /// affordance (button spinner instead of full-screen progress).
    public private(set) var isSaving: Bool = false

    /// Last error surfaced from the server. `nil` after a successful round-trip.
    public private(set) var error: HLError?

    /// `true` after a successful save — UI uses this to drive a transient
    /// "Gespeichert" confirmation (clears via `acknowledgeSaved()`).
    public private(set) var didJustSave: Bool = false

    /// Set when the visible config was served from cache (SWR `.cached`
    /// arm). Kept for parity with the other SWR-backed stores; the
    /// AIProvider screen doesn't surface the "cached" badge yet but the
    /// state slot exists for future use.
    public private(set) var isShowingStaleCache: Bool = false

    // MARK: - Draft state (user's pending edits)

    /// Provider the user is currently picking in the screen. Initialised
    /// from `config.resolvedProvider` once the first load lands. Editing
    /// this value never hits the network until the user taps save.
    public var draftProvider: AIProvider = .unconfigured

    /// Free-form model override the user is editing. Maps to the `model`
    /// PATCH field. Empty string clears the override server-side.
    public var draftModel: String = ""

    /// Base URL the user is editing (LOCAL only). Maps to `baseUrl`. Empty
    /// clears server-side.
    public var draftBaseUrl: String = ""

    /// API key entered for the active provider. Stored in a single field
    /// — the store routes it into the right server slot (`anthropicKey`,
    /// `openaiKey`, or `localKey`) based on `draftProvider` at save time.
    /// Never echoed back from the server; once saved, the field clears
    /// and only the preview "...ABCD" remains visible.
    public var draftAPIKey: String = ""

    private let repo: AIProviderRepository
    private let swr: SWRCoordinator?

    public init(repo: AIProviderRepository, swr: SWRCoordinator? = nil) {
        self.repo = repo
        self.swr = swr
    }

    // MARK: - Lifecycle

    /// Load the current config from the server. Repopulates the draft fields
    /// from the resolved state on **first** load only — subsequent SWR
    /// emits (cache→fresh) refresh `config` without clobbering in-flight
    /// drafts, so a user editing while the revalidate lands doesn't lose
    /// their typing.
    public func load() async {
        // 14-06 — `.empty` raises `isLoading` and only a terminal emission
        // lowered it, so a cancelled stream stranded the flag for the life of
        // the process. The defer lowers the FLAG and publishes nothing else; a
        // flag still raised at exit means this load published nothing at all.
        defer {
            if isLoading {
                StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .aiProvider)
            }
            isLoading = false
        }
        guard let swr else {
            await loadDirect()
            return
        }
        let repo = repo
        for await state in await swr.observe(
            .aiProviderConfig,
            decoding: AIProviderConfig.self,
            fetch: { try await repo.config() }
        ) {
            switch state {
            case .empty:
                isLoading = true
                error = nil
            case let .cached(value, _):
                let isFirstLoad = (config == nil)
                config = value
                isShowingStaleCache = true
                isLoading = false
                if isFirstLoad {
                    applyDraftsFrom(value)
                }
            case let .fresh(value):
                let isFirstLoad = (config == nil)
                config = value
                isShowingStaleCache = false
                isLoading = false
                error = nil
                if isFirstLoad {
                    applyDraftsFrom(value)
                }
            case let .failed(err, lastKnown):
                if let lastKnown {
                    let isFirstLoad = (config == nil)
                    config = lastKnown
                    isShowingStaleCache = true
                    if isFirstLoad {
                        applyDraftsFrom(lastKnown)
                    }
                }
                isLoading = false
                error = err
            }
        }
    }

    /// Direct-fetch path — used when no SWR coordinator is injected
    /// (unit tests). Keeps the legacy single-emit semantics so existing
    /// `AIProviderStoreTests` expectations still hold.
    private func loadDirect() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let fresh = try await repo.config()
            applyConfig(fresh)
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Persists the active draft. Composes a PATCH body that only includes
    /// the fields that actually changed against the last loaded config — the
    /// server treats sent-but-empty fields as "clear", so we deliberately do
    /// not send untouched fields.
    public func save() async {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        let patch = buildSavePatch()

        do {
            let updated = try await repo.update(patch)
            // The repo re-fetches GET after PATCH so we have authoritative state.
            applyConfig(updated)
            // Mirror to cache so the next observe sees the writer-truth.
            if let swr {
                await swr.writeThrough(.aiProviderConfig, value: updated)
            }
            // Clear the API key draft so the field doesn't keep a sensitive value in memory.
            draftAPIKey = ""
            didJustSave = true
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Compose the PATCH body from the current draft state. Extracted from
    /// `save()` so the entry point stays under SwiftLint's cyclomatic
    /// budget — the field-by-field diff logic is genuinely intricate but
    /// orthogonal to the save lifecycle.
    private func buildSavePatch() -> AIProviderUpdate {
        var patch = AIProviderUpdate(provider: .some(draftProvider.wireValue))

        // Model: send only when the provider supports model-override AND the
        // draft differs from the last server-known value. Empty draft means
        // "clear the override" — explicit nil so the server resets the column.
        if draftProvider.supportsModelOverride {
            let trimmed = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != (config?.model ?? "") {
                patch.model = .some(trimmed.isEmpty ? nil : trimmed)
            }
        }

        // Base URL: only LOCAL provider uses this. Same diff-against-server
        // rule applies. Server auto-clears baseUrl when provider changes away
        // from LOCAL (route.ts:111-119) so we only send it when needed.
        if draftProvider.supportsBaseUrl {
            let trimmed = draftBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != (config?.baseUrl ?? "") {
                patch.baseUrl = .some(trimmed.isEmpty ? nil : trimmed)
            }
        }

        // API key: only send when the user actually typed something. The
        // server never echoes the plaintext key back, so we can't compare
        // against the loaded config — we trust the field-emptiness check.
        let typedKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedKey.isEmpty {
            switch draftProvider {
            case .anthropic:
                patch.anthropicKey = .some(typedKey)
            case .openai:
                patch.openaiKey = .some(typedKey)
            case .local:
                patch.localKey = .some(typedKey)
            case .unconfigured, .openaiCompatible:
                break
            }
        }
        return patch
    }

    /// Clear the API key for the currently-selected provider. Sends an
    /// explicit `null` for the relevant key field — the server route treats
    /// `null`/empty as "remove" (route.ts:94-117).
    public func clearAPIKey() async {
        guard !isSaving, draftProvider.requiresKey else { return }
        isSaving = true
        defer { isSaving = false }
        var patch = AIProviderUpdate()
        switch draftProvider {
        case .anthropic: patch.anthropicKey = .some(nil)
        case .openai: patch.openaiKey = .some(nil)
        case .local: patch.localKey = .some(nil)
        case .unconfigured, .openaiCompatible: return
        }
        do {
            let updated = try await repo.update(patch)
            applyConfig(updated)
            if let swr {
                await swr.writeThrough(.aiProviderConfig, value: updated)
            }
            draftAPIKey = ""
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    // MARK: - UI affordances

    /// Acknowledges the "Gespeichert" toast — caller clears it after the
    /// pulse animation finishes.
    public func acknowledgeSaved() {
        didJustSave = false
    }

    /// Has the user changed anything since the last load? Drives the save
    /// button's enabled state.
    public var hasUnsavedChanges: Bool {
        guard let config else {
            // Pre-first-load: only treat as dirty if the user already typed
            // a key — picking `.unconfigured` against a yet-unknown server
            // state isn't dirty yet.
            return !draftAPIKey.isEmpty
        }
        if draftProvider != config.resolvedProvider { return true }
        if draftProvider.supportsModelOverride {
            let trimmed = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != (config.model ?? "") { return true }
        }
        if draftProvider.supportsBaseUrl {
            let trimmed = draftBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != (config.baseUrl ?? "") { return true }
        }
        if !draftAPIKey.isEmpty { return true }
        return false
    }

    /// Server's view of what's currently active. Drives the "Konfiguriert"
    /// pill at the top of the screen.
    public var serverProvider: AIProvider {
        config?.resolvedProvider ?? .unconfigured
    }

    /// The server reports a working AI route whose provider identifier is not
    /// part of this client version. UI must show it as available without
    /// inventing a vendor name or treating it as unconfigured.
    public var usesProviderOpaqueAIConsent: Bool {
        config?.usesProviderOpaqueAIConsent == true
    }

    public var isServerAIAvailable: Bool {
        config?.isServerAIAvailable == true
    }

    /// Whether the server has all the bits it needs to actually call the
    /// selected provider. Drives the green-check vs orange-warning pill.
    public var isServerFullyConfigured: Bool {
        config?.isFullyConfigured ?? false
    }

    /// Server-resident preview of the active provider's key (e.g. `"...AB12"`)
    /// — `nil` when none is set.
    public var serverKeyPreview: String? {
        config?.activeKeyPreview
    }

    /// v0.14.8 W3 (AUDIT-SECURITY-B175 M-1) — drop the previous user's
    /// provider config + every draft on logout. `draftAPIKey` is the
    /// sensitive one: an un-saved typed key must never survive into the next
    /// user's session. The SWR-cached config row is dropped separately by
    /// `swr.invalidateAll()` in the logout cascade.
    public func clearOnLogout() {
        config = nil
        isLoading = false
        isSaving = false
        error = nil
        didJustSave = false
        isShowingStaleCache = false
        draftProvider = .unconfigured
        draftModel = ""
        draftBaseUrl = ""
        draftAPIKey = ""
    }

    // MARK: - Helpers

    private func applyConfig(_ fresh: AIProviderConfig) {
        config = fresh
        // Reset drafts to server truth so the screen reflects what's actually
        // persisted. Keep the API-key field empty — the server never echoes
        // plaintext keys back.
        applyDraftsFrom(fresh)
    }

    /// Initialise drafts from a server payload. Called on first-load (SWR
    /// `.cached`/`.fresh`/`.failed` arms) so the user sees the persisted
    /// state in the editors. Later revalidation passes deliberately do NOT
    /// call this — they only refresh `config` so the badge updates without
    /// clobbering in-flight drafts.
    private func applyDraftsFrom(_ fresh: AIProviderConfig) {
        draftProvider = fresh.resolvedProvider
        draftModel = fresh.model ?? ""
        draftBaseUrl = fresh.baseUrl ?? ""
        draftAPIKey = ""
    }
}
