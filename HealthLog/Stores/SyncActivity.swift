import Foundation
#if canImport(UIKit)
    import UIKit
#endif

// U1 (#16) — the vocabulary of the one sync-activity source.
//
// Before this file, "when did this device last sync" had one writer: the
// pull-to-refresh handshake (`SyncStateStore.lastHandshakeAt`). Apple Health
// uploads — the sample observer, the daily-statistics sweep, the workout
// importer, every background wake — never touched it, so the footer's
// "Zuletzt synchronisiert" read older than the data on the server, and on a
// cold launch it read nothing at all until the user pulled. The values here are
// what `SyncStateStore` now answers with; the store stays the single place
// every surface reads (footer, header glyph, status panel).

/// Whether a sync happened while the app was open or while iOS ran it in the
/// background. Shown with the last-sync time (", im Hintergrund"), because the
/// two answer different questions: "did my pull work" versus "does this phone
/// deliver on its own".
public enum SyncChannel: String, Sendable, Equatable, Codable {
    case foreground
    case background

    /// The channel of work happening right now. A delivery that arrives while
    /// the app is backgrounded is background work — iOS woke the process for
    /// it. Same rule `HealthLogStandard` uses for its observer evidence.
    @MainActor
    static var current: SyncChannel {
        #if canImport(UIKit)
            UIApplication.shared.applicationState == .background ? .background : .foreground
        #else
            .foreground
        #endif
    }
}

/// One moment the server accepted something from this device: a handshake, a
/// drained outbox, or an Apple Health upload the server stored.
public struct SyncActivity: Sendable, Equatable, Codable {
    public let at: Date
    public let channel: SyncChannel

    public init(at: Date, channel: SyncChannel) {
        self.at = at
        self.channel = channel
    }

    /// The newest of the candidates. Absent candidates are skipped; no
    /// candidate at all is `nil` — "never synced" is not a date.
    static func latest(_ candidates: [SyncActivity?]) -> SyncActivity? {
        candidates.compactMap(\.self).max { $0.at < $1.at }
    }
}

/// The states that need attention. A healthy account has none. INT-L (1.1.1):
/// each one shows as its own calm glyph in the slot next to the avatar (see
/// ``SyncSlotGlyph``), no longer as a badge on the avatar.
public enum SyncAttention: Sendable, Equatable {
    /// Writes the outbox gave up on (dead-lettered or discarded). Sticky until
    /// cleared, and outranks everything: this is data that did not arrive.
    case failedWrites(Int)
    /// The last handshake failed (offline, server down, session trouble).
    case failed
    /// Writes waiting in the outbox for the next reachable moment.
    case queued(Int)
    /// Nothing reached the server for longer than ``staleAfter``.
    case stale(since: Date)

    /// A day. Background delivery is at iOS's discretion and a quiet night is
    /// normal; a full day without any accepted upload or handshake is not.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    /// How long a write must have been waiting before the slot says so. An
    /// online edit sits in the outbox for a moment before the replay sends
    /// it; showing that moment would make every save blink.
    static let queuedAfter: TimeInterval = 10

    /// The pure decision, most serious first. While a sync is in flight only
    /// the sticky write failure may show — the in-flight sync is about to
    /// answer every other question, and a glyph that flickers on for the
    /// length of a pull is noise.
    static func resolve(
        isInFlight: Bool,
        failedWriteCount: Int,
        handshakeFailed: Bool,
        queuedWriteCount: Int,
        queuedSince: Date?,
        lastSync: SyncActivity?,
        now: Date
    ) -> SyncAttention? {
        if failedWriteCount > 0 { return .failedWrites(failedWriteCount) }
        if isInFlight { return nil }
        if handshakeFailed { return .failed }
        if queuedWriteCount > 0, let queuedSince, now.timeIntervalSince(queuedSince) >= queuedAfter {
            return .queued(queuedWriteCount)
        }
        if let lastSync, now.timeIntervalSince(lastSync.at) > staleAfter {
            return .stale(since: lastSync.at)
        }
        return nil
    }
}

/// What the top-bar sync glyph shows. `nil` is the resting state: the glyph is
/// not on screen at all.
public enum SyncIndicatorGlyph: Sendable, Equatable {
    /// Rotating `arrow.triangle.2.circlepath` (static under Reduce Motion).
    case syncing
    /// `checkmark` for the store's `.done` beat, then the glyph leaves.
    case done

    /// Driven by the same phase machine as the footer and the pull-to-refresh
    /// checkmark, so the three can never disagree. A failed handshake drops
    /// `.syncing → .idle` without `.done`: the glyph leaves without a
    /// checkmark and the attention glyph takes the slot.
    static func resolve(phase: SyncPhase, isLoading: Bool) -> SyncIndicatorGlyph? {
        switch phase {
        case .syncing: .syncing
        case .done: .done
        case .idle: isLoading ? .syncing : nil
        }
    }
}

/// INT-L (1.1.1) — **the one slot next to the avatar.** The avatar carries no
/// badge any more; whatever the slot shows is tappable and opens the sync
/// status panel. A running sync and its checkmark beat win, because they are
/// about to answer the question; once the beat is over, an attention state
/// stays until it clears. `nil` is the healthy resting state: nothing there.
public enum SyncSlotGlyph: Sendable, Equatable {
    case syncing
    case done
    case attention(SyncAttention)

    static func resolve(indicator: SyncIndicatorGlyph?, attention: SyncAttention?) -> SyncSlotGlyph? {
        switch indicator {
        case .syncing: .syncing
        case .done: .done
        case nil: attention.map(SyncSlotGlyph.attention)
        }
    }
}
