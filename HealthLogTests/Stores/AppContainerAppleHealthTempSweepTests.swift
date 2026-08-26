import Foundation
@testable import HealthLog
import Testing

/// **Phase 09 / plan 09-02 — the launch sweep for Apple-Health import residue.**
///
/// Two unlike witnesses, because either one alone is satisfiable by the wrong
/// implementation:
///
/// * a **behavioural** case, which drives the exact function the launch task
///   calls and proves it removes what it owns and nothing else; and
/// * a **composition-source** case, which proves the launch task actually calls
///   it, awaits it as a structured child, and reaches it without going anywhere
///   near `ExportStore` or the import screen.
///
/// The second exists because the first would pass just as happily against a
/// sweep nobody ever runs — which is the state this plan found the app in.
@Suite("AppContainer Apple-Health import temp sweep", .serialized)
struct AppContainerAppleHealthTempSweepTests {
    // MARK: - Behaviour

    @Test("launch sweeps stale owned temps, and cannot delete anything else")
    func launchSweepsWithoutOpeningImportUI() async throws {
        let scratch = try Phase09Scratch("09-02-sweep")
        let store = AppleHealthImportTempStore(directory: scratch.url)

        // Ours, and old enough to be residue.
        let stale = try await store.makeOwnedFile()
        try Self.setModificationDate(of: stale, to: Date(timeIntervalSinceNow: -3600))
        // Ours, and young. A sweep with no age gate would take this one too.
        let fresh = try await store.makeOwnedFile()
        // Not ours, and old. A sweep with no prefix gate would take both.
        let neighbour = scratch.url.appendingPathComponent("healthlog-doctor-report-2026.pdf")
        try Data("pdf".utf8).write(to: neighbour)
        try Self.setModificationDate(of: neighbour, to: Date(timeIntervalSinceNow: -86400))
        let stranger = scratch.url.appendingPathComponent("someone-elses-export.zip")
        try Data("zip".utf8).write(to: stranger)
        try Self.setModificationDate(of: stranger, to: Date(timeIntervalSinceNow: -86400))

        let removed = await AppContainer.sweepAppleHealthImportTemps(
            store: store,
            now: .now,
            ttl: AppleHealthImportTempStore.defaultTTL
        )

        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        #expect(FileManager.default.fileExists(atPath: stranger.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(
            removed.map(\.lastPathComponent) == [stale.lastPathComponent],
            "EXPECTED_RED: app launch did not sweep stale Apple Health import temps"
        )
    }

    // MARK: - Composition source

    @Test("the launch task awaits the sweep as a structured child, without the import surface")
    func theLaunchTaskOwnsTheSweep() throws {
        // Comment-stripped, because this file's own prose names the very
        // symbols the scan forbids — a scan that read them would be a scan
        // that can only be satisfied by silence.
        let launchCode = try Self.executableSource("HealthLog/App/HealthLogApp.swift")

        // `async let` + a later `await` is a structured child of the launch
        // task. `Task { … }` / `Task.detached { … }` would be a sibling that
        // can outlive or be dropped by the launch, and nothing would notice.
        //
        // Each verdict is bound to a `Bool` before it is asserted. A
        // `#expect` on `contents.contains(…)` prints the whole file into the
        // failure message, and an 800-line paste of production source inside
        // a RED log is how a behavioural gate comes to look like a compile
        // failure to the regex that reads it.
        let opensStructuredChild = launchCode
            .contains("async let sweptImportTemps = AppContainer.sweepAppleHealthImportTemps()")
        let awaitsThatChild = launchCode.contains("_ = await sweptImportTemps")
        #expect(opensStructuredChild)
        #expect(awaitsThatChild)

        // The launch file must not reach the sweep by way of the export/import
        // surface — that factory only runs for a user who opened the screen,
        // which is everybody except the one whose import crashed.
        let exportSurfaceMentions = Self.occurrences(of: "ExportStore", in: launchCode)
            + Self.occurrences(of: "SettingsAppleHealthImportScreen", in: launchCode)
        #expect(exportSurfaceMentions == 0)

        // Exactly two production files may name the sweep: the composition
        // root that defines it and the launch task that awaits it. A third
        // would mean a second, unsequenced trigger.
        let callers = try Self.productionFiles(naming: "sweepAppleHealthImportTemps")
        #expect(callers == [
            "HealthLog/App/HealthLogApp.swift",
            "HealthLog/Stores/AppContainer+Wiring.swift"
        ])
    }

    // MARK: - Helpers

    private static func setModificationDate(of url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// The file with every comment line removed.
    private static func executableSource(_ relativePath: String) throws -> String {
        try stripComments(source(relativePath))
    }

    private static func stripComments(_ contents: String) -> String {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
            .joined(separator: "\n")
    }

    /// Count, never a short-circuiting probe. `grep -q` under `set -o pipefail`
    /// silently drops long files, a defect this phase's tooling has now
    /// produced three separate times; a `contains` that answers `true` and
    /// stops is the same mistake in Swift.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func repositoryRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Production files whose **executable** lines name `needle`, as
    /// repository-relative paths.
    ///
    /// The whole sorted list, never a `first(where:)`: a probe that stops at
    /// the first hit reports "found" for a tree that has five, which is the
    /// same defect as the `grep -q` above wearing Swift's clothes.
    private static func productionFiles(naming needle: String) throws -> [String] {
        let root = repositoryRoot().appendingPathComponent("HealthLog")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var found: [String] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            let url = root.appendingPathComponent(relative)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard occurrences(of: needle, in: stripComments(contents)) > 0 else { continue }
            found.append("HealthLog/" + relative)
        }
        return found.sorted()
    }
}
