// This suite depends on the app-target-only AppContainer. The SwiftPM library
// intentionally excludes that composition root.
// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("AppContainer sharing-recovery composition", .serialized, .mockURLSession)
    struct SharingRecoveryCompositionTests {
        @Test("production composition installs recovery and scoped cache cleanup")
        func productionCompositionInstallsRecovery() async throws {
            MockURLProtocol.install { request in
                Self.response(request, status: 200, body: #"{"data":null,"error":null}"#)
            }
            let container = try makeContainer()

            let hook = try #require(
                container.authStore.sharingScopeCleanupHook,
                "AppContainer must install AuthStore's selected-record cleanup hook"
            )
            container.dashboardStore.seedSummaryForTesting(Self.staleSelectedRecordSummary)

            await hook()

            #expect(
                container.dashboardStore.summary == nil,
                "selected-record in-memory data must be empty before the reconciled actor is published"
            )
        }

        /// The production client must hand a lost grant to the container's
        /// recovery: selected-record data goes, the owner stays signed in.
        @Test("a lost sharing grant on the production client clears selected-record data")
        func lostGrantReachesTheContainerRecovery() async throws {
            MockURLProtocol.install { request in
                if request.url?.path == "/api/auth/me" {
                    return Self.response(request, status: 200, body: #"{"data":{"id":"owner"},"error":null}"#)
                }
                return Self.response(
                    request,
                    status: 403,
                    body: #"{"data":null,"error":"Account access denied","meta":{"errorCode":"sharing.access.denied"}}"#
                )
            }
            let container = try makeContainer()
            container.authStore.setPhaseForTesting(.authenticated(Self.user(id: "owner")))
            container.dashboardStore.seedSummaryForTesting(Self.staleSelectedRecordSummary)
            let client = try #require(container.api as? APIClient)
            let entry = try #require(try JSONDecoder.hlDefault.decode([AccountAccessEntry].self, from: Data(#"""
            [{"accountId":"fixture-record","username":"fixture","access":"write","level":"write",
              "recordKind":"shared","sections":["measurements"],"canWrite":true}]
            """#.utf8)).first)
            await client.selectAccount(entry)

            let mutation = APIRequest<EmptyPayload>(method: .post, path: "/api/measurements", body: Data("{}".utf8))
            try? await client.sendVoid(mutation)

            #expect(await client.selectedAccountID() == nil)
            #expect(container.dashboardStore.summary == nil, "selected-record data must not survive a lost grant")
            guard case let .authenticated(user) = container.authStore.phase else {
                Issue.record("a lost grant must keep the owner signed in")
                return
            }
            #expect(user.id == "owner")
        }

        @Test("late sharing recovery cannot overwrite a replacement account")
        func lateRecoveryCannotCrossAccounts() async throws {
            let container = try makeContainer()
            container.authStore.setPhaseForTesting(.authenticated(Self.user(id: "replacement-owner")))

            await container.authStore.handleSharingRecovery(
                SharingRecoveryEvent(reason: .sessionChanged, reconciledUser: Self.user(id: "previous-owner"))
            )

            guard case let .authenticated(user) = container.authStore.phase else {
                Issue.record("replacement account must stay authenticated")
                return
            }
            #expect(user.id == "replacement-owner")
        }

        private func makeContainer() throws -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter(),
                apiSessionConfiguration: .mock()
            )
        }

        private nonisolated static func response(
            _ request: URLRequest,
            status: Int,
            body: String
        ) -> (HTTPURLResponse, Data?) {
            (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        private static func user(id: String) -> User {
            User(id: id, email: nil, username: nil, displayName: nil)
        }

        private static let staleSelectedRecordSummary = DashboardSummary(
            greeting: Greeting(salutation: "Selected record", date: .now),
            compliance: ComplianceSnapshot(scheduledToday: 1, takenToday: 0),
            highlightInsight: nil,
            metrics: [],
            lastUpdated: .now
        )
    }

#endif
