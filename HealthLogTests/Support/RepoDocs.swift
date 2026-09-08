import Foundation

/// Documents some tests pin (the planning corpus under `.planning/`,
/// `PROJECT_GUIDE.md`) are part of the development checkout but deliberately
/// not of the public mirror. A pin that cannot find its document is not a
/// finding about the app — the tests that read one declare
/// `.enabled(if: RepoDocs.present("…"))` and show as skipped where the
/// document is absent, instead of failing on a file-not-found.
enum RepoDocs {
    /// Repository root, from this file's own location (`HealthLogTests/Support/`).
    static func root(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    static func present(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root().appendingPathComponent(relativePath).path)
    }
}
