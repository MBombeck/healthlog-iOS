import Foundation

/// What one app-side snapshot mutation decided, given the snapshot that was on
/// disk when it ran.
///
/// `skip` is the v0.12 W8-7 diff: `onIntakesDidChange` fires on every store load
/// including idempotent revalidations, so an update whose widget-bearing fields
/// are byte-identical must burn neither a write nor a per-kind timeline reload.
/// The decision is made **inside** the persistence boundary, against the
/// snapshot that boundary just read, because a diff taken against a snapshot
/// read earlier is a diff against a snapshot that may no longer exist.
enum WidgetSnapshotDecision: Sendable {
    case skip
    case write(WidgetSnapshot, reloadKinds: [String])
}

/// **Phase 09 / plan 09-03 — the app-side widget snapshot boundary.**
///
/// Five call sites (medication schedule, mood glance, health score, latest
/// measurement, logout reset) each did read → modify → encode → write against
/// the App Group container, synchronously, on the main actor. Two of those
/// properties are in tension: main-actor isolation is what made the
/// read-modify-write atomic, and it is also what made a blocking file operation
/// land on the frame-producing thread.
///
/// Serialization moves here, so the write can leave the main actor without the
/// updates being able to clobber each other. One boundary, one operation at a
/// time, no interleaving between a read and the write derived from it.
///
/// **The extension is not affected.** `WidgetSnapshotStore` — including its
/// `.completeFileProtectionUntilFirstUserAuthentication` write and its backup
/// exclusion — is unchanged and still shared with `HealthLogWidgets`, whose
/// `TimelineProvider`s keep their small synchronous reads. This type is the
/// *app* side only.
actor WidgetSnapshotPersistence {
    private let store: WidgetSnapshotStore
    /// The account generation this boundary is serving. Bumped by the logout
    /// reset; anything older is refused.
    private var acceptedEpoch: UInt64 = 0

    init(store: WidgetSnapshotStore) {
        self.store = store
    }

    /// Read the current snapshot, let `mutate` decide against it, and write the
    /// result. Returns the widget kinds whose timelines the caller should
    /// reload — the empty array when the update was a no-op or was refused.
    ///
    /// `mutate` is deliberately **synchronous**. An actor method that awaits is
    /// reentrant, and a reentrant read-modify-write is exactly the interleaving
    /// this boundary exists to prevent, so there is no suspension point between
    /// the read and the write derived from it.
    ///
    /// `epoch` is the account generation the operation was admitted under. An
    /// operation carrying a retired one is dropped: a callback belonging to a
    /// signed-out account must not land after the logout placeholder.
    func apply(
        epoch: UInt64,
        _ mutate: @Sendable (WidgetSnapshot?) -> WidgetSnapshotDecision
    ) throws -> [String] {
        guard epoch >= acceptedEpoch else { return [] }
        switch mutate(store.read()) {
        case .skip:
            return []
        case let .write(snapshot, reloadKinds):
            try store.write(snapshot)
            return reloadKinds
        }
    }

    /// Adopt a new account generation. Every operation still carrying an older
    /// one is refused from here on.
    func adopt(epoch: UInt64) {
        acceptedEpoch = epoch
    }
}

/// **Phase 09 / plan 09-03 — admission and ordering for the widget writer.**
///
/// `WidgetSnapshotWriter` is a `struct` that every store callback copies, so the
/// state those copies must agree on lives here, behind one reference held by all
/// of them: is the writer admitting work at all, which account generation is it
/// admitting it for, and what is the operation currently at the end of the
/// queue.
///
/// **Ordering is by explicit predecessor, not by hope.** Each enqueued operation
/// awaits the task that was at the tail when it was appended. Appending happens
/// synchronously on the main actor, inside the same callback that snapshotted
/// the value being written, so the write order is the callback order — there is
/// no free-standing `Task` racing the queue.
@MainActor
final class WidgetWriteSequencer {
    private let persistence: WidgetSnapshotPersistence
    /// The operation currently at the end of the queue. Awaiting it awaits the
    /// whole chain, because every operation awaits its own predecessor.
    private var tail: Task<Void, Never>?
    /// The account generation new operations are stamped with.
    private var epoch: UInt64 = 0
    /// Closed by ``reset(_:)`` and re-opened only by ``admitNextAccount()``.
    private var admitted = true

    init(persistence: WidgetSnapshotPersistence) {
        self.persistence = persistence
    }

    /// Append `operation` behind everything already accepted. A refused
    /// operation (admission closed after logout) is dropped, not queued.
    func enqueue(_ operation: @escaping @MainActor (UInt64) async -> Void) {
        guard admitted else { return }
        let predecessor = tail
        let stampedEpoch = epoch
        tail = Task { @MainActor in
            await predecessor?.value
            await operation(stampedEpoch)
        }
    }

    /// Close admission, retire the current account generation, drain everything
    /// already accepted, and only then run the placeholder write.
    ///
    /// The order matters in both directions. Retiring the epoch *before* the
    /// drain means an operation that has not yet reached the boundary is refused
    /// rather than raced; draining *before* the placeholder means an operation
    /// that already reached it cannot still be in flight when the clear lands.
    func reset(_ placeholder: @MainActor (UInt64) async throws -> Void) async throws {
        admitted = false
        epoch &+= 1
        let retiredTail = tail
        tail = nil
        let currentEpoch = epoch
        await persistence.adopt(epoch: currentEpoch)
        await retiredTail?.value
        try await placeholder(currentEpoch)
    }

    /// Await every operation accepted so far.
    func drain() async {
        await tail?.value
    }

    /// Re-open admission for the next authenticated composition.
    func admitNextAccount() {
        admitted = true
    }
}
