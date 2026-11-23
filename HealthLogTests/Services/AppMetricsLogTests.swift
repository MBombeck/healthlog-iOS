#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// D5 #12 — MetricKit reports in a local ring buffer, nothing sent.
    @Suite("AppMetricsLog: a local ring buffer of MetricKit reports")
    struct AppMetricsLogTests {
        /// A log over its own defaults suite; the caller removes the suite.
        private struct Fixture {
            let suite = "hl.test.metrics.\(UUID().uuidString)"
            let defaults: UserDefaults
            let log: AppMetricsLog

            init() throws {
                defaults = try #require(UserDefaults(suiteName: suite))
                log = AppMetricsLog(suiteName: suite)
            }
        }

        @Test("keeps the newest reports up to its capacity, newest first")
        func ringBufferKeepsTheNewest() throws {
            let fixture = try Fixture()
            let log = fixture.log
            let defaults = fixture.defaults
            defer { defaults.removePersistentDomain(forName: fixture.suite) }
            let base = Date(timeIntervalSince1970: 1_790_000_000)
            for day in 0 ..< AppMetricsLog.capacity + 5 {
                log.record(AppMetricsReport(endedAt: base.addingTimeInterval(Double(day) * 86400), launchSeconds: Double(day)))
            }
            let reports = log.reports()
            #expect(reports.count == AppMetricsLog.capacity)
            #expect(reports.first?.launchSeconds == Double(AppMetricsLog.capacity + 4))
            #expect(reports.last?.launchSeconds == 5)
        }

        @Test("survives a relaunch: the buffer lives in the app's own defaults")
        func persistsLocally() throws {
            let fixture = try Fixture()
            let log = fixture.log
            let defaults = fixture.defaults
            defer { defaults.removePersistentDomain(forName: fixture.suite) }
            var exits = AppMetricsReport.ExitCounts()
            exits.lockedFile = 2
            log.record(AppMetricsReport(endedAt: Date(timeIntervalSince1970: 1_790_000_000), backgroundExits: exits))
            let reopened = AppMetricsLog(suiteName: fixture.suite)
            #expect(reopened.reports().first?.backgroundExits?.lockedFile == 2)
            #expect(reopened.reports().first?.backgroundExits?.total == 2)
        }

        @Test("crash and hang diagnostics join the report of their period")
        func diagnosticsJoinTheirReport() throws {
            let fixture = try Fixture()
            let log = fixture.log
            let defaults = fixture.defaults
            defer { defaults.removePersistentDomain(forName: fixture.suite) }
            let end = Date(timeIntervalSince1970: 1_790_000_000)
            log.record(AppMetricsReport(endedAt: end))
            log.recordDiagnostics(endedAt: end.addingTimeInterval(60), crashes: 1, hangs: 2)
            log.recordDiagnostics(endedAt: end, crashes: 0, hangs: 0)
            let reports = log.reports()
            #expect(reports.count == 1)
            #expect(reports.first?.crashes == 1)
            #expect(reports.first?.hangs == 2)
        }

        @Test("the support card names every termination cause")
        func exitDetailNamesEveryCause() {
            var exits = AppMetricsReport.ExitCounts()
            exits.memoryLimit = 1
            exits.lockedFile = 3
            let line = SupportMetricsCard.exitDetail(exits)
            #expect(line.contains("1"))
            #expect(line.contains("3"))
        }
    }

#endif
