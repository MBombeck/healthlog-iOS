import Foundation

/// Build 273 (sync audit B3) — `WCSession.transferUserInfo` is at-least-once.
/// A watch action that is delivered twice (reconnect after a phone kill, a
/// retried transfer) must be handled once: the phone remembers the outcome it
/// produced per action id and answers a redelivery with that outcome instead
/// of recording a second intake / mood entry.
///
/// Bounded and persisted in `UserDefaults` (no health data: an opaque id and
/// a three-valued outcome), oldest ids evicted first.
public final class WatchActionReplayGuard: @unchecked Sendable {
    public static let capacity = 64
    private static let key = "hl.watch.actionOutcomes.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Insertion-ordered `[id, outcomeRaw]` pairs.
    private var entries: [[String]]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = (defaults.array(forKey: Self.key) as? [[String]]) ?? []
    }

    /// The outcome already produced for `id`, or `nil` when the action is new.
    public func priorOutcome(for id: String) -> WatchAckOutcome? {
        lock.lock()
        defer { lock.unlock() }
        guard let pair = entries.last(where: { $0.first == id }), pair.count == 2 else { return nil }
        return WatchAckOutcome(rawValue: pair[1])
    }

    /// Record the outcome for `id`, evicting the oldest entries past capacity.
    public func remember(_ id: String, outcome: WatchAckOutcome) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.first == id }
        entries.append([id, outcome.rawValue])
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        defaults.set(entries, forKey: Self.key)
    }
}
