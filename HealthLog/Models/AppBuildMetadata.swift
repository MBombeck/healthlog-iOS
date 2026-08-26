import Foundation

/// **08-07 — the exact identity of the running binary.**
///
/// `CFBundleShortVersionString` and `CFBundleVersion` are two *independent*
/// Apple-owned strings. The first is the marketing version a store listing
/// shows; the second is the number an archive was uploaded under. No
/// arithmetic relates them, so any value computed from both is invented —
/// About shipped `short + "." + (build - 40)` and displayed a four-segment
/// version that exists in no tag, no archive and no store listing.
///
/// This type therefore does exactly two things, and neither is arithmetic:
///
/// 1. it decides whether a raw Info-dictionary value is usable at all, and
/// 2. it hands that value back **verbatim** when it is.
///
/// A value that is absent, of a non-string type, or blank is `nil` rather
/// than a guess. `nil` is a fact about the bundle, and the caller states it
/// as one (``marketingVersionText(unknown:)``) instead of substituting a
/// plausible number.
///
/// The type is a pure value with no `Bundle` dependency, so the whole
/// contract — including the missing-value cases a shipped bundle can never
/// reproduce — is testable without standing up a view or a host app.
struct AppBuildMetadata: Equatable, Sendable {
    /// `CFBundleShortVersionString` exactly as the bundle carries it, or `nil`
    /// when the bundle carries no usable value.
    let marketingVersion: String?

    /// `CFBundleVersion` exactly as the bundle carries it, or `nil` when the
    /// bundle carries no usable value. Never derived from, and never
    /// combined with, ``marketingVersion``.
    let build: String?

    /// Takes the two raw values an Info dictionary yields. `Any?` rather than
    /// `String?` on purpose: `object(forInfoDictionaryKey:)` is untyped, and
    /// "the plist held a number" is one of the cases this type has to answer
    /// for. The caller names the two keys at its own call site so a reader
    /// can check what is displayed against what was read.
    init(marketingVersion: Any?, build: Any?) {
        self.marketingVersion = Self.exact(marketingVersion)
        self.build = Self.exact(build)
    }

    /// The marketing version to display, or `unknown` when the bundle carries
    /// none. The caller supplies the localized wording; this type never
    /// invents a version to show in its place.
    func marketingVersionText(unknown: String) -> String {
        marketingVersion ?? unknown
    }

    /// The build to display, or `unknown` when the bundle carries none.
    func buildText(unknown: String) -> String {
        build ?? unknown
    }

    /// True when the bundle names both values, i.e. when the identity shown
    /// is complete rather than partially unknown.
    var isComplete: Bool {
        marketingVersion != nil && build != nil
    }

    /// The one normalisation applied anywhere in this type: surrounding
    /// whitespace is dropped, because it changes nothing about *which*
    /// version is named, and a value that is empty once it is gone names no
    /// version at all. Everything else — segment count, separators, letters,
    /// leading zeroes — is passed through untouched, because the bundle is
    /// the authority on its own identity.
    private static func exact(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
