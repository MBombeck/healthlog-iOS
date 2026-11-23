import Foundation
@testable import HealthLog
import Testing

/// **The measurement contract, before any optimisation.**
///
/// Phase 9 claims that six flows get faster or smaller. A claim like that is
/// only worth something if the boundary it is measured at existed *before* the
/// change, is named identically in the trace and in the evidence file, and
/// closes on every exit path including the throwing and the cancelled one. This
/// suite is what makes that true, and it is deliberately the first thing the
/// phase lands.
///
/// The behavioural clauses install a recorder into the signpost facility and
/// drive the real production call path, then assert the begin/end ledger is
/// balanced and correctly named. They live in
/// `Phase09SignpostContractTests+Balance.swift`. This file keeps the shared
/// interval vocabulary and the bounded source reader other suites still use,
/// with the reader's own soundness checks.
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
    // MARK: - Source reader soundness

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
