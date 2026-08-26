import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Exhaustiveness guard: every Chart shipped in v0.4.0 must wire an
/// `AXChartDescriptor`. The test scans the production source tree for
/// `Chart {` occurrences and asserts that every file rendering a Chart
/// also calls `accessibilityChartDescriptor(...)`.
///
/// **Why this exists (v0.4.0 charts marathon, Stream Charlie, Phase 8):**
/// VoiceOver users get "(empty)" or "image" when a Chart lacks a descriptor.
/// We promised "AXChartDescriptor mandatory on every chart in v0.4.0" in
/// the marathon brief; this test makes the promise enforceable.
@Suite("AXChartDescriptor exhaustiveness — every Chart has a descriptor")
struct ChartAXCoverageTests {
    /// File-system scan of the production sources. Excludes Test target so
    /// `Chart {` mentions in tests don't accidentally enforce the rule on
    /// themselves.
    private static let productionRoot: String = {
        // The bundle resource path points inside the test bundle at runtime;
        // we walk up to find the project root by searching for `HealthLog/`.
        // SwiftPM puts the test bundle in `.build/...`; the Xcode test bundle
        // sits under DerivedData. Both have `HealthLog/` two-or-three levels
        // up from `__FILE__`'s directory — we use `#filePath` to anchor.
        let here = URL(fileURLWithPath: #filePath)
        // here = .../HealthLogTests/Screens/ChartAXCoverageTests.swift
        // production root = .../HealthLog
        let prodRoot = here
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <worktree>
            .appendingPathComponent("HealthLog")
        return prodRoot.path
    }()

    @Test("Every file that renders a Chart wires AXChartDescriptor")
    func everyChartHasAXDescriptor() {
        let fm = FileManager.default
        var stack: [String] = [Self.productionRoot]
        var violators: [String] = []
        while let dir = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                let full = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    stack.append(full)
                } else if entry.hasSuffix(".swift") {
                    let contents = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
                    // Heuristic: a real `Chart {` Charts-framework root call
                    // lives outside `///`-comment lines. We split per-line and
                    // strip leading whitespace before testing — a doc-comment
                    // mention of `Chart { … }` shouldn't trigger the rule.
                    let rendersChart = contents
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .contains { line in
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") { return false }
                            return trimmed.contains("Chart {")
                        }
                    if rendersChart {
                        // Allow the file if it calls `accessibilityChartDescriptor`
                        // anywhere (descriptor may be on a parent view; file is
                        // the audit unit) OR if it marks the chart hidden via
                        // `.accessibilityHidden(true)` — the v0.5.5.6 sparkline
                        // primitives (PersonalRecords RecordCard etc.) are
                        // decorative previews whose data is already labelled on
                        // the parent card, so an empty descriptor would add
                        // noise. Hidden is the canonical SwiftUI escape valve.
                        let hasDescriptor = contents.contains("accessibilityChartDescriptor")
                            || contents.contains(".accessibilityHidden(true)")
                        if !hasDescriptor {
                            violators.append((full as NSString).lastPathComponent)
                        }
                    }
                }
            }
        }
        #expect(
            violators.isEmpty,
            "Chart files missing AXChartDescriptor: \(violators.joined(separator: ", "))"
        )
    }
}
