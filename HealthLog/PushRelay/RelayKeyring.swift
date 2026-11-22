import CryptoKit
import Foundation

// **#190 5.2 — the device keys of the relay, in their own keychain group.**
//
// One keychain item in `$(AppIdentifierPrefix)dev.healthlog.app.push`, the
// group only the app and the Notification Service Extension hold. The auth and
// refresh tokens stay in the app's own group, which the extension never gets.
// The item is `AfterFirstUnlockThisDeviceOnly`: the extension reads it while
// the phone is locked, and a backup restored to another device carries no key
// (the person turns the relay on again there).
//
// Nothing in here exists before the server seals (it reports
// `envelopeVersions`, #191); the binding key only after the person turned the
// relay on.

/// What the keyring holds, as one JSON item.
///
/// **D1 (5).** Versioned and decoded field by field (`decodeIfPresent`), so a
/// later build that adds a field never makes an older item unreadable, and an
/// item this build cannot read is never overwritten (``RelayKeyring/read()``).
public struct RelayKeyringState: Codable, Sendable, Equatable {
    /// The format this build writes.
    public static let currentFormat = 2

    /// An X25519 device key for the envelope, with its birth.
    public struct RecipientKey: Codable, Sendable, Equatable {
        public let privateKey: Data
        public let createdAt: Date
    }

    /// The Ed25519 binding key of one relay host, with its counter.
    public struct BindingKey: Codable, Sendable, Equatable {
        public let host: String
        public let privateKey: Data
        public var seq: Int64
    }

    /// What this device last bound, so the opt-out works without the server.
    public struct Binding: Codable, Sendable, Equatable {
        public let host: String
        public let instanceId: String
        public let tokenTag: Data
        public let consentTextVersion: String
        /// **D1 (3).** The APNs token the binding names. A later token does
        /// not move the binding at the relay; revoke, Live Activity withdraw
        /// and the challenge sign with this one. `nil` on items of 1.7 builds.
        public var apnsToken: Data?

        public init(host: String, instanceId: String, tokenTag: Data, consentTextVersion: String, apnsToken: Data? = nil) {
            self.host = host
            self.instanceId = instanceId
            self.tokenTag = tokenTag
            self.consentTextVersion = consentTextVersion
            self.apnsToken = apnsToken
        }
    }

    /// **D1 (3).** A direct revoke the relay has not confirmed yet. Kept
    /// apart from the binding, so it outlives a sign-out and its key wipe, and
    /// retried with backoff until the relay answers 2xx.
    public struct PendingRevocation: Codable, Sendable, Equatable {
        public let host: String
        public let instanceId: String
        public let apnsToken: Data
        public let bindingKey: Data
        public var attempts: Int
        public var nextAttemptAt: Date

        /// Tries before the device gives up (about two days of backoff).
        public static let maxAttempts = 12

        /// The record after one more failed try: 1, 2, 4 … minutes, at most
        /// six hours apart.
        public func failedOnce(now: Date) -> PendingRevocation {
            var next = self
            next.attempts += 1
            let minutes = min(pow(2, Double(next.attempts - 1)), 360)
            next.nextAttemptAt = now.addingTimeInterval(minutes * 60)
            return next
        }
    }

    public var formatVersion: Int = RelayKeyringState.currentFormat
    /// **D1 (1).** The account (``PushRelayStore/accountKey(userID:serverHost:)``)
    /// the keys were made for. Another account never opens with them.
    public var owner: String?
    /// The APNs token the push key was registered with: the AAD binds it,
    /// and the extension has no other way to learn it.
    public var apnsToken: Data?

    /// Current first, then at most one previous key.
    public var recipients: [RecipientKey] = []
    public var bindingKey: BindingKey?
    /// The server's sealing keys (`senderKeys`), at most three.
    public var trustedSenders: [Data] = []
    public var binding: Binding?
    /// Template category name to the random per-install identifier.
    public var categories: [String: String] = [:]
    public var pendingRevocations: [PendingRevocation] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case formatVersion, owner, apnsToken, recipients, bindingKey, trustedSenders, binding, categories, pendingRevocations
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        apnsToken = try c.decodeIfPresent(Data.self, forKey: .apnsToken)
        recipients = try c.decodeIfPresent([RecipientKey].self, forKey: .recipients) ?? []
        bindingKey = try c.decodeIfPresent(BindingKey.self, forKey: .bindingKey)
        trustedSenders = try c.decodeIfPresent([Data].self, forKey: .trustedSenders) ?? []
        binding = try c.decodeIfPresent(Binding.self, forKey: .binding)
        categories = try c.decodeIfPresent([String: String].self, forKey: .categories) ?? [:]
        pendingRevocations = try c.decodeIfPresent([PendingRevocation].self, forKey: .pendingRevocations) ?? []
    }

    /// How long the previous device key still opens after the current one
    /// was made (D1 (11)).
    public static let previousKeyGrace: TimeInterval = 7 * 24 * 60 * 60

    /// The keys that may open now: the current one, and the previous one
    /// only within ``previousKeyGrace`` of the current one's birth.
    public func openingRecipients(now: Date) -> [Curve25519.KeyAgreement.PrivateKey] {
        guard let current = recipients.first else { return [] }
        var usable = [current]
        if recipients.count > 1, now.timeIntervalSince(current.createdAt) < Self.previousKeyGrace {
            usable.append(recipients[1])
        }
        return usable.compactMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0.privateKey) }
    }

    /// The pinned sealing keys, at most three (`next`, `current`,
    /// `previous`, D1 (4)).
    public var openingSenders: [Curve25519.KeyAgreement.PublicKey] {
        trustedSenders.prefix(RelayKeyring.maxSenders).compactMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
    }
}

/// The keyring item cannot be read as it is: it is never overwritten.
public enum RelayKeyringError: Error, Sendable, Equatable {
    case unreadable
    case unavailable
}

public struct RelayKeyring: Sendable {
    public static let service = "dev.healthlog.app.push"
    static let itemKey = "relay.state.v1"
    /// Device keys rotate after 30 days (#190, security review).
    public static let rotationInterval: TimeInterval = 30 * 24 * 60 * 60
    /// Sealing keys the device pins at once (D1 (4)).
    public static let maxSenders = 3

    private let store: KeychainStoring

    public init(store: KeychainStoring) {
        self.store = store
    }

    /// The keychain group from the build (`HLPushKeychainGroup` in Info.plist,
    /// `$(AppIdentifierPrefix)dev.healthlog.app.push`).
    public static func production(bundle: Bundle = .main) -> RelayKeyring {
        let group = bundle.object(forInfoDictionaryKey: "HLPushKeychainGroup") as? String
        let resolved = group.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        return RelayKeyring(store: KeychainStore(service: service, accessGroup: resolved))
    }

    // MARK: State

    /// **D1 (5).** What the item holds, told apart: there is none, the
    /// keychain did not answer, or the item is there and this build cannot
    /// decode it. Only `missing` may be replaced by a new item.
    public enum Read: Sendable, Equatable {
        case found(RelayKeyringState)
        case missing
        case unavailable
        case unreadable
    }

    public func read() -> Read {
        switch store.readData(forKey: Self.itemKey) {
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        case let .found(data):
            guard let state = try? JSONDecoder().decode(RelayKeyringState.self, from: data) else { return .unreadable }
            return .found(state)
        }
    }

    /// `nil` when nothing was ever created, the keychain could not answer
    /// (before first unlock) or the item cannot be read: all mean "cannot
    /// open anything".
    public func state() -> RelayKeyringState? {
        if case let .found(state) = read() { return state }
        return nil
    }

    /// The state to change, or an error that forbids writing.
    private func writable() throws -> RelayKeyringState {
        switch read() {
        case let .found(state): return state
        case .missing: return RelayKeyringState()
        case .unavailable: throw RelayKeyringError.unavailable
        case .unreadable: throw RelayKeyringError.unreadable
        }
    }

    public func save(_ state: RelayKeyringState) throws {
        var stamped = state
        stamped.formatVersion = max(stamped.formatVersion, RelayKeyringState.currentFormat)
        try store.setData(JSONEncoder().encode(stamped), forKey: Self.itemKey)
    }

    /// Everything: keys, counter, pinned senders, categories. Unconfirmed
    /// revocations stay (D1 (3)) unless `keepingRevocations` is false.
    public func wipe(keepingRevocations: Bool = true) {
        let pending = keepingRevocations ? (state()?.pendingRevocations ?? []) : []
        try? store.remove(forKey: Self.itemKey)
        guard !pending.isEmpty else { return }
        var kept = RelayKeyringState()
        kept.pendingRevocations = pending
        try? save(kept)
    }

    /// **D1 (1).** New keys for `owner` when the item belongs to another
    /// account: no previous recipient key, no pinned senders, no binding, a
    /// new binding key and new category ids. An item from before the owner
    /// existed (1.7) is adopted as it is: it can only be this account's.
    /// Returns whether the keys were replaced.
    @discardableResult
    public func claim(for owner: String) throws -> Bool {
        var current = try writable()
        if current.owner == owner { return false }
        if current.owner == nil, !current.recipients.isEmpty || current.bindingKey != nil {
            current.owner = owner
            try save(current)
            return false
        }
        var fresh = RelayKeyringState()
        fresh.owner = owner
        fresh.pendingRevocations = current.pendingRevocations
        try save(fresh)
        return true
    }

    // MARK: Reading (app and extension)

    public func recipientKeys(now: Date = .now) -> [Curve25519.KeyAgreement.PrivateKey] {
        state()?.openingRecipients(now: now) ?? []
    }

    public func trustedSenders() -> [Curve25519.KeyAgreement.PublicKey] {
        state()?.openingSenders ?? []
    }

    /// The bound APNs token, which the AAD needs; the extension has no other
    /// way to learn it.
    public func boundToken() -> Data? {
        state()?.apnsToken
    }

    /// The token the relay binding names (D1 (3)): the binding's own, else
    /// (an item of 1.7) the registered one.
    public func bindingToken() -> Data? {
        guard let state = state() else { return nil }
        return state.binding?.apnsToken ?? state.apnsToken
    }

    public func secretCategory(for template: String) -> String? {
        state()?.categories[template]
    }

    // MARK: Writing (app only)

    /// The current device key, created on first use and rotated after
    /// ``rotationInterval``. The old one stays as `previous`, which opens for
    /// seven more days (D1 (11)), so envelopes sealed before the server
    /// learned the new key still open.
    @discardableResult
    public func ensureRecipientKey(now: Date = .now) throws -> Curve25519.KeyAgreement.PublicKey {
        var current = try writable()
        if let newest = current.recipients.first,
           now.timeIntervalSince(newest.createdAt) < Self.rotationInterval,
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: newest.privateKey)
        {
            if current.recipients.count > 1, now.timeIntervalSince(newest.createdAt) >= RelayKeyringState.previousKeyGrace {
                current.recipients = [newest]
                try save(current)
            }
            return key.publicKey
        }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        current.recipients = [RelayKeyringState.RecipientKey(privateKey: fresh.rawRepresentation, createdAt: now)]
            + current.recipients.prefix(1)
        try save(current)
        return fresh.publicKey
    }

    /// The binding key for `host` and the next counter value. A key for
    /// another host is replaced (one relay host per build).
    public func nextBinding(host: String) throws -> (key: Curve25519.Signing.PrivateKey, seq: Int64) {
        var current = try writable()
        var binding = current.bindingKey
        if binding?.host != host {
            binding = RelayKeyringState.BindingKey(
                host: host,
                privateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
                seq: 0
            )
        }
        guard var held = binding else { throw KeychainError.encoding }
        held.seq += 1
        current.bindingKey = held
        try save(current)
        return try (Curve25519.Signing.PrivateKey(rawRepresentation: held.privateKey), held.seq)
    }

    /// The relay is off: the binding record goes. The binding key and its
    /// counter stay, so turning the relay on again continues the same binding
    /// with a higher counter instead of a conflict; the envelope key and the
    /// pinned senders stay while the server seals.
    public func dropBinding() throws {
        try update { $0.binding = nil }
    }

    public func bindingKey() -> Curve25519.Signing.PrivateKey? {
        state()?.bindingKey.flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0.privateKey) }
    }

    public func update(_ change: (inout RelayKeyringState) -> Void) throws {
        var current = try writable()
        change(&current)
        try save(current)
    }

    /// Random identifiers for the action categories, made once per install.
    public static func makeCategoryIdentifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0 ... 255)
        }
        return "hl." + Data(bytes).relayBase64URL
    }
}
