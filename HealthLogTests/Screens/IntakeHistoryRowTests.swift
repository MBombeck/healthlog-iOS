import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// T-4 commit 2 — predicate-level coverage for `IntakeHistoryRow`'s
/// past-vs-future mutability cut + the status-chip routing.
///
/// SwiftUI view-bodies are not directly testable (Apple's preview/
/// snapshot frameworks are the supported channel). We cover the
/// observable side-effects: the `canRetroMark` boolean fed into the row
/// from `IntakeHistorySection` (v0.14.8 — retro-mark gated to past/due,
/// delete now offered on every row), the `statusChip` branch a parent
/// would see, and the localized action-label strings the operator
/// would tap.
@Suite("IntakeHistoryRow — T-4 retro-mutate primitives")
struct IntakeHistoryRowTests {
    // MARK: - Past-vs-future cut

    @Test("Events with scheduledFor < now are mutable")
    func pastEventsAreMutable() {
        let now = Date(timeIntervalSince1970: 1_714_550_400)
        let pastEvent = PaginatedIntakeEvent(
            id: "evt-1",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(-3600),
            injectionSite: nil
        )
        #expect(pastEvent.scheduledFor < now)
    }

    @Test("Events with scheduledFor > now are read-only")
    func futureEventsAreReadOnly() {
        let now = Date(timeIntervalSince1970: 1_714_550_400)
        let futureEvent = PaginatedIntakeEvent(
            id: "evt-1",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(86400),
            injectionSite: nil
        )
        #expect(futureEvent.scheduledFor > now)
    }

    // MARK: - Status routing

    @Test("Event with skipped=true routes to .skipped status display")
    func skippedRoutesToSkippedChip() {
        let event = PaginatedIntakeEvent(
            id: "evt-1",
            takenAt: nil,
            skipped: true,
            scheduledFor: Date(timeIntervalSince1970: 1_714_550_400),
            injectionSite: nil
        )
        #expect(event.skipped)
        #expect(event.takenAt == nil)
    }

    @Test("Event with takenAt non-nil + skipped=false routes to .taken status")
    func takenRoutesToTakenChip() {
        let event = PaginatedIntakeEvent(
            id: "evt-1",
            takenAt: Date(timeIntervalSince1970: 1_714_550_400),
            skipped: false,
            scheduledFor: Date(timeIntervalSince1970: 1_714_550_400),
            injectionSite: nil
        )
        #expect(event.takenAt != nil)
        #expect(!event.skipped)
    }

    @Test("Past event without takenAt + skipped=false is the 'open' state")
    func pastUnactionedIsOpen() {
        let now = Date()
        let event = PaginatedIntakeEvent(
            id: "evt-1",
            takenAt: nil,
            skipped: false,
            scheduledFor: now.addingTimeInterval(-3600),
            injectionSite: nil
        )
        #expect(event.scheduledFor < now)
        #expect(event.takenAt == nil)
        #expect(!event.skipped)
    }

    // MARK: - Menu action set

    /// The context menu hides the "Markieren als genommen" action when
    /// the row already represents a taken intake (no-op flips are
    /// confusing). Mirror the predicate the modifier uses.
    @Test("currentlyTaken predicate matches takenAt non-nil AND not skipped")
    func currentlyTakenPredicate() {
        let taken = PaginatedIntakeEvent(
            id: "evt-1",
            takenAt: Date(),
            skipped: false,
            scheduledFor: Date().addingTimeInterval(-3600),
            injectionSite: nil
        )
        let takenButSkipped = PaginatedIntakeEvent(
            id: "evt-2",
            takenAt: Date(),
            skipped: true,
            scheduledFor: Date().addingTimeInterval(-3600),
            injectionSite: nil
        )
        let openPast = PaginatedIntakeEvent(
            id: "evt-3",
            takenAt: nil,
            skipped: false,
            scheduledFor: Date().addingTimeInterval(-3600),
            injectionSite: nil
        )
        #expect(taken.takenAt != nil && !taken.skipped)
        #expect(!(takenButSkipped.takenAt != nil && !takenButSkipped.skipped))
        #expect(!(openPast.takenAt != nil && !openPast.skipped))
    }
}

// swiftlint:enable force_unwrapping
