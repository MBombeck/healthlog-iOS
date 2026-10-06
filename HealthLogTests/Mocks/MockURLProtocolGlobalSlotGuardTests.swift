import Foundation
import Testing

/// Issue #82 guard: the process-global `MockURLProtocol` handler stays gone.
///
/// Removing the slot already makes the old spelling a compile error. This
/// suite pins the two ways back that would compile: a new type-level handler
/// stored on the mock, and a suite that uses the mock transport without the
/// per-test scope, which would only surface as a runtime issue in whichever
/// test first touched it.
///
/// Patterns are assembled from pieces so this file never matches itself.
@Suite("MockURLProtocol has no process-global handler (#82)")
struct MockURLProtocolGlobalSlotGuardTests {
    private static let mockPath = "HealthLogTests/Mocks/MockURLProtocol.swift"
    private static let legacySpelling = "MockURLProtocol" + ".handler"
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

    @Test("no test source names the process-global handler in code")
    func noSourceNamesTheGlobalHandler() throws {
        let sources = try Self.testSources()
        #expect(sources.count > 100, "the scan must actually see the test tree")
        let offenders = try sources.filter { try Phase8SourceScan.stripped($0).contains(Self.legacySpelling) }
        #expect(offenders.isEmpty, "use MockURLProtocol.install inside a .mockURLSession scope: \(offenders)")
    }

    @Test("the mock stores no handler at type level")
    func theMockStoresNoTypeLevelHandler() throws {
        let source = try Phase8SourceScan.stripped(Self.mockPath)
        let typeLevelHandler = try Regex(#"static\s+var\s+\w+\s*:\s*(MockURLProtocol\.)?Handler"#)
        #expect(source.firstMatch(of: typeLevelHandler) == nil)
        // The only type-level mutable state that may name a session is the
        // task-local binding and the weak registries.
        #expect(source.contains("@TaskLocal static var current"))
    }

    /// A file that declares tests and reaches for the mock transport must open
    /// the per-test scope itself. Helper files without tests are exempt: their
    /// callers carry the trait.
    @Test("every test file that uses the mock transport opens the per-test scope")
    func everyUsingFileOpensTheScope() throws {
        let exempt: Set = [Self.mockPath]
        var offenders: [String] = []
        for path in try Self.testSources() where !exempt.contains(path) {
            let source = try Phase8SourceScan.stripped(path)
            let usesTransport = source.contains("." + "mock()") || source.contains("MockURLProtocol" + ".install")
            guard usesTransport, source.contains("@Test") else { continue }
            if !source.contains(Self.scopeTrait) { offenders.append(path) }
        }
        #expect(offenders.isEmpty, "add .mockURLSession to the suite: \(offenders)")
    }
}
