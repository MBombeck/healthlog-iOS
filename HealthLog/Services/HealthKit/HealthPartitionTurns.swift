import Foundation

/// One live leg per account and type at a time.
///
/// An observer delivery and a pass from the window can reach the same
/// collector together, and the collector is an actor that suspends while a
/// page is read and sent. Without turns both could read the same committed
/// anchor and send the same page twice. A leg takes its turn before it reads
/// the anchor and gives it back after its last commit, so the second leg
/// starts from the cursor the first one left.
actor HealthPartitionTurns {
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// The turn key of one partition. Kept in memory only, never logged.
    static func key(ownerID: String, typeIdentifier: String) -> String {
        "\(ownerID)\u{1F}\(typeIdentifier)"
    }

    /// Waits until no other leg holds `key`, then holds it.
    func acquire(_ key: String) async {
        guard busy.contains(key) else {
            busy.insert(key)
            return
        }
        await withCheckedContinuation { waiting[key, default: []].append($0) }
    }

    /// Hands `key` to the next waiting leg, or frees it.
    func release(_ key: String) {
        guard var queue = waiting[key], !queue.isEmpty else {
            busy.remove(key)
            waiting[key] = nil
            return
        }
        let next = queue.removeFirst()
        waiting[key] = queue.isEmpty ? nil : queue
        next.resume()
    }

    /// Whether a leg holds `key` (for tests).
    func isHeld(_ key: String) -> Bool {
        busy.contains(key)
    }
}
