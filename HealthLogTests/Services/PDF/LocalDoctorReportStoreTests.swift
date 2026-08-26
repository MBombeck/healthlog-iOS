import Foundation
import PDFKit
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

private typealias Measurement = HealthLog.Measurement

/// T-7 Commit 4 — `LocalDoctorReportStore` orchestration tests.
///
/// Drives the store with stub repository wiring and asserts:
/// - default selection is `.all`
/// - generate() writes a temp file we can re-open with PDFDocument
/// - successive generate() calls remove the previous file
/// - clearOnLogout removes the file + resets state
/// - snapshot pulls displayName from SettingsStore.profile
@MainActor
@Suite("LocalDoctorReportStore — orchestration")
struct LocalDoctorReportStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_716_000_000)

    // MARK: - Fixtures

    private static func makeStore() async throws -> LocalDoctorReportStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let measurementsRepo = MeasurementsRepository(api: api, outbox: outbox)
        let medicationsRepo = MedicationsRepository(api: api, outbox: outbox)
        let moodRepo = MoodRepository(api: api, outbox: outbox)
        let settingsRepo = SettingsRepository(api: api)
        let measurementsStore = MeasurementsStore(repo: measurementsRepo)
        let medicationsStore = MedicationsStore(repo: medicationsRepo)
        let moodStore = MoodStore(repo: moodRepo)
        let suiteName = "LocalDoctorReportStoreTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(repo: settingsRepo, defaults: defaults)
        return LocalDoctorReportStore(
            measurementsStore: measurementsStore,
            medicationsStore: medicationsStore,
            moodStore: moodStore,
            settingsStore: settingsStore,
            now: { Self.now }
        )
    }

    // MARK: - Default state

    @Test("default selection is `.all` and periodDays is 90")
    func defaultsAreAllAnd90Days() async throws {
        let store = try await Self.makeStore()
        #expect(store.selection.vitals)
        #expect(store.selection.charts)
        #expect(store.selection.medications)
        #expect(store.selection.adherence)
        #expect(store.selection.mood)
        #expect(store.periodDays == 90)
        #expect(store.pdfURL == nil)
        #expect(!store.isWorking)
        #expect(store.error == nil)
    }

    // MARK: - generate()

    @Test("generate() writes a PDFKit-parseable file and updates pdfURL")
    func generateProducesValidFile() async throws {
        let store = try await Self.makeStore()
        await store.generate(locale: .de)
        let url = try #require(store.pdfURL)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == "pdf")
        let document = try #require(PDFDocument(url: url))
        // Only the cover page lands when every store is empty.
        #expect(document.pageCount == 1)
        #expect(store.error == nil)
        #expect(!store.isWorking)
    }

    @Test("regenerate cleans up the previous file")
    func regenerationCleansUpPreviousFile() async throws {
        let store = try await Self.makeStore()
        await store.generate(locale: .de)
        let firstURL = try #require(store.pdfURL)
        defer { try? FileManager.default.removeItem(at: firstURL) }
        await store.generate(locale: .de)
        let secondURL = try #require(store.pdfURL)
        defer { try? FileManager.default.removeItem(at: secondURL) }
        #expect(firstURL != secondURL)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    // MARK: - clearOnLogout

    @Test("clearOnLogout removes the file + resets state to defaults")
    func clearOnLogoutResetsEverything() async throws {
        let store = try await Self.makeStore()
        store.selection.mood = false
        store.periodDays = 30
        await store.generate(locale: .de)
        let url = try #require(store.pdfURL)
        store.clearOnLogout()
        #expect(store.pdfURL == nil)
        #expect(store.periodDays == 90)
        #expect(store.selection == .all)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - makeSnapshot()

    @Test("makeSnapshot pulls displayName from SettingsStore.profile")
    func snapshotPullsDisplayName() async throws {
        let store = try await Self.makeStore()
        // No profile loaded — name should default to empty string.
        let snapshot = store.makeSnapshot()
        #expect(snapshot.patientName.isEmpty)
        #expect(snapshot.appVersion.contains("."))
        #expect(snapshot.measurements.isEmpty)
        #expect(snapshot.medications.isEmpty)
        #expect(snapshot.moodEntries.isEmpty)
    }

    @Test("makeSnapshot includes MoodStore.entries when present")
    func snapshotIncludesMood() async throws {
        let store = try await Self.makeStore()
        let api = StubAPIClient()
        // Re-build with a mood store that has entries injected via the
        // test-only replace setter.
        let outbox = try OutboxQueue(inMemory: true)
        let moodRepo = MoodRepository(api: api, outbox: outbox)
        let moodStore = MoodStore(repo: moodRepo)
        moodStore.replaceEntriesForTesting([
            MoodEntry(id: "m1", recordedAt: Self.now, score: 4, tags: ["happy"])
        ])
        // Build a fresh store using the populated mood store.
        let measurementsRepo = MeasurementsRepository(api: api, outbox: outbox)
        let medicationsRepo = MedicationsRepository(api: api, outbox: outbox)
        let settingsRepo = SettingsRepository(api: api)
        let suiteName = "LocalDoctorReportStoreTests.snapshotMood.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store2 = LocalDoctorReportStore(
            measurementsStore: MeasurementsStore(repo: measurementsRepo),
            medicationsStore: MedicationsStore(repo: medicationsRepo),
            moodStore: moodStore,
            settingsStore: SettingsStore(repo: settingsRepo, defaults: defaults),
            now: { Self.now }
        )
        let snapshot = store2.makeSnapshot()
        #expect(snapshot.moodEntries.count == 1)
        // Avoid unused-variable warning on `store`.
        _ = store
    }

    // MARK: - LocalDoctorReportPeriod

    @Test("LocalDoctorReportPeriod cases map to expected day counts")
    func periodEnumMatchesDayCounts() {
        #expect(LocalDoctorReportPeriod.thirty.rawValue == 30)
        #expect(LocalDoctorReportPeriod.sixty.rawValue == 60)
        #expect(LocalDoctorReportPeriod.ninety.rawValue == 90)
        #expect(LocalDoctorReportPeriod.oneEighty.rawValue == 180)
        #expect(LocalDoctorReportPeriod.threeSixtyFive.rawValue == 365)
        #expect(LocalDoctorReportPeriod.allCases.count == 5)
    }
}
