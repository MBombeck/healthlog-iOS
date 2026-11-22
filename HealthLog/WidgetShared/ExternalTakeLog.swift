import Foundation

/// **#188 (7) — a dose taken outside the app can be undone on the next open.**
///
/// A take from the notification, the widget, the Live Activity, the critical
/// alarm or the Watch had no undo at all: the app was not on screen to show
/// one. Each of those paths records the take here (App Group file, shared
/// with the widget extension), and the next foreground of the app offers one
/// undo for the newest entry ("Just logged as taken"). The undo deletes the
/// intake through the existing route. One tap is therefore enough on every
/// surface; the two-tap confirm is gone where this undo now exists.
///
/// **R1 (1) — an undo removes only the take this device wrote.** Each entry
/// carries the row id the server answered with and the idempotency key the
/// write went out under. The undo looks for exactly that row; a take someone
/// else recorded on the same slot (the pill box, the web) is never offered.
/// An answer of `alreadyTaken` wrote nothing, so it is never logged.
public struct ExternalTakeLog: Sendable {
    public enum Source: String, Codable, Sendable {
        case notification
        case widget
        case liveActivity
        case alarm
        case watch
    }

    /// What ties an entry to the row this device wrote: the row id from the
    /// server's answer and the idempotency key of the write. A queued write
    /// has only the key; the row it creates carries it once it lands.
    public struct Binding: Sendable, Equatable {
        public let rowID: String?
        public let idempotencyKey: String?

        public init(rowID: String?, idempotencyKey: String?) {
            self.rowID = rowID?.isEmpty == false ? rowID : nil
            self.idempotencyKey = idempotencyKey?.isEmpty == false ? idempotencyKey : nil
        }

        /// Whether there is anything to find the row by.
        public var isEmpty: Bool {
            rowID == nil && idempotencyKey == nil
        }

        /// The binding of one take from outside the app, or `nil` when it
        /// must not be offered for undo: nothing was written (signed out, a
        /// dropped write) or the slot was taken already (`alreadyTaken`, the
        /// row belongs to someone else). A landed write binds row and key, a
        /// durably queued one the key alone.
        public static func forCommit(
            error: Error?,
            receipt: ReminderIntakeReceipt?,
            idempotencyKey: String
        ) -> Binding? {
            guard let error else {
                return Binding(rowID: receipt?.rowID, idempotencyKey: idempotencyKey)
            }
            if error is MedicationAlreadyTaken { return nil }
            if let hlError = error as? HLError, hlError.shouldPersistToOutbox {
                return Binding(rowID: nil, idempotencyKey: idempotencyKey)
            }
            return nil
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let medicationId: String
        public let scheduledFor: Date
        public let source: Source
        public let at: Date
        /// The row the take wrote. `nil` on entries of older builds, which
        /// are therefore never offered (update path).
        public let rowID: String?
        /// The idempotency key the take went out under.
        public let idempotencyKey: String?

        public init(
            medicationId: String,
            scheduledFor: Date,
            source: Source,
            at: Date,
            rowID: String? = nil,
            idempotencyKey: String? = nil
        ) {
            self.medicationId = medicationId
            self.scheduledFor = scheduledFor
            self.source = source
            self.at = at
            self.rowID = rowID
            self.idempotencyKey = idempotencyKey
        }

        public var binding: Binding {
            Binding(rowID: rowID, idempotencyKey: idempotencyKey)
        }
    }

    /// How long "just logged" holds: older takes are not offered any more.
    public static let offerWindow: TimeInterval = 30 * 60

    /// Entries kept at most; the oldest fall off.
    static let capacity = 8

    private let url: URL?

    public init(url: URL? = WidgetAppGroup.externalTakeLogURL()) {
        self.url = url
    }

    /// Notes one take. Without a binding nothing is noted: a take that
    /// cannot be told apart from someone else's is never offered for undo.
    public func record(
        medicationId: String,
        scheduledFor: Date,
        source: Source,
        binding: Binding?,
        now: Date = .now
    ) {
        guard let binding, !binding.isEmpty else { return }
        var entries = read()
        entries.removeAll { $0.medicationId == medicationId && abs($0.scheduledFor.timeIntervalSince(scheduledFor)) < 1 }
        entries.append(Entry(
            medicationId: medicationId,
            scheduledFor: scheduledFor,
            source: source,
            at: now,
            rowID: binding.rowID,
            idempotencyKey: binding.idempotencyKey
        ))
        write(Array(entries.suffix(Self.capacity)))
    }

    public func read() -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    /// The newest entry still inside ``offerWindow`` that `isUndoable`
    /// accepts (its row is on today's list), so every take is offered once.
    ///
    /// **R1 (9).** Only what is settled leaves the log: the offered entry,
    /// every older one (one undo per open, the newest wins) and every expired
    /// one. A newer take whose row the list does not carry yet stays for the
    /// next open, instead of being thrown away unseen.
    public func takeOffer(now: Date = .now, isUndoable: (Entry) -> Bool = { _ in true }) -> Entry? {
        let entries = read()
        guard !entries.isEmpty else { return nil }
        let live = entries.filter { Self.isInWindow($0, now: now) }
        let offer = live.filter(isUndoable).max { $0.at < $1.at }
        let kept = live.filter { entry in
            guard let offer else { return true }
            return entry.at > offer.at && entry != offer
        }
        if kept.isEmpty {
            clear()
        } else if kept != entries {
            write(kept)
        }
        return offer
    }

    static func isInWindow(_ entry: Entry, now: Date) -> Bool {
        let age = now.timeIntervalSince(entry.at)
        return age >= 0 && age <= offerWindow
    }

    static func offer(in entries: [Entry], now: Date) -> Entry? {
        entries.filter { isInWindow($0, now: now) }.max { $0.at < $1.at }
    }

    public func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ entries: [Entry]) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? SensitiveDataBackupExclusion.secureCreatedItem(at: url)
    }
}
