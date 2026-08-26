import Foundation

/// v0.13 W2 — per-provider secret store for the client-side BYO-key path.
///
/// The API key is a secret, so it lives in the **Keychain** (PROJECT_GUIDE.md:
/// UserDefaults is UI-prefs only). The store is a `Sendable` struct over the
/// existing ``KeychainStoring`` injection so the logout / delete-account
/// cascade can wipe it (`wipeAll()`), and so tests can drive an in-memory
/// keychain double.
///
/// Three per-provider entries, all keyed by ``BYOProviderID/rawValue``:
/// - `byo.llm.key.<id>` — the API key bytes (the secret).
/// - `byo.llm.model.<id>` — optional user model override (falls back to
///   ``BYOProviderID/defaultModel`` when absent).
/// - `byo.llm.baseurl.<id>` — base URL, only meaningful for
///   ``BYOProviderID/openAICompatible``.
///
/// The base URL + model overrides ride in the Keychain alongside the key (one
/// home, one wipe path) — they are not secrets, but co-locating them keeps the
/// per-provider BYO config atomic and wiped in lockstep on logout.
public struct BYOKeyStore: Sendable {
    private let keychain: KeychainStoring

    /// Keychain account prefix for the API **key** bytes. `nonisolated` static
    /// so the logout/delete cascade can compose the account string without an
    /// instance. Stable persistence token — do not rename.
    public static let keyPrefix = "byo.llm.key."
    /// Keychain account prefix for the optional model override.
    public static let modelPrefix = "byo.llm.model."
    /// Keychain account prefix for the base URL (openAICompatible only).
    public static let baseURLPrefix = "byo.llm.baseurl."

    public init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    // MARK: - API key (secret)

    /// The stored API key for `provider`, or `nil` when none is saved.
    public func key(for provider: BYOProviderID) -> String? {
        let raw = keychain.getString(forKey: Self.keyPrefix + provider.rawValue)
        // An empty string is not a usable key — treat it as absent so a stray
        // blank write never reads back as "configured".
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Persists the API key for `provider`. A blank key is rejected — callers
    /// that mean "clear" must use ``removeKey(for:)`` (explicit intent), so a
    /// stray empty `SecureField` can never silently wipe a working key.
    public func setKey(_ key: String, for provider: BYOProviderID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BYOLLMError.invalidConfiguration("empty API key")
        }
        try keychain.setString(trimmed, forKey: Self.keyPrefix + provider.rawValue)
    }

    /// Removes the API key for `provider` (idempotent).
    public func removeKey(for provider: BYOProviderID) throws {
        try keychain.remove(forKey: Self.keyPrefix + provider.rawValue)
    }

    /// True when a non-empty key is stored for `provider`.
    public func hasKey(for provider: BYOProviderID) -> Bool {
        key(for: provider) != nil
    }

    // MARK: - Model override

    /// The user's model override for `provider`, or `nil` to use
    /// ``BYOProviderID/defaultModel``.
    public func model(for provider: BYOProviderID) -> String? {
        let raw = keychain.getString(forKey: Self.modelPrefix + provider.rawValue)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Sets/clears the model override for `provider`. An empty/blank string
    /// clears the override so the resolved model reverts to the default.
    public func setModel(_ model: String?, for provider: BYOProviderID) throws {
        let trimmed = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.remove(forKey: Self.modelPrefix + provider.rawValue)
        } else {
            try keychain.setString(trimmed, forKey: Self.modelPrefix + provider.rawValue)
        }
    }

    /// The model id to use for `provider` — the override if present, else the
    /// provider default. The single resolution point the service + W3 read.
    public func resolvedModel(for provider: BYOProviderID) -> String {
        model(for: provider) ?? provider.defaultModel
    }

    // MARK: - Base URL (openAICompatible)

    /// The stored base URL for `provider`, or `nil`. Only meaningful for
    /// ``BYOProviderID/openAICompatible``.
    public func baseURL(for provider: BYOProviderID) -> URL? {
        guard let raw = keychain.getString(forKey: Self.baseURLPrefix + provider.rawValue),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Sets/clears the base URL for `provider`. An empty string clears it.
    public func setBaseURL(_ url: URL?, for provider: BYOProviderID) throws {
        let raw = url?.absoluteString ?? ""
        if raw.isEmpty {
            try keychain.remove(forKey: Self.baseURLPrefix + provider.rawValue)
        } else {
            try keychain.setString(raw, forKey: Self.baseURLPrefix + provider.rawValue)
        }
    }

    // MARK: - Teardown

    /// Wipes **every** BYO entry (key + model + baseURL) for every provider.
    /// Wired into the logout / delete-account cascade so the secret key bytes
    /// never survive the user they were saved under. Idempotent — removing
    /// absent entries is a no-op.
    public func wipeAll() {
        for provider in BYOProviderID.allCases {
            try? keychain.remove(forKey: Self.keyPrefix + provider.rawValue)
            try? keychain.remove(forKey: Self.modelPrefix + provider.rawValue)
            try? keychain.remove(forKey: Self.baseURLPrefix + provider.rawValue)
        }
    }
}
