import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.12 W8-7** — pins the widget-writer diff: an idempotent `refresh` that
/// produces byte-identical dose + compliance data must NOT re-write the
/// snapshot (and therefore must not reload the timelines), while a genuine
/// change still writes through. Proxy for "skipped reload": the persisted
/// `generatedAt` only advances when the writer actually wrote.
@Suite("WidgetSnapshotWriter — diff before reload")
@MainActor
struct WidgetWriterDiffTests {
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = 1
        comps.hour = 8
        return Calendar.current.date(from: comps)!
    }

    private func med(times: [TimeOfDay]) -> Medication {
        Medication(
            id: "med-1",
            name: "Vitamin D",
            dose: "1000 IE",
            schedule: MedicationSchedule(times: times),
            notificationsEnabled: true,
            active: true
        )
    }

    private func intake(hour: Int, status: IntakeStatus) -> MedicationIntake {
        let scheduled = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
        return MedicationIntake(
            id: "med-1-\(hour)",
            medicationId: "med-1",
            scheduledAt: scheduled,
            takenAt: status == .taken ? now : nil,
            status: status
        )
    }

    private func makeWriter() -> (WidgetSnapshotWriter, WidgetSnapshotStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w8-widget-\(UUID().uuidString).json")
        let store = WidgetSnapshotStore(url: url)
        return (WidgetSnapshotWriter(store: store), store)
    }

    @Test("Identical idempotent refresh skips the re-write (generatedAt frozen)")
    func skipsIdenticalRewrite() async {
        let (writer, store) = makeWriter()
        let meds = [med(times: [TimeOfDay(hour: 9, minute: 0)])]
        let intakes = [intake(hour: 9, status: .pending)]

        // 09-03 — the write is queued now, so the assertion waits for the
        // operation it is about, not for a synchronous side effect.
        writer.refresh(medications: meds, derivedIntakes: intakes, now: now)
        await writer.drainPendingWrites()
        let firstStamp = store.read()?.generatedAt
        #expect(firstStamp != nil)

        // Same data, 5 minutes later. The diff must suppress the write, so the
        // persisted generatedAt stays pinned to the first write.
        writer.refresh(medications: meds, derivedIntakes: intakes, now: now.addingTimeInterval(300))
        await writer.drainPendingWrites()
        #expect(store.read()?.generatedAt == firstStamp)
    }

    @Test("A real change writes through (generatedAt advances)")
    func writesThroughOnChange() async {
        let (writer, store) = makeWriter()
        let meds = [med(times: [TimeOfDay(hour: 9, minute: 0)])]

        writer.refresh(medications: meds, derivedIntakes: [intake(hour: 9, status: .pending)], now: now)

        // Mark the 09:00 dose taken — compliance changes → must re-write.
        let later = now.addingTimeInterval(300)
        writer.refresh(medications: meds, derivedIntakes: [intake(hour: 9, status: .taken)], now: later)
        await writer.drainPendingWrites()
        #expect(store.read()?.generatedAt == later)
    }

    @Test("Mood refresh skips when the glance is unchanged")
    func skipsIdenticalMood() async {
        let (writer, store) = makeWriter()
        let mood = WidgetSnapshot.RecentMood(score: 4, loggedAt: now)

        writer.refreshMood(recentMood: mood, now: now)
        await writer.drainPendingWrites()
        let firstStamp = store.read()?.generatedAt

        writer.refreshMood(recentMood: mood, now: now.addingTimeInterval(300))
        await writer.drainPendingWrites()
        #expect(store.read()?.generatedAt == firstStamp)
    }

    // MARK: - Phase 09 / plan 09-03 — the app-side boundary is serialized

    /// **Why this is a real property and not a hypothetical one.**
    ///
    /// The app-side snapshot path is read → modify → encode → write against one
    /// App-Group file, and `WidgetSnapshotStore` provides no atomicity across
    /// those four steps. What has been standing in for atomicity is the
    /// incidental fact that all five callers happened to be synchronous on the
    /// main actor — which is also precisely the property 09-03 removes, because
    /// a synchronous main-actor caller is a blocking file operation on the
    /// frame-producing thread.
    ///
    /// So the serialization has to move into the boundary itself, and this case
    /// drives that boundary the way concurrent callers will: four kinds
    /// (medication, mood, score, latest measurement), 100 operations, each
    /// preserving every field it did not own. Every kind writes, so every kind's
    /// field must survive; a field that is `nil` at the end is a read-modify-write
    /// whose write landed on top of a snapshot it never saw.
    @Test("100 interleaved widget updates end with every latest field")
    func interleavedUpdatesPreserveAllLatestFields() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w09-03-interleave-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(url: url)
        // Start from the neutral placeholder, so the file exists before the
        // concurrent phase and every field below is `nil` until some operation
        // sets it. A field still `nil` at the end is therefore a lost update,
        // not an absent fixture.
        try store.write(.placeholder)
        let persistence = WidgetSnapshotPersistence(store: store)
        let base = now

        let completed = await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 100 {
                let stamp = base.addingTimeInterval(Double(index))
                let kind = index % 4
                group.addTask {
                    let kinds = try? await persistence.apply(epoch: 0) { current in
                        Self.interleavedDecision(kind: kind, index: index, at: stamp, current: current)
                    }
                    return kinds != nil
                }
            }
            var done = 0
            for await succeeded in group where succeeded {
                done += 1
            }
            return done
        }
        #expect(completed == 100, "every operation the boundary accepted must complete")

        // Deliberately not `#require`: an unserialized boundary can also lose the
        // file itself (concurrent atomic writes race each other's rename), and
        // "there is no snapshot left" is the strongest possible form of "a latest
        // field was lost" — it must reach the marker, not abort before it.
        let final = store.read()
        var lost: [String] = []
        if final?.nextDose == nil { lost.append("nextDose") }
        if final?.recentMood == nil { lost.append("recentMood") }
        if final?.healthScore == nil { lost.append("healthScore") }
        if final?.latestMeasurement == nil { lost.append("latestMeasurement") }
        let everyLatestFieldSurvived = lost.isEmpty
        #expect(
            everyLatestFieldSurvived,
            "EXPECTED_RED: interleaved widget updates lost a latest field"
        )
    }

    /// **The other half of the contract: order.**
    ///
    /// Serialization alone would let the boundary run the queued operations in
    /// any order it liked, and the last value of each kind would then be
    /// whichever one happened to win. The facade appends each operation behind
    /// the one that was at the tail when the store callback fired, so the write
    /// order is the callback order — and 100 interleaved updates end with
    /// exactly each kind's *last* value, not merely with some value of each.
    @Test("the facade keeps each kind's last enqueued value, in callback order")
    func orderedFacadeKeepsEachKindsLastValue() async {
        let (writer, store) = makeWriter()
        let base = now
        var lastMood: WidgetSnapshot.RecentMood?
        var lastScore: WidgetSnapshot.HealthScoreGlance?
        var lastMeasurement: WidgetSnapshot.LatestMeasurement?

        for index in 0 ..< 100 {
            let stamp = base.addingTimeInterval(Double(index))
            switch index % 4 {
            case 0:
                writer.refresh(
                    medications: [med(times: [TimeOfDay(hour: 9, minute: 0)])],
                    derivedIntakes: [intake(hour: 9, status: index % 8 == 0 ? .pending : .taken)],
                    now: stamp
                )
            case 1:
                lastMood = WidgetSnapshot.RecentMood(score: (index % 5) + 1, loggedAt: stamp)
                writer.refreshMood(recentMood: lastMood, now: stamp)
            case 2:
                lastScore = WidgetSnapshot.HealthScoreGlance(score: 40 + index, band: "amber", resolvedAt: stamp)
                writer.refreshHealthScore(lastScore, now: stamp)
            default:
                lastMeasurement = WidgetSnapshot.LatestMeasurement(
                    kindRaw: "weight", title: "Weight",
                    formattedValue: "\(70 + index)", unit: "kg",
                    symbol: "scalemass", recordedAt: stamp
                )
                writer.refreshLatestMeasurement(lastMeasurement, now: stamp)
            }
        }
        await writer.drainPendingWrites()

        let final = store.read()
        #expect(final != nil, "the queue must have produced a snapshot")
        #expect(final?.recentMood == lastMood)
        #expect(final?.healthScore == lastScore)
        #expect(final?.latestMeasurement == lastMeasurement)
        #expect(final?.nextDose != nil, "the medication path's field survives every later kind's write")
    }

    /// One kind's update, shaped exactly like the production refresh paths: it
    /// owns one field and carries every other field through unchanged.
    private nonisolated static func interleavedDecision(
        kind: Int,
        index: Int,
        at stamp: Date,
        current: WidgetSnapshot?
    ) -> WidgetSnapshotDecision {
        let base = current ?? .placeholder
        let snapshot = switch kind {
        case 0:
            WidgetSnapshot(
                nextDose: .init(
                    medicationId: "med-\(index)",
                    medicationName: "Vitamin D",
                    doseText: "1000 IE",
                    scheduledAt: stamp
                ),
                compliance: base.compliance,
                recentMood: base.recentMood,
                healthScore: base.healthScore,
                latestMeasurement: base.latestMeasurement,
                timeFormatRaw: base.timeFormatRaw,
                generatedAt: stamp
            )
        case 1:
            WidgetSnapshot(
                nextDose: base.nextDose,
                compliance: base.compliance,
                recentMood: .init(score: (index % 5) + 1, loggedAt: stamp),
                healthScore: base.healthScore,
                latestMeasurement: base.latestMeasurement,
                timeFormatRaw: base.timeFormatRaw,
                generatedAt: stamp
            )
        case 2:
            WidgetSnapshot(
                nextDose: base.nextDose,
                compliance: base.compliance,
                recentMood: base.recentMood,
                healthScore: .init(score: 40 + index, band: "amber", resolvedAt: stamp),
                latestMeasurement: base.latestMeasurement,
                timeFormatRaw: base.timeFormatRaw,
                generatedAt: stamp
            )
        default:
            WidgetSnapshot(
                nextDose: base.nextDose,
                compliance: base.compliance,
                recentMood: base.recentMood,
                healthScore: base.healthScore,
                latestMeasurement: .init(
                    kindRaw: "weight", title: "Weight",
                    formattedValue: "\(70 + index)", unit: "kg",
                    symbol: "scalemass", recordedAt: stamp
                ),
                timeFormatRaw: base.timeFormatRaw,
                generatedAt: stamp
            )
        }
        return .write(snapshot, reloadKinds: [])
    }
}
