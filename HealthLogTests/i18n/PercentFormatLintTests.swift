import Foundation
import Testing

/// Build-8 (b239) coherence guard — the in-suite half of the percent-format
/// lint (the other half is the `percent_use_hlnumberformat` SwiftLint
/// custom_rule in `.swiftlint.yml`; one convention, two enforcement organs).
///
/// The German display convention renders "83 %" with a narrow no-break space
/// (U+202F, DIN-5008), via `HLNumberFormat.percent(_:)`. Raw interpolation like
/// `"\(x)%"` / `"\(x) %"` bypasses that seam and ships an ASCII-glued or
/// ordinary-space percent. This guard scans `HealthLog/Screens/**` source for
/// those raw sites.
///
/// ## Tolerant baseline (per prompt: "referenziere die Konvention tolerant")
/// The raw→`HLNumberFormat.percent` conversion is item **8.5** (sibling scope),
/// and `HLNumberFormat.percent` is landed there. Until that conversion merges,
/// the currently-known raw sites live in `pendingConversionFiles`. This guard
/// therefore asserts the weaker-but-actionable invariant: **no NEW file** grows
/// a raw percent site beyond the known-pending baseline. As item 8.5 converts a
/// file it drops out of the scan naturally; the baseline entry then becomes
/// harmless dead weight and can be pruned. A brand-new raw percent site in any
/// other Screens file fails immediately.
@Suite("Percent-Lint — keine NEUEN rohen Prozent-Stellen in Screens (HLNumberFormat.percent nutzen)")
struct PercentFormatLintTests {
    /// Screens files that carry a raw percent site today, pending the item-8.5
    /// `HLNumberFormat.percent` conversion. Paths are relative to
    /// `HealthLog/Screens/`. Shrinks as 8.5 lands.
    static let pendingConversionFiles: Set<String> = [
        "Insights/Sub/SleepStageCompositionCard.swift",
        "Insights/Sub/WellnessScoreDetailSheet.swift",
        "Insights/Sub/MetricRangeDelta.swift",
        "Insights/Sub/InsightsInTargetBar.swift",
        "Insights/Sub/InsightsAuxChartDetailScreen.swift",
        "Settings/Sub/SettingsAppleHealthImportScreen.swift",
        // 08-13 removed the compact medication row this list used to name; its
        // entry went with the file in the same commit. That is what the
        // baseline-rot case below exists for — a pending-conversion path that
        // no longer resolves is a red test, not silent dead weight.
        "Medications/MedicationDetailSections.swift",
        "Achievements/AchievementsScreen.swift",
        "Achievements/AchievementDetailSheet.swift",
        "Workouts/WorkoutDetailView.swift",
        "Mood/MoodTagPicker.swift"
    ]

    // Raw percent interpolation: an interpolation-close (or any char) directly
    // (or one space) before a literal `%"`, plus the printf `%%` form.
    // nonisolated(unsafe): a compiled-once, immutable Regex. Regex isn't Sendable
    // so Swift 6 flags the static, but there is no post-construction mutable state.
    private nonisolated(unsafe) static let rawPercent = #/\)\s?%"|%\.[0-9]f%%/#

    /// `resolvingSymlinksInPath()` ist load-bearing: `#filePath` liefert den
    /// Übersetzungspfad (`/tmp/wt-x/…`), `FileManager.enumerator` seine URLs
    /// symlink-aufgelöst (`/private/tmp/wt-x/…`, weil `/tmp` auf macOS ein
    /// Symlink ist). Ohne Auflösung auf beiden Seiten greift der Präfix-Abgleich
    /// in `screenSwiftFiles()` nicht, die Liste fällt leer aus und dieser Guard
    /// wird **stumm grün**, statt zu prüfen. Im normalen Arbeitsverzeichnis
    /// (`~/Projects/…`) fiel das nicht auf; in einem `/tmp`-Worktree schon.
    private nonisolated static func screensRoot(file: String = #filePath) -> URL {
        // <repo>/HealthLogTests/i18n/PercentFormatLintTests.swift
        //   → <repo>/HealthLog/Screens
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // i18n
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .resolvingSymlinksInPath()
    }

    /// Every `*.swift` under `HealthLog/Screens`, as paths relative to that root.
    private nonisolated static func screenSwiftFiles() -> [(relative: String, url: URL)] {
        let root = screensRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var result: [(String, URL)] = []
        let rootPath = root.path
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            var rel = url.resolvingSymlinksInPath().path
            guard rel.hasPrefix(rootPath) else { continue }
            rel.removeFirst(rootPath.count)
            if rel.hasPrefix("/") { rel.removeFirst() }
            result.append((rel, url))
        }
        return result
    }

    @Test("Der Scan sieht den Quellbaum überhaupt — sonst ist dieser Guard stumm grün")
    func scanSeesTheSourceTree() {
        let count = Self.screenSwiftFiles().count
        #expect(count > 200, "Nur \(count) Screens-Dateien gefunden — der Pfadabgleich ist kaputt, nicht der Quellbaum leer.")
    }

    @Test("Kein neues rohes Prozent-Literal in Screens außerhalb der 8.5-Pending-Baseline")
    func noNewRawPercentSites() throws {
        var unexpected: [String] = []
        for (relative, url) in Self.screenSwiftFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            guard source.firstRange(of: Self.rawPercent) != nil else { continue }
            if !Self.pendingConversionFiles.contains(relative) {
                unexpected.append(relative)
            }
        }
        #expect(
            unexpected.isEmpty,
            "Neue rohe Prozent-Stellen (HLNumberFormat.percent nutzen) in: \(unexpected.sorted())"
        )
    }

    @Test("Baseline verrottet nicht: jede gelistete Pending-Datei existiert noch")
    func baselineFilesStillExist() {
        let root = Self.screensRoot()
        var missing: [String] = []
        for relative in Self.pendingConversionFiles {
            let url = root.appendingPathComponent(relative)
            if !FileManager.default.fileExists(atPath: url.path) {
                missing.append(relative)
            }
        }
        #expect(missing.isEmpty, "Pending-Baseline zeigt auf verschobene/gelöschte Dateien: \(missing.sorted())")
    }
}
