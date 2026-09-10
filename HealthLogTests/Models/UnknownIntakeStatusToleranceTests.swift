import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **Audit B-5 (2026-09-10) — an intake status this build cannot name is not
/// "taken", and it does not cost the row.**
///
/// Two losses on the same enum. On the READ side `MedicationIntake.status` is a
/// hard `try c.decode`, so one status the server adds after this build throws
/// mid-row — and the today-ledger is decoded as one array, so the sibling doses
/// of that page go with it. On the STORED side five call sites resolved the raw
/// value with `?? .taken`: a status a downgrade or a data import left behind
/// counted as a dose actually taken and raised the compliance figure.
///
/// The sentinel is a bucket, not a disposition: it is never taken, never
/// skipped, never pending, and it never goes back out on the wire.
@Suite("Audit B-5 — an unknown intake status degrades instead of lying")
struct UnknownIntakeStatusToleranceTests {
    private static let json = """
    [
      {
        "id": "i-1",
        "medicationId": "m-1",
        "scheduledAt": "2026-09-10T08:00:00Z",
        "status": "pending"
      },
      {
        "id": "i-2",
        "medicationId": "m-1",
        "scheduledAt": "2026-09-10T20:00:00Z",
        "status": "PARTIALLY_TAKEN"
      }
    ]
    """

    @Test("An unrecognised status decodes to the sentinel instead of throwing")
    func unknownStatusDecodes() throws {
        let decoded = try JSONDecoder.hlDefault.decode(IntakeStatus.self, from: Data("\"PARTIALLY_TAKEN\"".utf8))
        #expect(decoded == .unknown)
        #expect(decoded != .taken)
    }

    @Test("The unknown row keeps its place in the ledger — and its siblings keep theirs")
    func unknownRowSurvivesTheArray() throws {
        let rows = try JSONDecoder.hlDefault.decode([MedicationIntake].self, from: Data(Self.json.utf8))
        #expect(rows.count == 2)
        #expect(rows.first?.status == .pending)
        #expect(rows.last?.id == "i-2")
        #expect(rows.last?.status == .unknown)
        #expect(rows.last?.takenAt == nil)
    }

    @Test("Every value the server does send still decodes to itself")
    func knownStatusesAreUntouched() throws {
        for raw in ["pending", "taken", "skipped", "snoozed", "missed"] {
            let decoded = try JSONDecoder.hlDefault.decode(IntakeStatus.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded.rawValue == raw)
            #expect(decoded != .unknown)
        }
    }

    @Test("The sentinel round-trips through the offline cache encoder")
    func sentinelRoundTripsThroughTheCache() throws {
        // `MedicationsStore` write-throughs the whole `[MedicationIntake]` to the
        // SWR disk cache (`JSONEncoder.hlDefault`). A refusing `encode` would
        // drop the entire page's cache write for one unnameable row, so the
        // sentinel encodes as its own token and reads back as itself.
        let intake = MedicationIntake(
            id: "i-2",
            medicationId: "m-1",
            scheduledAt: Date(timeIntervalSince1970: 1_757_491_200),
            status: .unknown
        )
        let data = try JSONEncoder.hlDefault.encode([intake])
        let back = try JSONDecoder.hlDefault.decode([MedicationIntake].self, from: data)
        #expect(back.first?.status == .unknown)
    }

    @Test("A stored raw value this build cannot name resolves to the sentinel, never to taken")
    func storedRawValueResolvesToTheSentinel() {
        #expect(IntakeStatus(stored: "FUTURE_STATUS") == .unknown)
        #expect(IntakeStatus(stored: "") == .unknown)
        #expect(IntakeStatus(stored: "taken") == .taken)
        #expect(IntakeStatus(stored: "skipped") == .skipped)
        #expect(IntakeStatus(stored: "missed") == .missed)
    }

    @Test("The sentinel is never written back — not to the server, not to the local mirror")
    func sentinelIsNeverWritable() throws {
        #expect(throws: HLError.self) { try IntakeStatus.unknown.writableRawValue }
        #expect(try IntakeStatus.taken.writableRawValue == "taken")
        // The terminal read state keeps refusing exactly as before.
        #expect(throws: HLError.self) { try IntakeStatus.missed.writableRawValue }
    }
}
