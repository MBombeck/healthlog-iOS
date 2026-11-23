import Foundation

// W1 (1.3.0, #126 1.1/1.3, HealthLog#1173) — "N Einträge warten auf
// Verbindung" counts only rows the replay can still send.
//
// Up to 1.2.0 the banner and the slot glyph took `ops.count` of the live
// snapshot (`SyncStateStore.bindOutbox`). That snapshot also carries rows the
// replay never sends on its own: rows it parked (`parked:` marker, see
// `HealthKitReplayParked`), rows whose retry budget ran out (held until the
// seven-day dead-letter sweep), rows of another account and rows this build
// cannot attribute. The count therefore stood at "6" for days while every
// sync around it succeeded. The count now asks the same questions the replay
// asks before it sends, and the rows it leaves out are listed in Sync
// Diagnostics with their reason and "Erneut senden".

/// Why the replay holds a live row back instead of sending it on its own.
enum OutboxHoldReason: Hashable, Sendable {
    /// The server answered the page with a 4xx that names no row
    /// (`parked:not_stored`): a real refusal, not a connection problem.
    case serverRefused(status: Int)
    /// The module that owns the write is switched off for this account.
    case moduleDisabled(String)
    /// The server cannot map the reading's type yet.
    case unmappable
    /// The server refused rows, but the refusal could not be kept on this
    /// device.
    case refusalNotRecorded
    /// The retry budget ran out; the row waits for the age-gated sweep.
    case retryBudgetExhausted

    /// Reads the `parked:` marker `HealthKitReplayParked` writes into
    /// `lastError`; `nil` for any other note.
    init?(parkedMarker lastError: String?) {
        let prefix = HealthKitReplayParked.lastErrorPrefix
        guard let lastError, lastError.hasPrefix(prefix) else { return nil }
        let body = lastError.dropFirst(prefix.count)
        if body.hasPrefix("not_stored") {
            self = .serverRefused(status: Self.value(after: "status=", in: body).flatMap { Int($0) } ?? 0)
        } else if body.hasPrefix("module_disabled") {
            self = .moduleDisabled(Self.value(after: "module=", in: body) ?? "")
        } else if body.hasPrefix("unmappable_identifier") {
            self = .unmappable
        } else {
            self = .refusalNotRecorded
        }
    }

    private static func value(after key: String, in body: Substring) -> String? {
        guard let range = body.range(of: key) else { return nil }
        let value = body[range.upperBound...].prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }
}

/// One line of the "held back" list: a reason and how many rows carry it.
struct OutboxHeldGroup: Hashable, Sendable {
    let reason: OutboxHoldReason
    let count: Int
}

extension OutboxQueue.Operation {
    /// Why the replay will not send this row on its own, or `nil` when it
    /// will (possibly after its back-off).
    func holdReason(maxAttempts: Int) -> OutboxHoldReason? {
        if let parked = OutboxHoldReason(parkedMarker: lastError) { return parked }
        if attempts >= maxAttempts { return .retryBudgetExhausted }
        return nil
    }

    /// Whether this row is the signed-in account's and the replay would send
    /// it: the gates of `OutboxReplayService.runOnce`, in the same order.
    func belongs(to currentUserID: String?) -> Bool {
        if delivered { return false }
        if quarantineReason(currentUserID: currentUserID) != nil { return false }
        if let owner = ownerUserID, owner != currentUserID { return false }
        return true
    }
}

extension OutboxQueue {
    /// The rows of `ops` that still wait to be sent for the signed-in account.
    /// This is the number behind "N Einträge warten auf Verbindung" and the
    /// `icloud.slash` glyph.
    func waitingCount(
        in ops: [Operation],
        maxAttempts: Int = OutboxReplayService.defaultMaxAttempts
    ) -> Int {
        let user = currentOwnerProvider()
        // A row whose first send is still running is not waiting for anything.
        return ops.count {
            !liveSendIDs.contains($0.id) && $0.belongs(to: user) && $0.holdReason(maxAttempts: maxAttempts) == nil
        }
    }

    /// The signed-in account's held rows, grouped by reason (largest group
    /// first), for Sync Diagnostics.
    func heldGroups(maxAttempts: Int = OutboxReplayService.defaultMaxAttempts) async -> [OutboxHeldGroup] {
        let user = currentOwnerProvider()
        var counts: [OutboxHoldReason: Int] = [:]
        for op in await snapshot where op.belongs(to: user) {
            if let reason = op.holdReason(maxAttempts: maxAttempts) { counts[reason, default: 0] += 1 }
        }
        return counts.map { OutboxHeldGroup(reason: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : "\($0.reason)" < "\($1.reason)" }
    }

    /// "Erneut senden": every held row of the signed-in account gets its
    /// budget back and loses its park marker, so the next replay pass sends
    /// it. A row the server still refuses is parked again with its reason.
    /// Returns the number of rows re-armed.
    @discardableResult
    func rearmHeld(maxAttempts: Int = OutboxReplayService.defaultMaxAttempts) async throws -> Int {
        let user = currentOwnerProvider()
        let held = await snapshot.filter { $0.belongs(to: user) && $0.holdReason(maxAttempts: maxAttempts) != nil }
        guard !held.isEmpty else { return 0 }
        let store = await resolvedStore()
        var rearmed = 0
        for op in held {
            let didRearm = try await store.rearm(id: op.id)
            rearmed += didRearm ? 1 : 0
        }
        await broadcast()
        return rearmed
    }

    /// The update path from 1.2.0, see
    /// ``OutboxStore/requeueRetriableRowsOverBudget(maxAttempts:keepingMarkers:)``.
    func requeueRetriableRowsOverBudget(maxAttempts: Int) async throws -> Int {
        let markers = [HealthKitReplayParked.lastErrorPrefix, OutboxReplayService.unconfirmedPrefix]
        let count = try await resolvedStore().requeueRetriableRowsOverBudget(
            maxAttempts: maxAttempts,
            keepingMarkers: markers
        )
        if count > 0 { await broadcast() }
        return count
    }

    /// The rows of `owner` the store had to delete unread since the last
    /// call, see ``OutboxStore/discardUnreadable(_:)``.
    func takeUnreadableDiscards(ownedBy owner: String) async -> [OutboxUnreadableDiscard] {
        await resolvedStore().takeUnreadableDiscards(ownedBy: owner)
    }

    /// See ``OutboxStore/resetAttempts(ownedBy:keepingMarkers:)``. Parked and
    /// unconfirmed rows keep their budget, as in the update path above.
    @discardableResult
    func resetAttempts(ownedBy owner: String) async throws -> Int {
        let markers = [HealthKitReplayParked.lastErrorPrefix, OutboxReplayService.unconfirmedPrefix]
        let count = try await resolvedStore().resetAttempts(ownedBy: owner, keepingMarkers: markers)
        if count > 0 { await broadcast() }
        return count
    }
}
