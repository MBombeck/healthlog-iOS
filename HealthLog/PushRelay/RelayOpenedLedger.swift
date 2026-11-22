import Foundation

// **#190 5.3 and 5.6 — what this device opened.**
//
// One App Group file, written under a lock by the extension (alerts) and the
// app (silent pushes). It answers two questions:
//
// - the verified list: was the notification behind a tap or an action opened
//   from a valid envelope? Only those may act; everything else opens Home.
// - the receipts: which envelope ids per class arrived, reported in
//   `/api/sync/state` so the server can tell pushes the relay accepted but
//   never delivered.

/// Whether this install refuses unsealed content. On once the server seals
/// for this device (`push.device.envelope == 1`, through the relay or its own
/// APNs key); the extension reads it from the App Group, because it cannot ask
/// the server.
public enum RelayEnvelopeMode {
    static let defaultsKey = "hl.pushRelay.envelopeMode"

    public static func isOn(defaults: UserDefaults? = UserDefaults(suiteName: RelayAppGroupFile.appGroup)) -> Bool {
        defaults?.bool(forKey: defaultsKey) ?? false
    }

    public static func set(_ on: Bool, defaults: UserDefaults? = UserDefaults(suiteName: RelayAppGroupFile.appGroup)) {
        if on {
            defaults?.set(true, forKey: defaultsKey)
        } else {
            defaults?.removeObject(forKey: defaultsKey)
        }
    }
}

public struct RelayOpenedLedger: Sendable {
    public static let filename = "push-relay-opened.json"
    /// Kept per class for the receipts, and for the verified list in total.
    static let receiptsPerClass = 10
    static let maxEntries = 64

    public struct Entry: Codable, Sendable, Equatable {
        /// `UNNotificationRequest.identifier`; `nil` for a silent push.
        public let requestId: String?
        public let envelopeId: String
        public let type: String
        public let pushClass: RelayPushClass
        /// The route the plaintext names, if any (`medication:<id>`).
        public let target: String?
        public let openedAt: Date
    }

    private let url: URL?

    public init(url: URL? = RelayAppGroupFile.url(RelayOpenedLedger.filename)) {
        self.url = url
    }

    public func record(_ entry: Entry) {
        guard let url else { return }
        _ = RelayAppGroupFile.withLock(url) {
            var entries = RelayAppGroupFile.read([Entry].self, from: url) ?? []
            entries.removeAll { $0.envelopeId == entry.envelopeId }
            entries.append(entry)
            if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
            RelayAppGroupFile.write(entries, to: url)
        }
    }

    public func entries() -> [Entry] {
        guard let url else { return [] }
        return RelayAppGroupFile.withLock(url) { RelayAppGroupFile.read([Entry].self, from: url) ?? [] } ?? []
    }

    /// The verified entry for a delivered notification, if it was opened.
    public func verified(requestId: String) -> Entry? {
        entries().last { $0.requestId == requestId }
    }

    /// The last opened envelope ids, newest last, per class.
    public func receipts() -> [RelayPushClass: [String]] {
        var result: [RelayPushClass: [String]] = [:]
        for pushClass in RelayPushClass.allCases {
            let ids = entries().filter { $0.pushClass == pushClass }.map(\.envelopeId)
            if !ids.isEmpty { result[pushClass] = Array(ids.suffix(Self.receiptsPerClass)) }
        }
        return result
    }

    public func wipe() {
        RelayAppGroupFile.remove(url)
    }
}

/// The receipts as query items of `GET /api/sync/state` (#191):
/// `openedAlert` and `openedSilent`, each the newest envelope id this device
/// opened in that class. The server answers `push.receiptsRecorded`. Empty
/// unless the server seals for this device.
public enum RelayReceiptQuery {
    static let names: [RelayPushClass: String] = [.alert: "openedAlert", .silent: "openedSilent"]

    public static func items(
        ledger: RelayOpenedLedger = RelayOpenedLedger(),
        envelopeMode: Bool = RelayEnvelopeMode.isOn()
    ) -> [(String, String)] {
        guard envelopeMode else { return [] }
        let receipts = ledger.receipts()
        return [RelayPushClass.alert, .silent].compactMap { pushClass in
            guard let name = names[pushClass], let newest = receipts[pushClass]?.last else { return nil }
            return (name, newest)
        }
    }
}
