import Foundation
@testable import HealthLog
import Testing

/// **REG (1.5) — Server #1216, the threshold nudges (POLISH-B B5).**
///
/// `Regression_server_1216` pins that Rest Mode is shown only as the server
/// delivers it. The threshold nudges after a lab entry had the same mistake
/// in another place: they were held back while any illness episode had no
/// `resolvedAt`, and a chronic, ongoing episode never gets one. Now the
/// server's own `restMode.active` on the Health Score decides, nothing else.
@Suite("REG Server #1216: threshold nudges follow the server's Rest Mode")
@MainActor
struct Regression_server_1216_Nudges {
    private static func score(_ restMode: String) throws -> HealthScore {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractional
        let json = #"{"score":71,"band":"yellow","delta":0"# + restMode + "}"
        return try decoder.decode(HealthScore.self, from: Data(json.utf8))
    }

    /// One chronic, ongoing episode: the server keeps Rest Mode off.
    static let chronicOnly = #","restMode":{"active":false,"since":"2026-10-01T00:00:00.000Z","episodeCount":1}"#
    /// An acute episode the server rests for.
    static let resting = #","restMode":{"active":true,"since":"2026-11-01T08:00:00.000Z","episodeCount":1}"#

    private static func lab() -> LabResultDTO {
        LabResultDTO(
            id: UUID().uuidString,
            biomarkerId: "bm-1",
            panel: nil,
            analyte: "Glucose",
            value: 250,
            unit: "mg/dL",
            referenceLow: 70,
            referenceHigh: 180,
            takenAt: "2026-11-05T08:00:00Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: .above,
            createdAt: "2026-11-05T08:00:00Z",
            updatedAt: "2026-11-05T08:00:00Z"
        )
    }

    private final class Scheduled {
        var delivered = 0
    }

    private static func coordinator(score: HealthScore?, scheduled: Scheduled) -> ThresholdNudgeCoordinator {
        ThresholdNudgeCoordinator(
            isOptedIn: { true },
            serverHasEscalated: { _ in ThresholdNudgeCoordinator.serverHasEscalated(score: score) },
            isDebounced: { _ in false },
            recordNudge: { _ in },
            clearDebounce: { _ in },
            schedule: { _, _ in
                scheduled.delivered += 1
                return true
            }
        )
    }

    @Test("only a chronic illness: Rest Mode is off, the nudge comes")
    func chronicOnlyStillNudges() async throws {
        let scheduled = Scheduled()
        let decision = try await Self.coordinator(score: Self.score(Self.chronicOnly), scheduled: scheduled)
            .handleCreatedLab(Self.lab())
        guard case .nudge = decision else {
            Issue.record("expected a nudge, got \(decision)")
            return
        }
        #expect(scheduled.delivered == 1)
    }

    @Test("the server rests the account: the nudge waits")
    func restModeDefers() async throws {
        let scheduled = Scheduled()
        let decision = try await Self.coordinator(score: Self.score(Self.resting), scheduled: scheduled)
            .handleCreatedLab(Self.lab())
        #expect(decision == .suppress(.serverEscalated))
        #expect(scheduled.delivered == 0)
    }

    @Test("no score yet, or a server without the flag: no escalation the app could name", arguments: [
        #","restMode":null"#, ""
    ])
    func absentFlagIsNoEscalation(_ restMode: String) throws {
        #expect(!ThresholdNudgeCoordinator.serverHasEscalated(score: nil))
        #expect(try !ThresholdNudgeCoordinator.serverHasEscalated(score: Self.score(restMode)))
    }
}
