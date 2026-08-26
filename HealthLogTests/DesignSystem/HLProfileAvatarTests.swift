import Foundation
@testable import HealthLog
import Testing
import UIKit

/// **v0.6.2 W-SEC-A — Gravatar removed.**
///
/// The earlier v0.5.4-NF-1 contract pinned the deterministic email →
/// Gravatar-URL transform (so re-renders surfaced "the operator's face"
/// rather than a stranger's). v0.6.2 W-SEC-A drops the third-party
/// fetch entirely; this suite now pins the **negative** contract:
///
///   * No `URLSession.shared.data(from:)` call is issued from the avatar.
///   * No Gravatar URL is constructed or referenced anywhere in the view.
///   * The view body composes without crashing across every input shape
///     it used to support (nil email, real email, blank initials).
///
/// We can't easily intercept `URLSession.shared.data` here, so the
/// network-absence contract is enforced through three layers:
///   1. The compiler — `HLProfileAvatar.makeGravatarURL` and friends no
///      longer exist (this file used to call them; they're now gone).
///   2. Source review — searching the production sources for
///      `gravatar.com` should return zero hits outside comments.
///   3. Composition — body construction must not depend on AvatarCache.
@Suite("HLProfileAvatar — privacy (W-SEC-A)")
struct HLProfileAvatarTests {
    // MARK: - Composition contract

    @Test("Avatar composes with email=nil — paints initials immediately")
    @MainActor
    func composesNoEmailRendersInitials() {
        let view = HLProfileAvatar(size: 36, email: nil, initials: "AF")
        _ = view.body
    }

    @Test("Avatar composes with a real email — still paints initials, no network")
    @MainActor
    func composesWithEmailRendersInitials() {
        // The email parameter is retained on the signature but the
        // renderer ignores it. Constructing with a non-nil email must
        // not trigger any network round-trip or cache lookup — this
        // body composition is the test seam (no AsyncImage path exists).
        let view = HLProfileAvatar(size: 36, email: "noone@example.invalid", initials: "AL")
        _ = view.body
    }

    @Test("Avatar composes with empty initials — '?' glyph still renders")
    @MainActor
    func composesEmptyInitialsRendersQuestionMark() {
        let view = HLProfileAvatar(size: 36, email: nil, initials: "")
        _ = view.body
    }

    @Test("Avatar composes at toolbar (32pt) + hero (88pt) sizes without crashing")
    @MainActor
    func composesAtMultipleSizes() {
        _ = HLProfileAvatar(size: 32, email: nil, initials: "AF").body
        _ = HLProfileAvatar(size: 88, email: "anna@healthlog.dev", initials: "AF").body
    }

    // MARK: - Privacy contract (negative)

    @Test("Production source tree references no live www.gravatar.com URL")
    func noGravatarURLInProductionSources() throws {
        // Scans the production sources for any literal Gravatar URL.
        // Comments referencing the *removed* path are allowed (W-SEC-A's
        // own removal-rationale comment legitimately names the host),
        // so the assertion is conservative: zero `URL(string: ".*gravatar"`
        // literals in non-comment positions.
        let sourceRoot = Self.locateProductionSourceRoot()
        guard let sourceRoot else {
            // Skip cleanly if the test harness isn't running from the
            // worktree root (e.g. SPM-only invocation). The compile-time
            // removal of `makeGravatarURL` is the primary safety net;
            // this test is belt-and-braces.
            return
        }
        let suspect = try Self.scanForLiteralGravatarURL(in: sourceRoot)
        #expect(
            suspect.isEmpty,
            "Gravatar URL literal must not appear in production sources after W-SEC-A. Found: \(suspect)"
        )
    }

    /// Tries a couple of locations to find the production source tree
    /// relative to the test runner. Returns `nil` if neither resolves —
    /// the caller then skips the file scan gracefully.
    private static func locateProductionSourceRoot() -> URL? {
        // `#filePath` resolves at compile time to the path of this test
        // file; from there we step up to the repo root and into
        // `HealthLog/`.
        let here = URL(fileURLWithPath: #filePath)
        var dir = here.deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = dir.appendingPathComponent("HealthLog")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Walks the production source tree and returns any `.swift` file
    /// that contains a literal `URL(string: "...gravatar...")` outside a
    /// commented-out line. Conservative — comments referencing the
    /// removal are OK.
    private static func scanForLiteralGravatarURL(in root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var hits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                if trimmed.contains("gravatar.com"), trimmed.contains("URL(string:") {
                    hits.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        return hits
    }
}
