import Foundation

// **The fields this device adds to `POST /api/devices` on its own behalf.**
//
// Kept apart from ``DeviceRegistration`` so the body's other additions (the
// per-Activity tokens of #188) and these merge without touching each other:
// ``DeviceRegistration`` holds one optional value of this type and encodes it
// into the same JSON object.
//
// - `medicationDelivery` (#179): who delivers this device's medication
//   reminders. Omitted until the device has decided, so a body built before
//   the first evaluation, or by 1.6, says nothing (the server reads `null`).
// - `pushKey` (#191): as soon as the server seals (it reports
//   `envelopeVersions`), through the relay or with its own APNs key.
// - `relayConsent`, `relayBinding` (#190 5.2): only after the person turned
//   the relay on, and the withdrawal after turning it off.
// - The Live Activity proof (#190 5.4) is not part of this type: it rides
//   inside each `liveActivityTokens[]` entry (``RelayActivityProof``).

/// Per-device medication reminder delivery (#179).
public enum DeviceMedicationDelivery: String, Codable, Sendable, Equatable {
    /// This device plans the reminders itself; the server sends it none.
    case client
    /// This device has no local reminders; the server delivers them.
    case server
}

/// The device's answer, including the explicit "not me".
public enum DeviceMedicationDeliveryReport: Sendable, Equatable {
    case delivery(DeviceMedicationDelivery)
    /// This device does not remind (an iPad next to an active iPhone): sent as
    /// `null`, so the account setting and the other device decide.
    case none

    /// The rule, from what the device already knows.
    ///
    /// - A device that does not plan local reminders at all reports `null`:
    ///   asking the server for pushes would duplicate the phone's reminders.
    /// - A device that plans and delivers them reports `client`. Reminders stay
    ///   local with the relay on too (#190 5.1: "Reminders stay on your
    ///   iPhone").
    /// - A device that would plan but delivers nothing (no permission, no
    ///   armed medication, a runway cut short) reports `server`: the server's
    ///   reminders then reach it directly or through the relay, which is the
    ///   server-reminder mode of #190 5.6.
    public static func decide(plansLocally: Bool, deliversLocally: Bool) -> DeviceMedicationDeliveryReport {
        guard plansLocally else { return .none }
        return .delivery(deliversLocally ? .client : .server)
    }

    var wireValue: String? {
        switch self {
        case let .delivery(value): value.rawValue
        case .none: nil
        }
    }
}

/// `pushKey`: the device's X25519 key for the envelope (#191, final names).
public struct RelayPushKey: Codable, Sendable, Equatable {
    public let v: Int
    public let suites: [Int]
    /// Raw 32 bytes, unpadded base64url.
    public let publicKey: String

    public init(publicKey: String) {
        v = 1
        suites = [1]
        self.publicKey = publicKey
    }
}

/// `relayBinding`: the signed binding statement (`hl-bind-v1`).
public struct RelayBindingStatement: Codable, Sendable, Equatable {
    public struct Statement: Codable, Sendable, Equatable {
        public let instanceId: String
        public let tokenTag: String
        public let kind: String
        public let seq: Int64
        public let iat: Int64
    }

    /// Ed25519, unpadded base64url.
    public let bindingKey: String
    public let statement: Statement
    public let signature: String
}

/// `relayConsent`: the person's answer and the consent text it was given to.
/// `granted: false` withdraws the relay; the push key stays.
public struct RelayConsentRecord: Codable, Sendable, Equatable {
    public let granted: Bool
    public let textVersion: String

    public init(granted: Bool, textVersion: String) {
        self.granted = granted
        self.textVersion = textVersion
    }
}

/// The relay part of one `liveActivityTokens[]` entry (`hl-activity-v1`).
/// The entry itself (`token`, `medicationId`, `slotInstant`) belongs to the
/// per-Activity token list of #188; this adds `statement` and `signature` to
/// it, and nothing else. Without it the server sends no `end` through the
/// relay.
public struct RelayActivityProof: Codable, Sendable, Equatable {
    public struct Statement: Codable, Sendable, Equatable {
        public let instanceId: String
        public let tokenTag: String
        public let laTokenTag: String
        public let iat: Int64
    }

    public let statement: Statement
    public let signature: String

    private enum CodingKeys: String, CodingKey { case statement, signature }

    /// Writes `statement` and `signature` into the entry's own object.
    public func encode(into encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(statement, forKey: .statement)
        try container.encode(signature, forKey: .signature)
    }
}

/// `liveActivityConsent` (`hl-la-consent-v1`): the separate consent to Live
/// Activity start and update over the relay. The relay and Apple then see
/// when a dose is due; the content state never carries a name.
public struct RelayLiveActivityConsent: Codable, Sendable, Equatable {
    public let textVersion: String
    public let iat: Int64
    public let signature: String
}

/// `liveActivityWithdraw` (`hl-la-withdraw-v1`).
public struct RelayLiveActivityWithdraw: Codable, Sendable, Equatable {
    public let iat: Int64
    public let signature: String
}

/// `liveActivityStart` (`hl-la-start-v1`): the push-to-start token of
/// ``HealthLogDoseAttributes``, signed at least every 30 days.
public struct RelayLiveActivityStart: Codable, Sendable, Equatable {
    public struct Statement: Codable, Sendable, Equatable {
        public let instanceId: String
        public let tokenTag: String
        public let laTokenTag: String
        public let iat: Int64
    }

    public let token: String
    public let statement: Statement
    public let signature: String
}

/// One `liveActivityTokens[]` entry for an Activity the relay started:
/// `relayStart: true` and no medication; the proof lets the relay update and
/// end it.
public struct RelayStartedActivityToken: Encodable, Sendable, Equatable {
    public let token: String
    public let relayStart = true
    public var proof: RelayActivityProof?

    public init(token: String, proof: RelayActivityProof?) {
        self.token = token
        self.proof = proof
    }

    private enum CodingKeys: String, CodingKey { case token, relayStart }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(relayStart, forKey: .relayStart)
        try proof?.encode(into: encoder)
    }
}

/// What the body says about the envelope and the relay.
public enum DevicePushKeyPart: Sendable, Equatable {
    /// The device's key, because the server seals (relay or its own APNs key).
    case key(RelayPushKey)
    /// `pushKey: null`: the server stopped sealing, or the device signed out.
    case withdrawn
}

/// Everything this device adds to the body, encoded into the same object.
public struct DeviceRegistrationPushFields: Sendable, Equatable {
    public var medicationDelivery: DeviceMedicationDeliveryReport?
    public var pushKey: DevicePushKeyPart?
    public var relayConsent: RelayConsentRecord?
    /// Only when the person turned the relay on; never on its own (#190 §4).
    public var relayBinding: RelayBindingStatement?
    public var liveActivityConsent: RelayLiveActivityConsent?
    public var liveActivityWithdraw: RelayLiveActivityWithdraw?
    /// `.some(nil)` sends `liveActivityStart: null` (the token is withdrawn).
    public var liveActivityStart: RelayLiveActivityStart??
    /// Joined into `liveActivityTokens[]` by ``DeviceRegistration``.
    public var relayStartedActivities: [RelayStartedActivityToken] = []

    public init(
        medicationDelivery: DeviceMedicationDeliveryReport? = nil,
        pushKey: DevicePushKeyPart? = nil,
        relayConsent: RelayConsentRecord? = nil,
        relayBinding: RelayBindingStatement? = nil
    ) {
        self.medicationDelivery = medicationDelivery
        self.pushKey = pushKey
        self.relayConsent = relayConsent
        self.relayBinding = relayBinding
    }

    public var isEmpty: Bool {
        medicationDelivery == nil && pushKey == nil && relayConsent == nil && relayBinding == nil
            && liveActivityConsent == nil && liveActivityWithdraw == nil && liveActivityStart == nil
            && relayStartedActivities.isEmpty
    }

    /// Part of the registration dedup key; empty when nothing is added, so an
    /// installation without either keeps its fingerprint. Signatures and
    /// times stay out, so an unchanged registration is not posted again.
    public var fingerprint: String {
        guard !isEmpty else { return "" }
        let delivery = medicationDelivery.map { $0.wireValue ?? "null" } ?? "-"
        let key = switch pushKey {
        case let .key(value): value.publicKey
        case .withdrawn: "null"
        case nil: "-"
        }
        let consent = relayConsent.map { "\($0.granted):\($0.textVersion)" } ?? "-"
        let binding = relayBinding.map { "b\($0.statement.seq)" } ?? "-"
        let liveActivity = [
            liveActivityConsent.map { "c\($0.textVersion)" } ?? "",
            liveActivityWithdraw == nil ? "" : "w",
            liveActivityStart.map { $0?.statement.laTokenTag ?? "null" } ?? "",
            relayStartedActivities.map(\.token).joined(separator: ",")
        ].joined(separator: "/")
        return "md=\(delivery);pk=\(key);rc=\(consent);rb=\(binding);la=\(liveActivity)"
    }

    private enum CodingKeys: String, CodingKey {
        case medicationDelivery, pushKey, relayConsent, relayBinding
        case liveActivityConsent, liveActivityWithdraw, liveActivityStart
    }

    public func encode(into encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let medicationDelivery {
            // Explicit `null` for "not me"; absent until decided.
            try container.encode(medicationDelivery.wireValue, forKey: .medicationDelivery)
        }
        switch pushKey {
        case let .key(value): try container.encode(value, forKey: .pushKey)
        case .withdrawn: try container.encodeNil(forKey: .pushKey)
        case nil: break
        }
        try container.encodeIfPresent(relayConsent, forKey: .relayConsent)
        try container.encodeIfPresent(relayBinding, forKey: .relayBinding)
        try container.encodeIfPresent(liveActivityConsent, forKey: .liveActivityConsent)
        try container.encodeIfPresent(liveActivityWithdraw, forKey: .liveActivityWithdraw)
        if let liveActivityStart {
            try container.encode(liveActivityStart, forKey: .liveActivityStart)
        }
    }
}
