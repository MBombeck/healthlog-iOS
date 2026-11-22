import Foundation

/// **Push diagnostics — what reached this device, counted locally.**
///
/// Per class (alert, silent, Live Activity): how many pushes arrived, how
/// many were opened (an envelope that opened, or a plain push that was
/// shown), how many were discarded (an envelope that did not open, a template
/// v1 does not know, a Live Activity the relay started without consent), and
/// when the last one arrived. One App Group file, written under a lock by the
/// extension (alerts) and the app (silent pushes, Live Activities). Never sent
/// anywhere; wiped on sign-out.
public struct PushDeliveryCounters: Sendable {
    public static let filename = "push-delivery-counters.json"

    public enum Event: String, Codable, Sendable, CaseIterable {
        case received
        case opened
        case discarded
    }

    public enum PushClass: String, Codable, Sendable, CaseIterable {
        case alert
        case silent
        case liveActivity
    }

    /// The counters as read.
    public struct Snapshot: Codable, Sendable, Equatable {
        public var counts: [String: Int] = [:]
        public var lastDeliveryAt: Date?

        public init() {}

        public func count(_ event: Event, _ pushClass: PushClass) -> Int {
            counts[PushDeliveryCounters.key(event, pushClass)] ?? 0
        }

        public var isEmpty: Bool {
            counts.values.allSatisfy { $0 == 0 }
        }
    }

    private let url: URL?

    public init(url: URL? = RelayAppGroupFile.url(PushDeliveryCounters.filename)) {
        self.url = url
    }

    static func key(_ event: Event, _ pushClass: PushClass) -> String {
        "\(pushClass.rawValue).\(event.rawValue)"
    }

    public func note(_ event: Event, pushClass: PushClass, now: Date = .now) {
        guard let url else { return }
        _ = RelayAppGroupFile.withLock(url) {
            var snapshot = RelayAppGroupFile.read(Snapshot.self, from: url) ?? Snapshot()
            let key = Self.key(event, pushClass)
            snapshot.counts[key] = min((snapshot.counts[key] ?? 0) + 1, Int(Int32.max))
            if event == .received { snapshot.lastDeliveryAt = now }
            RelayAppGroupFile.write(snapshot, to: url)
        }
    }

    public func snapshot() -> Snapshot {
        guard let url else { return Snapshot() }
        let stored = RelayAppGroupFile.withLock(url) { RelayAppGroupFile.read(Snapshot.self, from: url) }
        return stored.flatMap(\.self) ?? Snapshot()
    }

    public func wipe() {
        RelayAppGroupFile.remove(url)
    }
}
