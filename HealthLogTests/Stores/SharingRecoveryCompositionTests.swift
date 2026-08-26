// This suite depends on the app-target-only AppContainer. The SwiftPM library
// intentionally excludes that composition root.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("AppContainer sharing-recovery composition", .serialized)
    struct SharingRecoveryCompositionTests {
        @Test("production composition installs recovery and scoped cache cleanup")
        func productionCompositionInstallsRecovery() async throws {
            let container = try makeContainer()

            let source = try String(
                contentsOf: repositoryRoot()
                    .appendingPathComponent("HealthLog/Stores/AppContainer+LogoutHooks.swift"),
                encoding: .utf8
            )
            #expect(
                source.contains("apiClient.setSharingRecoveryHandler"),
                "AppContainer production composition must install APIClient's sharing-recovery handler"
            )

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
                healthKit: MockHealthKitWriter()
            )
        }

        private func repositoryRoot(file: String = #filePath) -> URL {
            URL(fileURLWithPath: file)
                .deletingLastPathComponent() // Stores
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // repository root
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
