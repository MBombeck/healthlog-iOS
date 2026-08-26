import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **audit-v0162 M-7 regression coverage — derived-intake synthesis gate.**
///
/// `derivedTodayIntakes` synthesised client-side placeholders UNCONDITIONALLY,
/// even against a modern slot-materialising server — so a server slot whose
/// `scheduledFor` diverges >5 min from the client projection (schedule-era edit
/// / DST / profile-TZ seam) escaped the ±5-min dedup and was appended alongside
/// the synth slot, double-counting the due surfaces + app badge.
///
/// The synthesis is now gated on `derivedIntakeSynthesisEnabledProvider`
/// (defaults to `true` = the ≤ v1.15.17 fallback, unchanged). When a modern
/// server is detected the gate flips off and the derivation trusts the server
/// rows verbatim — no double-count.
@Suite("MedicationsStore — M-7 derived-intake synthesis gate")
@MainActor
struct MedicationsStoreDerivedIntakeGateTests {
    @Test("Today's ledger keeps a pending evening dose when a sibling row is auto-missed")
    func todayLedgerDecodesMissedWithoutDroppingPendingSibling() throws {
        // Synthetic mirror of the server's current `scope=today` contract.
        // Decoding is array-atomic: before the regression fix, the one
        // `missed` row throws and discards the otherwise valid 21:00 pending
        // dose together with the entire response.
        let payload = Data(#"""
        [
          {
            "id": "morning-taken",
            "medicationId": "med-lisinopril",
            "scheduledAt": "2026-08-13T06:59:00.000Z",
            "takenAt": "2026-08-13T06:59:00.000Z",
            "status": "taken",
            "snoozedUntil": null
          },
          {
            "id": "terminal-missed",
            "medicationId": "med-other",
            "scheduledAt": "2026-08-13T07:30:00.000Z",
            "takenAt": null,
            "status": "missed",
            "snoozedUntil": null
          },
          {
            "id": "evening-pending",
            "medicationId": "med-lisinopril",
            "scheduledAt": "2026-08-13T19:00:00.000Z",
            "takenAt": null,
            "status": "pending",
            "snoozedUntil": null
          }
        ]
        """#.utf8)

        let decoded = try JSONDecoder.hlDefault.decode([MedicationIntake].self, from: payload)

        #expect(decoded.map(\.id) == ["morning-taken", "terminal-missed", "evening-pending"])
        #expect(decoded[1].status == .missed)
        #expect(decoded.last?.status == .pending)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let noon = try #require(ISO8601DateFormatter.fractional.date(from: "2026-08-13T12:00:00.000Z"))
        let snapshot = AnstehendeEinnahmenSheet.makeSnapshot(
            todayIntakes: decoded,
            medications: [
                Medication(
                    id: "med-lisinopril",
                    name: "Lisinopril",
                    dose: "5 mg",
                    schedule: MedicationSchedule(times: [])
                ),
                Medication(
                    id: "med-other",
                    name: "Synthetic control",
                    dose: "1 unit",
                    schedule: MedicationSchedule(times: [])
                )
            ],
            now: noon,
            calendar: utc
        )
        #expect(snapshot.rows.contains { $0.id == "evening-pending" })
        #expect(snapshot.pendingCount == 1, "only the authoritative evening row remains open")
        #expect(snapshot.totalCount == 3, "the terminal missed row remains visible without hiding siblings")
    }

    private func makeStore() throws -> MedicationsStore {
        // No network is exercised (we drive the derive directly via the seams);
        // the shared `StubAPIClient` with no handler is never called.
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        return MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox))
    }

    private func lisinopril() -> Medication {
        Medication(
            id: "med-lisinopril",
            name: "Lisinopril",
            dose: "5mg",
            schedule: MedicationSchedule(
                times: [TimeOfDay(hour: 7, minute: 0), TimeOfDay(hour: 19, minute: 0)],
                weekdays: nil,
                intervalWeeks: 1
            ),
            notificationsEnabled: true,
            active: true
        )
    }

    /// A server row for TODAY at 13:00 local — diverges >5 min from both the
    /// 07:00 and 19:00 schedule slots, so the ±5-min dedup can't suppress a synth.
    private func divergentServerDoseToday() -> MedicationIntake {
        let cal = Calendar.current
        let onePm = cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
        return MedicationIntake(
            id: "server-divergent",
            medicationId: "med-lisinopril",
            scheduledAt: onePm,
            takenAt: nil,
            status: .pending,
            snoozedUntil: nil
        )
    }

    @Test("Gate ON (default): synthesis runs and the divergent server slot double-counts")
    func gateOnStillSynthesises() throws {
        let store = try makeStore()
        store._testForceSet(medications: [lisinopril()])
        store._testForceSet(todayIntakes: [divergentServerDoseToday()])

        let derived = store.derivedTodayIntakes
        // Default behaviour is preserved: the two schedule slots are still
        // synthesised alongside the divergent server row (the documented hazard).
        #expect(derived.contains { $0.isSynthesizedPlaceholder }, "default gate keeps synthesising")
        #expect(derived.contains { $0.id == "server-divergent" })
    }

    @Test("Gate OFF (modern server): synthesis is skipped — server rows trusted verbatim, no double-count")
    func gateOffTrustsServerRowsOnly() throws {
        let store = try makeStore()
        store._testForceSet(medications: [lisinopril()])
        store._testForceSet(todayIntakes: [divergentServerDoseToday()])
        store.derivedIntakeSynthesisEnabledProvider = { false }

        let derived = store.derivedTodayIntakes
        #expect(derived.filter(\.isSynthesizedPlaceholder).isEmpty, "M-7: no synth placeholders when the server materialises slots")
        #expect(derived.map(\.id) == ["server-divergent"], "only the server row survives — no double-count")
    }

    @Test("Gate OFF filters server rows to today's window and sorts them")
    func gateOffFiltersAndSortsToday() throws {
        let store = try makeStore()
        let cal = Calendar.current
        let today = Date()
        let morning = try #require(cal.date(bySettingHour: 8, minute: 0, second: 0, of: today))
        let evening = try #require(cal.date(bySettingHour: 20, minute: 0, second: 0, of: today))
        let yesterday = try #require(cal.date(byAdding: .day, value: -1, to: morning))

        store._testForceSet(medications: [])
        store._testForceSet(todayIntakes: [
            MedicationIntake(id: "evening", medicationId: "m", scheduledAt: evening, status: .pending),
            MedicationIntake(id: "stale", medicationId: "m", scheduledAt: yesterday, status: .pending),
            MedicationIntake(id: "morning", medicationId: "m", scheduledAt: morning, status: .pending)
        ])
        store.derivedIntakeSynthesisEnabledProvider = { false }

        let derived = store.derivedTodayIntakes
        #expect(derived.map(\.id) == ["morning", "evening"], "yesterday's row is dropped; today's are chronological")
    }
}
