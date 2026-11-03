import Foundation

/// **#134 (server v1.43) — "Support-Info kopieren".**
///
/// A few plain-text lines a person pastes into a support request, so the
/// operator can find the fault without a round of questions: app version and
/// build, iOS version, device class, app language, the server's version and
/// build, the account's time zone, the modules that are on, every AI
/// capability with its reason and the usage level, the Apple Health block of
/// the Sync Diagnostics report, and the last failures with their request ids
/// and error codes (``RecentFailureLines``; since server v1.43.7 every failure
/// carries a code, an `http.*` one where the route has none of its own).
/// Fixed English words, the same style as W5's Sync Diagnostics report, so
/// the text reads the same on every phone.
///
/// **What it never carries.** No name, e-mail or account id, no server
/// address, no token, no health value, no record id. The builder only takes
/// the inputs below, and every server-provided string is checked against a
/// narrow shape before it is printed, so nothing personal can leak in from a
/// field it never sees. `SupportInfoReportTests` pins that.
struct SupportInfoReport: Equatable {
    struct Input {
        var generatedAt: Date
        var build: AppBuildMetadata
        var osVersion: String
        /// `iPhone` or `iPad`, never the device's name.
        var deviceClass: String
        /// The language the app runs in (`de`, `en`).
        var appLanguage: String?
        /// A fresh answer of `GET /api/version`, when the server answered.
        var server: ServerVersionInfo?
        /// The last version this phone learned, when the server did not answer.
        var lastKnownServerVersion: String?
        /// Newest first, from ``RecentFailureLog/snapshot()``.
        var failures: [RecentFailure]
        /// #134 — the account's zone as `/api/auth/me` resolved it.
        var timeZone: String?
        /// #134 — `/api/auth/me` `modules`; `nil` before the first load.
        var modules: [String: Bool]?
        /// #134 — `/api/auth/me` `ai`; `nil` before the first load and on a
        /// server older than v1.39.
        var ai: AIAccountBlock?
        /// #134 — `GET /api/integrations/healthkit`, when it answered in time.
        var appleHealth: HKServerSyncHealthSummary?
        var appleHealthLoadFailed = false
    }

    let text: String

    init(_ input: Input) {
        var lines = ["HealthLog support info"]
        lines.append("generated: \(input.generatedAt.formatted(.iso8601))")
        let version = Self.token(input.build.marketingVersion) ?? "unknown"
        let build = Self.token(input.build.build) ?? "unknown"
        lines.append("app: \(version) (\(build))")
        lines.append("os: iOS \(Self.token(input.osVersion) ?? "unknown")")
        lines.append("device: \(Self.token(input.deviceClass) ?? "unknown")")
        lines.append("language: \(Self.token(input.appLanguage) ?? "unknown")")
        lines.append("server version: \(Self.serverLine(input))")
        lines += Self.accountLines(input)
        lines += SyncDiagnosticsReport.appleHealthLines(input.appleHealth, loadFailed: input.appleHealthLoadFailed)
        lines += RecentFailureLines.lines(input.failures)
        text = lines.joined(separator: "\n") + "\n"
    }

    private static func serverLine(_ input: Input) -> String {
        if let server = input.server, let version = token(server.version) {
            guard let sha = token(server.buildSha) else { return version }
            return "\(version) (build \(sha))"
        }
        if let known = token(input.lastKnownServerVersion) {
            return "\(known) (last known, not reachable now)"
        }
        return "not reachable"
    }

    /// A version, build or language token: letters, digits, `.`, `-`, `+`,
    /// `_`, at most 40 characters. Anything else is not such a token and is
    /// left out rather than printed.
    static func token(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1 ... 40).contains(value.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || ".-+_".unicodeScalars.contains(scalar))
              }) else { return nil }
        return value
    }
}
