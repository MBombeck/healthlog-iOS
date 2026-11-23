import Foundation
import Testing

/// Issue #82 guard: every suite that uses the mock transport opens its own
/// per-test scope.
///
/// A suite without the scope only surfaces as a runtime issue in whichever
/// test first touched the shared transport, so the trait is checked across the
/// whole test tree.
///
/// Patterns are assembled from pieces so this file never matches itself.
@Suite("MockURLProtocol has no process-global handler (#82)")
struct MockURLProtocolGlobalSlotGuardTests {
    private static let mockPath = "HealthLogTests/Mocks/MockURLProtocol.swift"
    private static let scopeTrait = "." + "mockURLSession"

    /// Every Swift file under `HealthLogTests/`, as repository-relative paths.
    private static func testSources() throws -> [String] {
        let root = Phase8SourceScan.repositoryRoot
        let base = root.appendingPathComponent("HealthLogTests")
        let enumerator = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            paths.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
        }
        return paths.sorted()
    }

    /// A file that declares tests and reaches for the mock transport must open
    /// the per-test scope itself. Helper files without tests are exempt: their
    /// callers carry the trait.
    @Test("every test file that uses the mock transport opens the per-test scope")
    func everyUsingFileOpensTheScope() throws {
        let exempt: Set = [Self.mockPath]
        let sources = try Self.testSources()
        #expect(sources.count > 100, "the scan must actually see the test tree")
        var offenders: [String] = []
        for path in sources where !exempt.contains(path) {
            let source = try Phase8SourceScan.stripped(path)
            let usesTransport = source.contains("." + "mock()") || source.contains("MockURLProtocol" + ".install")
            guard usesTransport, source.contains("@Test") else { continue }
            if !source.contains(Self.scopeTrait) { offenders.append(path) }
        }
        #expect(offenders.isEmpty, "add .mockURLSession to the suite: \(offenders)")
    }
}
