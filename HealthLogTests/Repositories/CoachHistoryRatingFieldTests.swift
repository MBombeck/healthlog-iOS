// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// The app no longer rates answers, but the server and the web keep the
/// rating. A conversation whose messages carry a rating still reads in full.
@Suite("Coach history with a rating field", .serialized, .mockURLSession)
struct CoachHistoryRatingFieldTests {
    private func makeRepo() -> CoachConversationHistoryRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return CoachConversationHistoryRepository(api: api)
    }

    @Test("messages with a rating or a feedback object decode unchanged")
    func ratedMessagesDecode() async throws {
        let repo = makeRepo()
        MockURLProtocol.install { req in
            let payload = """
            {"data":{"id":"c1","title":"Sleep","createdAt":"2026-06-10T08:00:00.000Z",\
            "updatedAt":"2026-06-12T08:00:00.000Z","messageCount":3,"summary":null,\
            "messages":[\
            {"id":"m1","role":"user","content":"How is my sleep?","createdAt":"2026-06-10T08:00:00.000Z"},\
            {"id":"m2","role":"assistant","content":"Your sleep looks steady.","createdAt":"2026-06-10T08:00:05.000Z",\
            "rating":"helpful"},\
            {"id":"m3","role":"assistant","content":"Try an earlier bedtime.","createdAt":"2026-06-10T08:00:09.000Z",\
            "feedback":{"rating":"unhelpful","reason":null,"createdAt":"2026-06-11T10:00:00.000Z"}}\
            ]},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }

        let detail = try await repo.detail(id: "c1")

        #expect(detail.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(detail.messages[1].content == "Your sleep looks steady.")
        #expect(detail.messages[2].role == .assistant)
        #expect(detail.messages[2].content == "Try an earlier bedtime.")
    }
}
