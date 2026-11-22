#if !SWIFT_PACKAGE
    import Foundation
    @testable import HealthLog
    import Testing

    /// Opening Sync Diagnostics reads `GET /api/version` again, so the copied
    /// report names the server as it runs now. A version recorded before a
    /// server update must not reach the report while the server answers.
    @MainActor
    @Suite("Sync Diagnostics: fresh server version on open")
    struct SyncDiagnosticsServerVersionTests {
        private struct Offline: Error {}

        private static func defaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: "hl.tests.hkdiag.version.\(UUID().uuidString)"))
        }

        @Test("a server updated since the last foreground: the fresh answer wins and is recorded")
        func freshAnswerReplacesTheStoredOne() async throws {
            let defaults = try Self.defaults()
            KnownServerVersion.record(ServerVersionInfo(version: "1.47.5"), defaults: defaults)

            let version = await SettingsHKSyncDiagnosticsScreen.refreshedServerVersion(defaults: defaults) {
                ServerVersionInfo(version: "1.47.6")
            }

            #expect(version == "1.47.6")
            #expect(defaults.string(forKey: KnownServerVersion.defaultsKey) == "1.47.6")
        }

        @Test("offline: the last recorded version stays")
        func offlineKeepsTheStoredOne() async throws {
            let defaults = try Self.defaults()
            KnownServerVersion.record(ServerVersionInfo(version: "1.47.5"), defaults: defaults)

            let version = await SettingsHKSyncDiagnosticsScreen.refreshedServerVersion(defaults: defaults) {
                throw Offline()
            }

            #expect(version == "1.47.5")
            #expect(defaults.string(forKey: KnownServerVersion.defaultsKey) == "1.47.5")
        }

        @Test("never answered and offline: nothing is invented")
        func nothingKnown() async throws {
            let defaults = try Self.defaults()
            let version = await SettingsHKSyncDiagnosticsScreen.refreshedServerVersion(defaults: defaults) {
                throw Offline()
            }
            #expect(version == nil)
        }

        @Test("the report prints the version it is given")
        func reportLine() {
            let input = SyncDiagnosticsReport.Input(
                generatedAt: Date(timeIntervalSince1970: 1_792_137_600),
                build: AppBuildMetadata(marketingVersion: "1.7.0", build: "320"),
                osVersion: "27.2.0",
                serverVersion: "1.47.6",
                server: nil,
                serverLoadFailed: false,
                heldGroups: [],
                statsLog: nil,
                history: [],
                lastCollectionTriggerAt: nil,
                lastCollectionTriggerSource: nil,
                kinds: [],
                recentFailures: [],
                hourly: nil,
                hrBuckets: nil
            )
            #expect(SyncDiagnosticsReport(input).text.contains("server version: 1.47.6"))
        }
    }
#endif
