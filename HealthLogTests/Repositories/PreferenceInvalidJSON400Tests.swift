import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#110 — malformed-JSON refusal moved from `422` to `400` on seven
/// preference operations.**
///
/// The server answers a body that is not JSON at all with
/// `400 { data: null, error: "Invalid JSON body", meta: { errorCode:
/// "<surface>.body.invalid_json" } }` (the table in #110; `report-selection` at
/// v1.39.0 is `apiError("Invalid JSON body", 400, { errorCode })`). The app
/// never sends such a body, so this is about the shape it would meet: every one
/// of the seven must surface a typed, non-retriable refusal carrying the token
/// from `meta.errorCode` — never a decode failure, never an outbox enqueue,
/// never a retry loop — and `report-selection` must keep its own typed class.
@Suite("#110 — the seven preference operations answer 400 invalid_json", .serialized, .mockURLSession)
struct PreferenceInvalidJSON400Tests {
    enum Operation: String, CaseIterable, Sendable {
        case coachPrefs = "coach-prefs"
        case cyclePrefs = "cycle-prefs"
        case disableCoach = "disable-coach"
        case modules
        case notificationPrefs = "notification-prefs"
        case reportSelection = "report-selection"
        case sourcePriority = "source-priority"

        var path: String {
            "/api/auth/me/\(rawValue)"
        }

        var code: String {
            "\(rawValue).body.invalid_json"
        }
    }

    private static func makeAPI() -> APIClient {
        APIClient(
            environment: AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.5.0",
                buildNumber: "1"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
    }

    /// Runs the operation's real repository write against `api`.
    private static func perform(_ operation: Operation, api: APIClient) async throws {
        switch operation {
        case .coachPrefs:
            try await AICoachSettingsRepository(api: api).putCoachPrefs(["dataClusters": .array([])])
        case .cyclePrefs:
            try await CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))
                .updatePrefs(CyclePrefsPatch(enabled: true))
        case .disableCoach:
            try await AICoachSettingsRepository(api: api).setDisableCoach(true)
        case .modules:
            try await ModuleGateRepository(api: api).updateModules(changes: ["mood": false])
        case .notificationPrefs:
            try await NotificationsRepository(api: api).setMoodReminderHour(20)
        case .reportSelection:
            try await ReportSelectionRepository(api: api).replace(
                SavedReportProfile(
                    selection: ReportSelection(leaves: ["WEIGHT"]),
                    format: .pdf,
                    rangeDays: 30,
                    includeCharts: false
                )
            )
        case .sourcePriority:
            try await SourcePriorityRepository(api: api).update(SourcePriorityDTO(weight: ["MANUAL"]))
        }
    }

    @Test("each operation surfaces the 400 as a typed refusal with meta.errorCode", arguments: Operation.allCases)
    func typedRefusal(operation: Operation) async throws {
        let api = Self.makeAPI()
        nonisolated(unsafe) var writes: [String] = []
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            if req.httpMethod != "GET" { writes.append(path) }
            // The notification-prefs writer holds no token yet; a GET here
            // would be its conflict re-read, which a 400 never triggers.
            return (
                HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"""
                {"data":null,"error":"Invalid JSON body","meta":{"errorCode":"\#(operation.code)"}}
                """#.utf8)
            )
        }

        do {
            try await Self.perform(operation, api: api)
            Issue.record("\(operation.rawValue): a 400 must throw")
        } catch let error as ReportSelectionError {
            #expect(operation == .reportSelection, "only report-selection owns a typed class")
            #expect(error == .invalidJSON)
        } catch let error as HLError {
            #expect(operation != .reportSelection, "report-selection must map to .invalidJSON")
            #expect(error == .server(status: 400, code: operation.code, message: "Invalid JSON body"))
            #expect(!error.isRetriable)
            #expect(!error.shouldPersistToOutbox, "a malformed body must never be queued for replay")
        } catch {
            Issue.record("\(operation.rawValue): unexpected error type \(error)")
        }
        // One write on the wire: no retry loop on a client-side fault.
        #expect(writes == [operation.path])
    }
}

// swiftlint:enable force_unwrapping
