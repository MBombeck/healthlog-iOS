import Foundation

// **#190 5.1 (2), final names in #191 — what `/api/auth/me` says.**
//
// `push.relay` names the operator's offer, the sealing keys and parameters;
// `push.device` is this device's own state, resolved by the server from
// `X-Device-Id` (the same block `POST /api/devices` answers with).
// Tolerant like every capability decode: a missing or odd field means "not
// offered", never a thrown decode. The app gates on these fields only, never
// on a server version.

public struct RelayCapability: Sendable, Equatable {
    public enum State: String, Sendable {
        case ok
        case degraded
        case down
        case off
    }

    public enum DeviceRelayState: String, Sendable {
        case none
        case bound
        case rebindNeeded = "rebind_needed"
        case conflict
    }

    public enum IntakeSync: String, Sendable {
        case ok
        case degraded
    }

    public enum Transport: String, Sendable {
        case relay
        case direct
        case none
    }

    /// `push.device`: the server's view of this device (`X-Device-Id`), the
    /// same block the `POST /api/devices` answer carries.
    public struct Device: Sendable, Equatable {
        public var transport: Transport
        /// `1` once the server seals for this device; `nil` before.
        public var envelope: Int?
        public var consent: Bool
        public var relayState: DeviceRelayState
        public var intakeSync: IntakeSync
        public var senderKeys: [Data]
        public var relayInstanceId: String?
        /// The relay accepted this device's Live Activity consent.
        public var liveActivityConsent: Bool
        /// The dose of the Activity the relay started (#190, 18:29): the
        /// push and the attributes carry none on purpose. `nil` once the
        /// slot is taken, skipped or ended.
        public var liveActivityStarted: StartedDose?
        /// **D1 (8).** The block named `envelope` at all, `null` included.
        /// Only an explicit `envelope: null` turns envelope mode off; a block
        /// without the key says nothing.
        public var reportsEnvelope: Bool = false

        public struct StartedDose: Sendable, Equatable {
            public let medicationId: String
            public let slotInstant: Date?
        }

        public init(
            transport: Transport = .none,
            envelope: Int? = nil,
            consent: Bool = false,
            relayState: DeviceRelayState = .none,
            intakeSync: IntakeSync = .ok,
            senderKeys: [Data] = [],
            relayInstanceId: String? = nil,
            liveActivityConsent: Bool = false,
            liveActivityStarted: StartedDose? = nil,
            reportsEnvelope: Bool = false
        ) {
            self.transport = transport
            self.envelope = envelope
            self.consent = consent
            self.relayState = relayState
            self.intakeSync = intakeSync
            self.senderKeys = senderKeys
            self.relayInstanceId = relayInstanceId
            self.liveActivityConsent = liveActivityConsent
            self.liveActivityStarted = liveActivityStarted
            self.reportsEnvelope = reportsEnvelope || envelope != nil
        }
    }

    /// The relay is usable at all (its identity keys are pinned on the server).
    public var available: Bool
    /// The operator turned it on.
    public var offered: Bool
    public var state: State
    /// Since when `state` holds.
    public var since: Date?
    public var instanceId: String?
    /// The server's X25519 sealing keys (current first), raw 32 bytes.
    public var senderKeys: [Data]
    /// Present whenever the server seals: relay offered or its own APNs key.
    public var envelopeVersions: [Int]
    /// The Live Activity pushes over the relay (`["end"]` in 1.49.0; `start`
    /// and `update` need their own consent, #191).
    public var liveActivity: [String]
    /// `push.relay.liveActivityConsentTextVersion` (`2026-11-21`).
    public var liveActivityConsentTextVersion: String?
    /// `push.relay.host`: the relay the server talks to. When it is not the
    /// relay of this build, the relay counts as not offered (#190 §9).
    public var host: String?
    public var termsURL: URL?
    public var privacyURL: URL?
    public var consentTextVersion: String?
    /// `nil` when the server does not know this device yet.
    public var device: Device?

    public init(
        available: Bool = false,
        offered: Bool = false,
        state: State = .off,
        since: Date? = nil,
        instanceId: String? = nil,
        senderKeys: [Data] = [],
        envelopeVersions: [Int] = [],
        liveActivity: [String] = [],
        termsURL: URL? = nil,
        privacyURL: URL? = nil,
        consentTextVersion: String? = nil,
        host: String? = nil,
        device: Device? = nil
    ) {
        self.available = available
        self.offered = offered
        self.state = state
        self.since = since
        self.instanceId = instanceId
        self.senderKeys = senderKeys
        self.envelopeVersions = envelopeVersions
        self.liveActivity = liveActivity
        self.termsURL = termsURL
        self.privacyURL = privacyURL
        self.consentTextVersion = consentTextVersion
        self.host = host
        self.device = device
    }

    public static let notOffered = RelayCapability()

    /// The server seals envelope v1 and named a key to trust: the device
    /// registers its push key (#191), relay or not.
    public var seals: Bool {
        envelopeVersions.contains(1) && !trustedSenderKeys.isEmpty
    }

    /// The device's own sender list when the server sent one, else the
    /// capability's.
    public var trustedSenderKeys: [Data] {
        let own = device?.senderKeys ?? []
        return Array((own.isEmpty ? senderKeys : own).prefix(RelayKeyring.maxSenders))
    }

    /// The server names a relay other than this build's: not offered (§9).
    public var usesOtherRelay: Bool {
        guard let host, !host.isEmpty else { return false }
        return host.lowercased() != HLPushRelayKeys.host.lowercased()
    }

    /// The relay can be offered to the person: available, offered, this
    /// build's relay, envelope v1, an instance and a consent text to record.
    public var isUsable: Bool {
        available && offered && !usesOtherRelay && seals && instanceId.map(Self.isInstanceId) == true
            && consentTextVersion?.isEmpty == false
    }

    /// The server confirmed it seals for this device; from now on unsealed
    /// content is refused (#190 5.3).
    ///
    /// **D1 (14).** Any reported version counts: a later server's `2` must
    /// never turn plaintext back on. An envelope this build cannot open ends
    /// as `unsupportedVersion`, i.e. the placeholder.
    public var sealsForThisDevice: Bool {
        device?.envelope != nil
    }

    /// The line about a disrupted sync (#191): offered, bound, and either the
    /// relay or the intake sync is not well.
    public var isDegraded: Bool {
        guard offered, let device, device.relayState == .bound else { return false }
        return state != .ok || device.intakeSync == .degraded
    }

    static func isInstanceId(_ text: String) -> Bool {
        text.count == 36 && text == text.lowercased() && UUID(uuidString: text) != nil
    }

    /// **D1 (4).** Up to three sealing keys. An entry may carry `status`
    /// (`next`, `current`, `previous`): those are ordered current, next,
    /// previous, so none falls out of the three; any other status (a retired
    /// key) is not trusted. An entry without status keeps its place.
    static func keys(_ value: Any?) -> [Data] {
        struct Ranked {
            let rank: Int
            let index: Int
            let key: Data
        }
        let rank = ["current": 0, "next": 1, "previous": 2]
        let parsed: [Ranked] = (value as? [Any] ?? []).enumerated().compactMap { index, entry in
            let object = entry as? [String: Any]
            let text = (entry as? String) ?? (object?["publicKey"] as? String)
            guard let text, let key = Data(relayBase64URL: text), key.count == 32 else { return nil }
            guard let status = object?["status"] as? String else { return Ranked(rank: 0, index: index, key: key) }
            guard let order = rank[status] else { return nil }
            return Ranked(rank: order, index: index, key: key)
        }
        var seen = Set<Data>()
        return parsed.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.key)
            .filter { seen.insert($0).inserted }
    }

    static func https(_ value: Any?) -> URL? {
        (value as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    /// `push.device`, also the `push` block of the `POST /api/devices` answer.
    static func parseDevice(_ value: Any?) -> Device? {
        guard let device = value as? [String: Any] else { return nil }
        return Device(
            transport: (device["transport"] as? String).flatMap(Transport.init(rawValue:)) ?? .none,
            envelope: (device["envelope"] as? NSNumber)?.intValue,
            consent: device["consent"] as? Bool ?? false,
            relayState: (device["relayState"] as? String).flatMap(DeviceRelayState.init(rawValue:)) ?? .none,
            intakeSync: (device["intakeSync"] as? String).flatMap(IntakeSync.init(rawValue:)) ?? .ok,
            senderKeys: keys(device["senderKeys"]),
            relayInstanceId: device["relayInstanceId"] as? String,
            liveActivityConsent: device["liveActivityConsent"] as? Bool ?? false,
            liveActivityStarted: (device["liveActivityStarted"] as? [String: Any]).flatMap { started in
                (started["medicationId"] as? String).map {
                    Device.StartedDose(
                        medicationId: $0,
                        slotInstant: (started["slotInstant"] as? String).flatMap { APNsPayload.parseISO8601($0) }
                    )
                }
            },
            reportsEnvelope: device.keys.contains("envelope")
        )
    }

    /// Whether the `/api/auth/me` object carries a `push` block at all.
    /// Without one the answer says nothing about sealing or the relay (R1 (6)).
    public static func reportsPush(me: [String: Any]) -> Bool {
        pushBlock(in: me) != nil
    }

    private static func pushBlock(in me: [String: Any]) -> [String: Any]? {
        let root = (me["user"] as? [String: Any]).flatMap { $0["push"] == nil ? nil : $0 } ?? me
        return root["push"] as? [String: Any]
    }

    /// Reads `push.relay` and `push.device` out of the `/api/auth/me` object.
    public static func parse(me: [String: Any]) -> RelayCapability {
        guard let push = pushBlock(in: me) else { return .notOffered }
        var capability = RelayCapability()
        capability.device = parseDevice(push["device"])
        guard let relay = push["relay"] as? [String: Any] else { return capability }
        capability.available = relay["available"] as? Bool ?? false
        capability.offered = relay["offered"] as? Bool ?? false
        capability.state = (relay["state"] as? String).flatMap(State.init(rawValue:)) ?? .off
        capability.since = (relay["since"] as? String).flatMap { APNsPayload.parseISO8601($0) }
        capability.instanceId = relay["instanceId"] as? String
        capability.senderKeys = keys(relay["senderKeys"])
        capability.envelopeVersions = (relay["envelopeVersions"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        capability.liveActivity = relay["liveActivity"] as? [String] ?? []
        capability.termsURL = https(relay["termsUrl"])
        capability.privacyURL = https(relay["privacyUrl"])
        capability.consentTextVersion = relay["consentTextVersion"] as? String
        capability.host = relay["host"] as? String
        capability.liveActivityConsentTextVersion = relay["liveActivityConsentTextVersion"] as? String
        return capability
    }
}

/// `GET /api/auth/me`, read only for `push.relay`.
public struct AuthMeRelay: Decodable, Sendable {
    public let relay: RelayCapability
    /// `false` when the answer has no `push` block: "unknown", not "off".
    public let reportsPush: Bool

    public init(from decoder: any Decoder) throws {
        let json = (try? RelayJSON(from: decoder)) ?? .null
        let me = json.propertyListValue as? [String: Any]
        relay = me.map(RelayCapability.parse(me:)) ?? .notOffered
        reportsPush = me.map(RelayCapability.reportsPush(me:)) ?? false
    }
}

extension RelayJSON: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RelayJSON].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: RelayJSON].self))
        }
    }
}

/// `POST /api/devices` answers `{ id, push }`; `push` is the same block as
/// `push.device` on `/api/auth/me`. Read tolerantly: anything else is no
/// answer about the relay.
public struct DeviceRegistrationAnswer: Decodable, Sendable {
    public let device: RelayCapability.Device?

    public init(from decoder: any Decoder) throws {
        let json = (try? RelayJSON(from: decoder)) ?? .null
        device = RelayCapability.parseDevice((json.propertyListValue as? [String: Any])?["push"])
    }
}
