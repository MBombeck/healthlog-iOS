import Foundation
@testable import HealthLog
import Testing

/// The two-tap confirm as timeline frames, and the snapshot stamp that has to
/// move forward even when nothing about the doses changed.
@MainActor
@Suite("Widget timeline frames and snapshot stamp")
struct WidgetTimelineFramesTests {
    private let armedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let window = WidgetPendingConfirmStore.pendingConfirmWindow

    // MARK: - Confirm frames

    @Test("armed: a confirm frame now and a plain frame exactly when the window closes")
    func armedFrames() {
        let now = armedAt.addingTimeInterval(1)
        let frames = WidgetTimelinePolicy.pendingConfirmFrames(now: now, armedAt: armedAt, window: window)
        #expect(frames.count == 2)
        #expect(frames[0].date == now)
        #expect(frames[0].armed)
        #expect(frames[1].date == armedAt.addingTimeInterval(window))
        #expect(!frames[1].armed)
    }

    @Test("not armed or the window already closed: one plain frame")
    func plainFrames() {
        let plain = WidgetTimelinePolicy.pendingConfirmFrames(now: armedAt, armedAt: nil, window: window)
        #expect(plain.count == 1)
        #expect(!plain[0].armed)
        let closed = WidgetTimelinePolicy.pendingConfirmFrames(
            now: armedAt.addingTimeInterval(window + 1),
            armedAt: armedAt,
            window: window
        )
        #expect(closed.count == 1)
        #expect(!closed[0].armed)
    }

    @Test("the plain frame never comes before the intent stops treating a tap as the confirming one")
    func plainFrameNotEarly() {
        let frames = WidgetTimelinePolicy.pendingConfirmFrames(now: armedAt, armedAt: armedAt, window: window)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetPendingConfirmStore(url: url)
        try? store.arm(medicationId: "med-1", scheduledFor: armedAt, now: armedAt)
        let plainAt = frames[1].date
        // A moment after the plain frame shows, a tap is a first tap again.
        #expect(!store.armed(for: "med-1", scheduledFor: armedAt, now: plainAt.addingTimeInterval(0.01)))
        // While the confirm frame shows, a tap confirms.
        #expect(store.armed(for: "med-1", scheduledFor: armedAt, now: plainAt.addingTimeInterval(-0.5)))
    }

    // MARK: - Stamp

    @Test("an unchanged snapshot gets a fresh stamp after an hour or on a new day")
    func stampRule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 8)))
        #expect(!WidgetTimelinePolicy.needsFreshStamp(previous: morning, now: morning.addingTimeInterval(30 * 60), calendar: calendar))
        #expect(WidgetTimelinePolicy.needsFreshStamp(previous: morning, now: morning.addingTimeInterval(61 * 60), calendar: calendar))
        let lateEvening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 23, minute: 50)))
        #expect(WidgetTimelinePolicy.needsFreshStamp(
            previous: lateEvening,
            now: lateEvening.addingTimeInterval(20 * 60),
            calendar: calendar
        ))
    }

    @Test("writer: same doses two hours later still move generatedAt")
    func writerMovesStamp() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(url: url)
        let writer = WidgetSnapshotWriter(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 8)))
        let medication = Medication(
            id: "med-1",
            name: "Vitamin D",
            dose: "1000 IE",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 20, minute: 0)]),
            notificationsEnabled: true,
            active: true
        )
        let intake = try MedicationIntake(
            id: "med-1-20",
            medicationId: "med-1",
            scheduledAt: #require(calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now)),
            takenAt: nil,
            status: .pending
        )

        writer.refresh(medications: [medication], derivedIntakes: [intake], now: now)
        await writer.drainPendingWrites()
        let later = now.addingTimeInterval(2 * 60 * 60)
        writer.refresh(medications: [medication], derivedIntakes: [intake], now: later)
        await writer.drainPendingWrites()

        #expect(store.read()?.generatedAt == later)
    }
}
