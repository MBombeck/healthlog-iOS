import Foundation
import Testing

/// v0.11 W36/#22 → **09-08 deletion.** Locks the chart-detail cutover
/// invariant and then the evidence that let the legacy host go.
///
/// The web-mirror `InsightsMetricScreen` (bottom-period control + the newer
/// chart mechanic the operator prefers) is the canonical drill-down at every
/// entry point that used to push the legacy top-range `ChartDetailScreen`:
///
///   1. `DashboardScreen` tile drill-down (routes to the Insights tab)
///   2. `InsightsScreen` notable-trend chip
///   3. `PerKindInsightsBlock` long-tail metric tile
///   4. `InsightsTargetTileGrid` target tile
///
/// (`BMIDetailScreen` was a 4th entry point until v0.14.8 — the screen was an
/// orphan since the Insights web-mirror landed and was deleted per audit Q2.4.
/// The Settings → Privacy & Security "legacy chart view" parking row went in
/// W-B187.)
///
/// **Why the legacy host may be deleted, and how that is proven here.** After
/// the parking row went, nothing constructed `ChartDetailScreen` any more. The
/// naive way to check that is `source.contains("ChartDetailScreen(")` over the
/// raw text of a handful of files — and it is worthless, because this
/// repository documents the legacy host in roughly fifty doc-comments. A
/// substring count over raw text reports every one of those as a live call
/// site, so the clause either never goes green or goes green for the wrong
/// reason. Two properties fix that, and both are stated rather than implied:
///
///   * **Comments are stripped** (`CodeOnlySwift`), string literals are not —
///     a route key or deep-link path that spells the host's name is a
///     reference we *do* want to see.
///   * **The scanned range is bounded** to `HealthLog/**.swift`, the app
///     target's own source. Test and UI-test sources deliberately still name
///     the host (this file does), so scanning them would prove nothing.
///
/// `productionScanSeesTheSourceTree` exists because a scanner that silently
/// scans nothing is green without checking anything — the failure mode this
/// whole suite would otherwise be most vulnerable to.
@Suite("Chart-detail cutover — the legacy host is proven unreachable, then deleted (09-08)")
struct ChartDetailCutoverTests {
    // MARK: - Anchors

    /// `#filePath` is the path this file was *compiled* under; `FileManager`
    /// hands back symlink-resolved URLs (`/tmp` is a symlink on macOS). Both
    /// sides are resolved, because an unresolved prefix comparison makes the
    /// production scan come back empty.
    private static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Screens/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    /// The single file 09-08 deletes, repo-relative.
    static let legacyHostPath = "HealthLog/Screens/Charts/ChartDetailScreen.swift"

    /// The identifier whose every production occurrence must be accounted for.
    private static let legacyHostSymbol = "ChartDetailScreen"

    /// Reusable chart assets that must survive the deletion. The phase context
    /// is explicit that only proven-unreachable code goes; stores and
    /// components stay. `InsightsMetricScreen` composes the same pieces.
    static let reusableChartAssets = [
        "HealthLog/Screens/Charts/ChartDetailComponents.swift",
        "HealthLog/Screens/Charts/ChartDetailDrillDownRow.swift",
        "HealthLog/Screens/Charts/ChartDetailHeroTrend.swift",
        "HealthLog/Screens/Charts/ChartDetailSourcesRow.swift",
        "HealthLog/Screens/Charts/ChartsAccessibility.swift",
        "HealthLog/Screens/Charts/FullscreenChartCover.swift",
        "HealthLog/Screens/Charts/HLTileMetricChart.swift",
        "HealthLog/Screens/Charts/InsufficientDataCard.swift",
        "HealthLog/Screens/Charts/MetricChartContent.swift",
        "HealthLog/Screens/Charts/MetricChartMath.swift",
        "HealthLog/Screens/Charts/SelectedPointCallout.swift",
        "HealthLog/Screens/Charts/TrendsOverlayCard.swift",
        "HealthLog/Stores/ChartDetailStore.swift",
        "HealthLog/Stores/ChartDetailStore+Loading.swift"
    ]

    private func loadSource(_ components: String...) throws -> String {
        var target = Self.repoRoot().appendingPathComponent("HealthLog")
        for component in components {
            target.appendPathComponent(component)
        }
        return try String(contentsOf: target, encoding: .utf8)
    }

    /// Every `*.swift` under `HealthLog/`, as repo-relative path + contents.
    static func productionSources() -> [(relative: String, text: String)] {
        let root = repoRoot()
        let scanRoot = root.appendingPathComponent("HealthLog")
        guard let walker = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        let rootPath = root.path
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            var relative = url.resolvingSymlinksInPath().path
            guard relative.hasPrefix(rootPath) else { continue }
            relative.removeFirst(rootPath.count)
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((relative, text))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: - The scanner is itself under test.

    @Test("The comment stripper drops comments, keeps string literals, and keeps code")
    func strippingCommentsFiresOnAFixture() {
        let fixture = """
        // \(Self.legacyHostSymbol)(kind: .weight)
        /* \(Self.legacyHostSymbol)(kind: .bmi) /* nested */ still a comment */
        let route = "//\(Self.legacyHostSymbol)/open"
        let raw = #"a // b"#
        \(Self.legacyHostSymbol)(kind: .glucose)
        """
        let code = CodeOnlySwift.strip(fixture)
        // The two commented constructions are gone …
        #expect(!code.contains("\(Self.legacyHostSymbol)(kind: .weight)"))
        #expect(!code.contains("\(Self.legacyHostSymbol)(kind: .bmi)"))
        #expect(!code.contains("still a comment"))
        // … the literals survive, including the one that looks like a comment …
        #expect(code.contains("\"//\(Self.legacyHostSymbol)/open\""))
        #expect(code.contains("#\"a // b\"#"))
        // … and real code is untouched.
        #expect(code.contains("\(Self.legacyHostSymbol)(kind: .glucose)"))
    }

    @Test("The production scan sees the app source tree — a scanner that scans nothing proves nothing")
    func productionScanSeesTheSourceTree() {
        let sources = Self.productionSources()
        #expect(
            sources.count > 500,
            """
            Only \(sources.count) Swift files were found under HealthLog/. That is a broken \
            path, not a cleanup: every reachability clause below would then report "no \
            references" and the deletion proof would be vacuous.
            """
        )
        #expect(sources.contains { $0.relative == "HealthLog/Screens/Charts/ChartDetailComponents.swift" })
    }

    // MARK: - Reachability: the deletion precondition.

    @Test("No production file constructs the legacy ChartDetailScreen")
    func legacyHostIsNotConstructedAnywhereInProduction() {
        let offenders = Self.productionSources()
            .filter { CodeOnlySwift.strip($0.text).contains("\(Self.legacyHostSymbol)(") }
            .map(\.relative)
        #expect(
            offenders.isEmpty,
            """
            \(Self.legacyHostSymbol) is still constructed in code (comments stripped) by: \
            \(offenders.joined(separator: ", ")). The host may not be deleted while a live \
            call site exists.
            """
        )
    }

    @Test("No production file outside the host's own file even names ChartDetailScreen in code")
    func legacyHostIsNotNamedOutsideItsOwnFile() {
        let offenders = Self.productionSources()
            .filter { $0.relative != Self.legacyHostPath }
            .filter { CodeOnlySwift.strip($0.text).contains(Self.legacyHostSymbol) }
            .map(\.relative)
        #expect(
            offenders.isEmpty,
            """
            \(Self.legacyHostSymbol) is referenced in code (comments stripped) by: \
            \(offenders.joined(separator: ", ")). Routes, deep links and navigation \
            destinations all land here, so a non-empty list is a live reachability path.
            """
        )
    }

    /// Second witness, deliberately a *different* algorithm. The scanner above
    /// is a character state machine; this one classifies whole lines by their
    /// leading token. For a live reference to escape both, it would have to sit
    /// on a line that begins with a comment marker and is nevertheless code.
    /// Agreement between two unlike mechanisms is what makes the deletion proof
    /// worth more than one clever regex.
    @Test("Independent line-lead witness agrees: the only code line naming the host is its declaration")
    func legacyHostReferencesAreCommentsOnlyByLineLead() {
        let markers = ["///", "//", "*", "/*"]
        var offenders: [String] = []
        for source in Self.productionSources() {
            for (number, line) in source.text.components(separatedBy: "\n").enumerated() {
                guard line.contains(Self.legacyHostSymbol) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !markers.contains(where: { trimmed.hasPrefix($0) }) else { continue }
                offenders.append("\(source.relative):\(number + 1)")
            }
        }
        let outsideHost = offenders.filter { !$0.hasPrefix("\(Self.legacyHostPath):") }
        #expect(
            outsideHost.isEmpty,
            """
            Lines naming \(Self.legacyHostSymbol) outside a comment and outside its own \
            file: \(outsideHost.joined(separator: ", ")). Any entry here is a live \
            reachability path and blocks the deletion.
            """
        )
        // Inside its own file, before deletion, the only such line is the
        // declaration; after deletion the file is gone and the list is empty.
        #expect(offenders.count <= 1)
    }

    @Test("The legacy host has no explicit project or package membership to unpick")
    func legacyHostHasNoExplicitProjectMembership() throws {
        let root = Self.repoRoot()
        for manifest in ["project.yml", "Package.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(manifest), encoding: .utf8)
            #expect(
                !text.contains("\(Self.legacyHostSymbol).swift"),
                "\(manifest) names \(Self.legacyHostSymbol).swift explicitly; deleting the file would break generation."
            )
        }
    }

    // MARK: - The deletion itself.

    @Test("The proven-unreachable ChartDetailScreen host is deleted")
    func provenUnreachableLegacyHostIsAbsent() {
        let path = Self.repoRoot().appendingPathComponent(Self.legacyHostPath).path
        #expect(
            !FileManager.default.fileExists(atPath: path),
            "EXPECTED_RED: proven unreachable ChartDetailScreen source still exists"
        )
    }

    @Test("Deleting the host keeps every reusable chart store and component")
    func reusableChartAssetsSurviveTheDeletion() {
        let root = Self.repoRoot()
        let missing = Self.reusableChartAssets.filter {
            !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        #expect(
            missing.isEmpty,
            """
            09-08 deletes exactly one proven-unreachable host. These reusable assets are \
            missing and must not be: \(missing.joined(separator: ", ")).
            """
        )
    }

    // MARK: - The replacement routes still exist.

    @Test("Dashboard tile tap unifies onto the Insights tab, never a Home-stack detail screen")
    func dashboardDrillDownUsesWebMirror() throws {
        let code = try CodeOnlySwift.strip(loadSource("Screens", "Dashboard", "DashboardScreen.swift"))
        // v0.13.1 IC — NAV UNIFICATION. The Dashboard no longer hosts ANY metric
        // detail screen of its own (it pushed `InsightsMetricScreen` onto the
        // Home stack pre-IC, which felt like a duplicate view). The tile tap now
        // drives the `.insights(metric:)` deep link via the router, landing the
        // operator in the Insights tab on that metric's page.
        #expect(code.contains("router.selectInsightsMetric("))
        #expect(!code.contains("InsightsMetricScreen("))
    }

    @Test("Insights notable-trend chip drills into the navigable Insights metric seam")
    func insightsTrendChipUsesWebMirror() throws {
        // v0.14.3 E4: the overview Trends row routes through the SAME navigable
        // seam as the Home tile + wellness contributors (tab strip + swipe +
        // back) via `router.selectInsightsMetric(kind)`, replacing the old
        // dead-end `trendChartMetric` push.
        let code = try CodeOnlySwift.strip(loadSource("Screens", "Insights", "InsightsScreen.swift"))
        #expect(code.contains("router.selectInsightsMetric("))
    }

    @Test("Long-tail Insights tile drills into InsightsMetricScreen")
    func perKindTileUsesWebMirror() throws {
        let code = try CodeOnlySwift.strip(loadSource("Screens", "Insights", "PerKindInsightsBlock.swift"))
        #expect(code.contains("InsightsMetricScreen("))
    }

    @Test("Insights target tile drills into InsightsMetricScreen")
    func targetTileUsesWebMirror() throws {
        let code = try CodeOnlySwift.strip(
            loadSource("Screens", "Insights", "Sub", "Tiles", "InsightsTargetTileGrid.swift")
        )
        #expect(code.contains("InsightsMetricScreen("))
    }

    /// W-B187 (Settings consolidation §A.2) — the legacy-chart-view PARKING ROW
    /// was removed from `SettingsAdvancedScreen` (a developer artifact in a user
    /// privacy/security screen). That removal is what made the host unreachable,
    /// so it is pinned separately from the generic reachability sweep above.
    @Test("Legacy chart view is no longer surfaced from Settings → Privacy & Security")
    func legacyChartRowRemovedFromSettings() throws {
        let code = try CodeOnlySwift.strip(
            loadSource("Screens", "Settings", "Sub", "SettingsAdvancedScreen.swift")
        )
        #expect(!code.contains("settings.advanced.legacyChartRow"))
    }

    // MARK: - The web-mirror screen is standalone-capable (optional strip dep).

    @Test("InsightsMetricScreen reads InsightsStripVisibility as OPTIONAL so it renders standalone")
    func metricScreenStripDependencyIsOptional() throws {
        // file_length split: the screen's source spans the screen file plus its
        // `+Sections.swift` sibling (pure code movement) — assert across both.
        let source = try loadSource("Screens", "Insights", "InsightsMetricScreen.swift")
            + loadSource("Screens", "Insights", "InsightsMetricScreen+Sections.swift")
        // The pager coupling is made optional — that is what lets the same screen
        // serve both the Insights pager AND the standalone Dashboard/tile
        // drill-down without crashing on a missing environment value.
        #expect(source.contains("private var stripVisibility: InsightsStripVisibility?"))
        #expect(source.contains("stripVisibility?.report(offset:"))
        // It accepts the presenting screen's matched-geometry namespace so the
        // Dashboard hero zoom-morph is preserved into the hero number.
        #expect(source.contains("matchedNamespace: Namespace.ID? = nil"))
        #expect(source.contains("HeroStrip(store: store, matchedNamespace: matchedNamespace)"))
    }
}

// MARK: - Comment stripper

/// Removes Swift comments while preserving string literals verbatim.
///
/// Literals are preserved on purpose: a deep-link path or a route key that
/// spells a type's name is a genuine reference, and dropping literals would
/// make this scanner report fewer references than exist — the wrong direction
/// for a proof that something is safe to delete. Comments are dropped because
/// they are documentation, not reachability.
///
/// Handles `//`, nested `/* */`, single-line and multiline literals, and raw
/// (`#"…"#`) literals of any hash depth, so a `//` inside a literal never
/// starts a comment and a `"` inside a comment never opens a literal.
enum CodeOnlySwift {
    private struct Scanner {
        let chars: [Character]
        var index = 0
        var out: [Character] = []
        var blockDepth = 0
        var inLineComment = false
        /// Hash depth of the literal currently open; `nil` when in code.
        var literalHashes: Int?
        var literalIsMultiline = false

        init(_ source: String) {
            chars = Array(source)
            out.reserveCapacity(chars.count)
        }

        func repeated(_ character: Character, _ count: Int) -> [Character] {
            Array(repeating: character, count: count)
        }

        func matches(_ needle: [Character], at position: Int) -> Bool {
            guard position >= 0, position + needle.count <= chars.count else { return false }
            for offset in 0 ..< needle.count where chars[position + offset] != needle[offset] {
                return false
            }
            return true
        }

        mutating func run() -> String {
            while index < chars.count {
                if literalHashes != nil {
                    stepInLiteral()
                } else if inLineComment {
                    stepInLineComment()
                } else if blockDepth > 0 {
                    stepInBlockComment()
                } else {
                    stepInCode()
                }
            }
            return String(out)
        }

        private mutating func stepInLiteral() {
            guard let hashes = literalHashes else { return }
            let escape: [Character] = ["\\"] + repeated("#", hashes)
            if matches(escape, at: index) {
                let span = min(escape.count + 1, chars.count - index)
                out.append(contentsOf: chars[index ..< index + span])
                index += span
                return
            }
            let closer = repeated("\"", literalIsMultiline ? 3 : 1) + repeated("#", hashes)
            if matches(closer, at: index) {
                out.append(contentsOf: closer)
                index += closer.count
                literalHashes = nil
                return
            }
            // A single-line literal cannot span a newline. Recovering here keeps
            // one malformed line from swallowing the rest of the file.
            if chars[index] == "\n", !literalIsMultiline { literalHashes = nil }
            out.append(chars[index])
            index += 1
        }

        private mutating func stepInLineComment() {
            if chars[index] == "\n" {
                inLineComment = false
                out.append("\n")
            }
            index += 1
        }

        private mutating func stepInBlockComment() {
            if matches(["/", "*"], at: index) {
                blockDepth += 1
                index += 2
                return
            }
            if matches(["*", "/"], at: index) {
                blockDepth -= 1
                index += 2
                return
            }
            // Newlines survive so line-oriented reasoning still holds downstream.
            if chars[index] == "\n" { out.append("\n") }
            index += 1
        }

        private mutating func stepInCode() {
            if matches(["/", "/"], at: index) {
                inLineComment = true
                index += 2
                return
            }
            if matches(["/", "*"], at: index) {
                blockDepth = 1
                index += 2
                return
            }
            if chars[index] == "#" || chars[index] == "\"", openLiteral() { return }
            out.append(chars[index])
            index += 1
        }

        /// Opens a literal when `#`* is followed by `"`; returns false otherwise
        /// so `#Preview`, `#expect` and friends stay ordinary code.
        private mutating func openLiteral() -> Bool {
            var hashes = 0
            while index + hashes < chars.count, chars[index + hashes] == "#" {
                hashes += 1
            }
            guard matches(["\""], at: index + hashes) else { return false }
            let multiline = matches(["\"", "\"", "\""], at: index + hashes)
            let opener = repeated("#", hashes) + repeated("\"", multiline ? 3 : 1)
            out.append(contentsOf: opener)
            index += opener.count
            literalHashes = hashes
            literalIsMultiline = multiline
            return true
        }
    }

    static func strip(_ source: String) -> String {
        var scanner = Scanner(source)
        return scanner.run()
    }
}
