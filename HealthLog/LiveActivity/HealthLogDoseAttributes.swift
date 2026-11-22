import Foundation
#if canImport(ActivityKit)
    import ActivityKit
#endif

// **#190 (17:58 to 18:29) — the Live Activity the relay starts.**
//
// The relay starts and updates only Activities of this type (`relayStart`).
// Its attributes are `{"v":1}` and its content state is the relay's closed
// template: no name, no dose, no medication id. The app learns the started
// dose from its own server (`push.device.liveActivityStarted`) and writes the
// name into the App Group, where the widget reads it; until then the Activity
// shows a neutral title. Activities the app starts itself stay
// ``MedicationActivityAttributes``.

/// The relay's six fields. `countdownTarget` is unix seconds, `0` for none,
/// unlike ActivityKit's default date encoding; an unknown status reads as
/// neutral.
public struct HealthLogDoseContentState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case pending
        case due
        case overdue
        case snoozed
        case taken
        case skipped
        case unknown
    }

    public var status: Status
    /// Unix seconds; `0` means no countdown.
    public var countdownTarget: Int64
    public var isOverdue: Bool
    public var confirmed: Bool
    public var pendingConfirm: Bool
    /// `AUTO`, `H12` or `H24`.
    public var timeFormatRaw: String

    public init(
        status: Status,
        countdownTarget: Int64,
        isOverdue: Bool = false,
        confirmed: Bool = false,
        pendingConfirm: Bool = false,
        timeFormatRaw: String = "AUTO"
    ) {
        self.status = status
        self.countdownTarget = countdownTarget
        self.isOverdue = isOverdue
        self.confirmed = confirmed
        self.pendingConfirm = pendingConfirm
        self.timeFormatRaw = timeFormatRaw
    }

    private enum CodingKeys: String, CodingKey {
        case status, countdownTarget, isOverdue, confirmed, pendingConfirm, timeFormatRaw
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard let decoded = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return decoded
        }
        status = value(String.self, .status).flatMap(Status.init(rawValue:)) ?? .unknown
        countdownTarget = value(Double.self, .countdownTarget).map(Self.countdownSeconds) ?? 0
        isOverdue = value(Bool.self, .isOverdue) ?? false
        confirmed = value(Bool.self, .confirmed) ?? false
        pendingConfirm = value(Bool.self, .pendingConfirm) ?? false
        let format = value(String.self, .timeFormatRaw) ?? "AUTO"
        timeFormatRaw = ["AUTO", "H12", "H24"].contains(format) ? format : "AUTO"
    }

    /// The latest countdown the device accepts (2100-01-01).
    static let maxCountdownSeconds: Int64 = 4_102_444_800

    /// **D1 (10).** Unix seconds from the plaintext content state, or `0`:
    /// a value that is not finite, negative or past ``maxCountdownSeconds``
    /// (`1e300` would trap a plain `Int64(_:)`) is no countdown.
    static func countdownSeconds(_ raw: Double) -> Int64 {
        guard raw.isFinite, raw >= 0, raw <= Double(maxCountdownSeconds) else { return 0 }
        return Int64(raw.rounded(.down))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status == .unknown ? "pending" : status.rawValue, forKey: .status)
        try c.encode(countdownTarget, forKey: .countdownTarget)
        try c.encode(isOverdue, forKey: .isOverdue)
        try c.encode(confirmed, forKey: .confirmed)
        try c.encode(pendingConfirm, forKey: .pendingConfirm)
        try c.encode(timeFormatRaw, forKey: .timeFormatRaw)
    }

    /// The countdown's date, `nil` without one.
    public var countdownDate: Date? {
        countdownTarget > 0 ? Date(timeIntervalSince1970: TimeInterval(countdownTarget)) : nil
    }

    /// Whether the dose is still to be taken.
    public var isOpen: Bool {
        [.pending, .due, .overdue, .snoozed].contains(status) && !confirmed
    }
}

#if canImport(ActivityKit)
    /// `{"v":1}`: nothing about the dose.
    public struct HealthLogDoseAttributes: ActivityAttributes {
        public typealias ContentState = HealthLogDoseContentState
        public var v: Int

        public init(v: Int = 1) {
            self.v = v
        }
    }
#endif

/// The name of the started dose, as the app resolved it from its own server
/// (`push.device.liveActivityStarted`), shared with the widget through the
/// App Group. Never filled from a push.
public struct RelayLiveActivityLabel: Codable, Sendable, Equatable {
    public let medicationId: String
    public let slotInstant: Date?
    public let title: String
    public let detail: String?

    public static let filename = "relay-live-activity-label.json"

    public init(medicationId: String, slotInstant: Date?, title: String, detail: String?) {
        self.medicationId = medicationId
        self.slotInstant = slotInstant
        self.title = title
        self.detail = detail
    }

    public static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroup.identifier)?
            .appendingPathComponent(filename, isDirectory: false)
    }

    public static func read(url: URL? = url) -> RelayLiveActivityLabel? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RelayLiveActivityLabel.self, from: data)
    }

    /// How far the countdown may sit from the label's slot and still name
    /// the same dose. The relay counts to the due time of the slot.
    public static let slotTolerance: TimeInterval = 90 * 60
    /// A snoozed dose counts to the end of its snooze, up to a day later.
    public static let snoozeReach: TimeInterval = 24 * 60 * 60

    /// **R1 (3), (12).** The label an Activity may show, else `nil` (the
    /// neutral title). Never while names stay off the lock screen, read at
    /// render time; and an open dose only while the countdown points at the
    /// label's slot, so the name of an earlier dose never sits on a later one.
    /// A finished dose (no countdown) keeps the label until the app clears it.
    public static func shown(
        _ label: RelayLiveActivityLabel?,
        for state: HealthLogDoseContentState,
        hideNames: Bool
    ) -> RelayLiveActivityLabel? {
        guard !hideNames, let label, !label.title.isEmpty else { return nil }
        guard state.isOpen, let target = state.countdownDate else { return label }
        guard let slot = label.slotInstant else { return nil }
        let offset = target.timeIntervalSince(slot)
        if abs(offset) <= slotTolerance { return label }
        if state.status == .snoozed, offset > 0, offset <= snoozeReach { return label }
        return nil
    }

    /// `nil` removes the label.
    public static func write(_ label: RelayLiveActivityLabel?, url: URL? = url) {
        guard let url else { return }
        guard let label else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(label) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // D4 (10): the label names a medication; it never goes into a backup.
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }
}
