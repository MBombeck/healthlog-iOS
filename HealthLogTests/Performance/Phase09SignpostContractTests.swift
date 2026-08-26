import Foundation
@testable import HealthLog
import Testing

/// **Phase 09 Wave 0 — the measurement contract, before any optimisation.**
///
/// Phase 9 claims that six flows get faster or smaller. A claim like that is
/// only worth something if the boundary it is measured at existed *before* the
/// change, is named identically in the trace and in the evidence file, and
/// closes on every exit path including the throwing and the cancelled one. This
/// suite is what makes that true, and it is deliberately the first thing the
/// phase lands.
///
/// It asserts two different kinds of thing, and keeps them apart on purpose.
///
/// **Structural clauses** read production source. Every such clause reads a
/// *comment-stripped* view (a doc comment that merely mentions
/// `apple-import.upload` must not satisfy a clause asking whether the interval
/// is opened) and every clause is **bounded to one declaration's brace-matched
/// body** (a signpost opened in some unrelated function must not satisfy a
/// clause about `upload`). Both of those defences exist because assertions in
/// this repository have previously passed for the wrong reason.
///
/// **Behavioural clauses** install a recorder into the signpost facility and
/// drive the real production call path, then assert the begin/end ledger is
/// balanced and correctly named. Those live in
/// `Phase09SignpostContractTests+Balance.swift` — same suite type, so the same
/// `-only-testing` selector runs both halves — and they are the ones that would
/// catch a `defer` someone deletes later.
///
/// What this suite does **not** do is assert a wall-clock duration. Elapsed
/// time and resident memory are physical-device evidence
/// (`09-PERFORMANCE-EVIDENCE.md`); a simulator number would be a fabricated
/// baseline, and the entire point of Wave 0 is that a measurement precedes a
/// claim.
///
/// Serialized because the signpost recorder is process-wide state: two cases
/// installing their own recorder concurrently would each see the other's
/// intervals, and a balance assertion that can be satisfied by a neighbour's
/// work is not a balance assertion.
@Suite("Phase09SignpostContractTests — Phase 09 intervals and seams", .serialized)
struct Phase09SignpostContractTests {
    // MARK: - The production contract

    /// The eight intervals and the seams the later Phase-9 plans consume.
    ///
    /// Every missing piece is collected rather than short-circuited, so the RED
    /// run names the complete gap in one pass instead of revealing it one
    /// `xcodebuild` invocation at a time.
    @Test("every Phase 9 interval and seam exists in production")
    func allRequiredIntervalsAndSeamsExist() throws {
        var violations: [String] = []
        try violations.append(contentsOf: Self.vocabularyViolations())
        try violations.append(contentsOf: Self.appleImportViolations())
        try violations.append(contentsOf: Self.persistenceViolations())
        try violations.append(contentsOf: Self.moodAnalysisViolations())
        try violations.append(contentsOf: Self.lifecycleViolations())

        // Diagnostics go to stdout, not to a second recorded issue: the RED
        // gate requires exactly one `EXPECTED_RED:` reason in the log, and a
        // pile of extra issues is how that invariant gets broken by accident.
        for violation in violations {
            print("phase09-measurement-gap: \(violation)")
        }
        #expect(violations.isEmpty, "EXPECTED_RED: Phase 9 intervals and seams are incomplete")
    }

    /// The interval vocabulary itself, bounded to the enum that declares it, and
    /// the balanced-by-construction facility that opens them.
    ///
    /// A hand-written begin/end pair at eight call sites is eight chances to
    /// forget the end on the throwing path; `measure` closes in a `defer` it
    /// owns, so the balance is a property of the facility rather than of the
    /// discipline of whoever edits the call site next.
    private static func vocabularyViolations() throws -> [String] {
        var violations: [String] = []
        let intervalBody = try declarationBody("HealthLog/DesignSystem/HLPerfSignpost.swift", containing: "enum Interval")
        for name in requiredIntervalNames where !intervalBody.contains("\"\(name)\"") {
            violations.append("HLPerfSignpost.Interval does not declare the interval \(name)")
        }
        let source = try strippedSource("HealthLog/DesignSystem/HLPerfSignpost.swift")
        if !source.contains("enum Magnitude") {
            violations.append("HLPerfSignpost declares no categorical Magnitude — a signpost must not carry a byte count")
        }
        if !source.contains("func measure") {
            violations.append("HLPerfSignpost declares no balanced `measure` facility")
        }
        return violations
    }

    /// Preparation and transport are separate boundaries because 09-02 changes
    /// one of them and must not be able to hide the cost in the other.
    private static func appleImportViolations() throws -> [String] {
        var violations: [String] = []
        let body = try declarationBody("HealthLog/Services/AppleHealthImportService.swift", containing: "func upload(")
        if !body.contains(".appleImportPrepare") {
            violations.append("AppleHealthImportService.upload does not open apple-import.prepare")
        }
        if !body.contains(".appleImportUpload") {
            violations.append("AppleHealthImportService.upload does not open apple-import.upload")
        }
        return violations
    }

    /// Export persistence at both PHI write seams, and widget persistence plus
    /// a reload seam. `WidgetCenter` is invisible to a unit test, so 09-03's
    /// "unchanged values skip the reload" contract needs a counted reloader to
    /// exist before it can be asserted at all.
    private static func persistenceViolations() throws -> [String] {
        var violations: [String] = []
        let persist = try declarationBody("HealthLog/Stores/ExportStore.swift", containing: "static func persist(")
        if !persist.contains(".exportPersist") {
            violations.append("ExportStore.persist does not open export.persist")
        }
        let writeData = try declarationBody("HealthLog/Stores/ExportStore.swift", containing: "static func writeData(")
        if !writeData.contains(".exportPersist") {
            violations.append("ExportStore.writeData does not open export.persist")
        }
        if try !strippedSource("HealthLog/Stores/ExportStore.swift").contains("ExportPersistenceWriter") {
            violations.append("ExportStore has no injectable persistence-writer seam")
        }
        let widget = try declarationBody(
            "HealthLog/Services/WidgetSnapshotWriter.swift",
            containing: "struct WidgetSnapshotWriter"
        )
        if !widget.contains(".widgetPersist") {
            violations.append("WidgetSnapshotWriter does not open widget.persist")
        }
        if !widget.contains("WidgetTimelineReloader") {
            violations.append("WidgetSnapshotWriter has no injectable timeline-reload seam")
        }
        return violations
    }

    /// The cold and cache-hit paths are *separate* interval names, which forces
    /// the seam to answer "is this key already resident?" before it computes —
    /// exactly the shape 09-04's revision cache needs.
    private static func moodAnalysisViolations() throws -> [String] {
        var violations: [String] = []
        let engine = try strippedSource("HealthLog/Screens/Mood/MoodAnalysisEngine.swift")
        if !engine.contains(".moodAnalysisCold") || !engine.contains(".moodAnalysisHit") {
            violations.append("MoodAnalysisEngine does not open both mood-analysis.cold and mood-analysis.hit")
        }
        if !engine.contains("isCached") {
            violations.append("MoodAnalysisEngine has no O(1) cache probe, so the hit interval can never be reached")
        }
        let content = try declarationBody(
            "HealthLog/Screens/Mood/MoodAnalysisContent.swift",
            containing: "struct MoodAnalysisContent"
        )
        if !content.contains("MoodAnalysisEngine") {
            violations.append("MoodAnalysisContent still computes insights without passing the measured engine seam")
        }
        return violations
    }

    /// Outbox open at the launch-critical composition root behind an injectable
    /// factory, and the foreground pass closed by a `defer` in the one task that
    /// owns it, so a cancelled foreground cannot leave the interval hanging.
    private static func lifecycleViolations() throws -> [String] {
        var violations: [String] = []
        let coreInfra = try declarationBody(
            "HealthLog/Stores/AppContainer+CoreInfra.swift",
            containing: "static func makeCoreInfra("
        )
        if !coreInfra.contains(".outboxOpen") {
            violations.append("AppContainer.makeCoreInfra does not open outbox.open")
        }
        if !coreInfra.contains("outboxFactory") {
            violations.append("AppContainer.makeCoreInfra has no injectable outbox-open factory")
        }
        // 09-06 — the interval moved from `RootView.handle(scenePhase:)`, where
        // it was closed by a `defer` inside one arbitrarily chosen sibling task,
        // onto the coordinator that owns the whole pass. The clause moved with
        // it and gained the half it could not state before: the scene handler
        // must hand the foreground to exactly one owner rather than fan it out.
        let handle = try declarationBody("HealthLog/App/RootView.swift", containing: "func handle(scenePhase")
        if !handle.contains("startForegroundPass()") {
            violations.append("RootView.handle(scenePhase:) does not hand the foreground to one owner")
        }
        let pass = try declarationBody("HealthLog/App/ForegroundCoordinator.swift", containing: "private func run(")
        if !pass.contains("HLPerfSignpost.open(.foregroundPass)") {
            violations.append("ForegroundCoordinator.run does not open foreground.pass")
        }
        if !pass.contains("defer { HLPerfSignpost.close(token") {
            violations.append("ForegroundCoordinator.run does not close foreground.pass from a defer")
        }
        return violations
    }

    /// The bounding machinery itself, proven on source that exists today.
    ///
    /// A clause that silently scanned the whole file, or silently scanned
    /// nothing, would pass for the wrong reason in both directions. This case
    /// pins the middle: each anchor resolves, the extracted body is strictly
    /// smaller than its file, and the extracted body is brace-balanced.
    @Test("the bounded source reader extracts a real, strictly smaller declaration body")
    func boundedSourceReaderIsSound() throws {
        let anchors: [(String, String)] = [
            ("HealthLog/DesignSystem/HLPerfSignpost.swift", "enum Interval"),
            ("HealthLog/Services/AppleHealthImportService.swift", "func upload("),
            ("HealthLog/Stores/ExportStore.swift", "static func persist("),
            ("HealthLog/Stores/ExportStore.swift", "static func writeData("),
            ("HealthLog/Services/WidgetSnapshotWriter.swift", "struct WidgetSnapshotWriter"),
            ("HealthLog/Screens/Mood/MoodAnalysisContent.swift", "struct MoodAnalysisContent"),
            ("HealthLog/Stores/AppContainer+CoreInfra.swift", "static func makeCoreInfra("),
            ("HealthLog/App/RootView.swift", "func handle(scenePhase")
        ]
        for (path, anchor) in anchors {
            let whole = try Self.strippedSource(path)
            let body = try Self.declarationBody(path, containing: anchor)
            #expect(!body.isEmpty, "\(path): `\(anchor)` resolved to nothing")
            #expect(body.count < whole.count, "\(path): `\(anchor)` was not actually bounded")
            #expect(body.hasPrefix("{") && body.hasSuffix("}"), "\(path): `\(anchor)` body is not brace-delimited")
        }
    }

    /// The comment stripper must delete prose and keep string literals — and it
    /// must survive `ExportStore.swift`, whose `//` comment contains `/*`.
    @Test("the comment stripper removes prose, preserves literals, and tolerates a slash-star inside prose")
    func commentStripperIsSound() throws {
        let signposts = try Self.strippedSource("HealthLog/DesignSystem/HLPerfSignpost.swift")
        #expect(signposts.contains("\"dashboard.first-paint\""), "a string literal must survive stripping")
        #expect(!signposts.contains("Instruments"), "doc-comment prose must not survive stripping")
        let export = try Self.strippedSource("HealthLog/Stores/ExportStore.swift")
        #expect(!export.isEmpty, "a `/*` inside a `//` comment must not defeat the stripper")
        #expect(!export.contains("/api/fhir/*"), "the commented path must have been stripped with its comment")
    }

    // MARK: - Source helpers

    /// The eight interval names Phase 9 measures. These strings are the shared
    /// vocabulary between production, Instruments and the evidence file — a
    /// rename here is a rename in all three.
    static let requiredIntervalNames = [
        "apple-import.prepare",
        "apple-import.upload",
        "mood-analysis.cold",
        "mood-analysis.hit",
        "export.persist",
        "widget.persist",
        "outbox.open",
        "foreground.pass"
    ]

    /// Production source with `//` comments removed and string literals left
    /// intact (the raw interval names *are* string literals, so blanking them
    /// would defeat the clause).
    ///
    /// The stripper is line-oriented but string-literal aware, so a `//` inside
    /// a URL literal is not mistaken for a comment. It then asserts that no
    /// `/*` survives *after* line comments were removed — that ordering matters,
    /// because `ExportStore.swift` legitimately mentions `/api/fhir/*` inside a
    /// `//` comment, and a naive pre-check would have failed on prose.
    static func strippedSource(_ relativePath: String) throws -> String {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        // A missing file returns empty rather than recording a second issue:
        // the caller's clause then fires, which is the honest signal, and the
        // RED gate's "exactly one reason" invariant survives.
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let stripped = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripLineComment(String($0)) }
            .joined(separator: "\n")
        #expect(
            !stripped.contains("/*"),
            "\(relativePath) gained a block comment; the line-only stripper is no longer sound"
        )
        return stripped
    }

    /// The brace-matched body of the first declaration whose header contains
    /// `anchor`, read from the comment-stripped source. Brace matching ignores
    /// braces inside string literals.
    ///
    /// Bounding matters as much as comment stripping: without it, "the file
    /// mentions `.exportPersist` somewhere" would satisfy a clause that meant
    /// "the persist function opens it".
    static func declarationBody(_ relativePath: String, containing anchor: String) throws -> String {
        let stripped = try strippedSource(relativePath)
        guard !stripped.isEmpty else { return "" }
        let masked = maskStringLiterals(stripped)
        // Every failure below returns empty on purpose (see `strippedSource`):
        // the caller's clause is the single reported signal.
        guard let anchorRange = stripped.range(of: anchor) else { return "" }
        let offset = stripped.distance(from: stripped.startIndex, to: anchorRange.upperBound)
        let maskedChars = Array(masked)
        let strippedChars = Array(stripped)
        var index = offset
        while index < maskedChars.count, maskedChars[index] != "{" {
            index += 1
        }
        guard index < maskedChars.count else { return "" }
        let bodyStart = index
        var depth = 0
        while index < maskedChars.count {
            if maskedChars[index] == "{" { depth += 1 }
            if maskedChars[index] == "}" {
                depth -= 1
                if depth == 0 { return String(strippedChars[bodyStart ... index]) }
            }
            index += 1
        }
        return ""
    }

    /// Replaces the *contents* of every string literal with spaces, preserving
    /// length so offsets computed here address the unmasked text unchanged.
    private static func maskStringLiterals(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var inString = false
        var escaped = false
        for character in source {
            if character == "\n" {
                inString = false
                escaped = false
                result.append(character)
                continue
            }
            if inString {
                result.append(" ")
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
                result.append(" ")
                continue
            }
            result.append(character)
        }
        return result
    }

    /// Removes a trailing `//` comment, ignoring a `//` that sits inside a
    /// string literal.
    private static func stripLineComment(_ line: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        var sawSlash = false
        for character in line {
            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                sawSlash = false
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
                sawSlash = false
                continue
            }
            if character == "/", sawSlash {
                result.removeLast()
                return result
            }
            sawSlash = character == "/"
            result.append(character)
        }
        return result
    }

    static func repositoryRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Performance
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
    }
}
