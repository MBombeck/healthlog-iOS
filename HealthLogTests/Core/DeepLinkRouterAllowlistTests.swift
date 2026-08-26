import Foundation
@testable import HealthLog
import Testing

/// M-5 defence-in-depth — `DeepLinkRoute(url:)` MUST allowlist any ID-bearing
/// path component before constructing the typed route. Without it, a URL like
/// `healthlog://medications/abc%2F..%2Fbadroute` percent-decodes via
/// `pathComponents` into `parts[0] = "abc/../badroute"` and would land in
/// `.medication(id: "abc/../badroute")`. None of the current downstream
/// callers concatenate that into a URL path, but defence-in-depth keeps
/// future refactors safe.
@Suite("DeepLinkRoute ID allowlist (M-5)")
struct DeepLinkRouterAllowlistTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string), "Test-Fixture URL ungültig: \(string)")
    }

    // MARK: - Happy paths

    @Test("Valid cuid medication ID is accepted")
    func happyMedicationCuid() throws {
        let route = try DeepLinkRoute(url: url("healthlog://medications/cm5abc123def456"))
        #expect(route == .medication(id: "cm5abc123def456"))
    }

    @Test("Valid UUID-shaped medication ID is accepted")
    func happyMedicationUUID() throws {
        let route = try DeepLinkRoute(url: url("healthlog://medications/11111111-2222-3333-4444-555555555555"))
        #expect(route == .medication(id: "11111111-2222-3333-4444-555555555555"))
    }

    @Test("Valid medication-history ID is accepted")
    func happyMedicationHistory() throws {
        let route = try DeepLinkRoute(url: url("healthlog://medications/med_abc123/history"))
        #expect(route == .medicationHistory(id: "med_abc123"))
    }

    @Test("Valid personal-record ID is accepted")
    func happyPersonalRecord() throws {
        let route = try DeepLinkRoute(url: url("healthlog://personal-records/pr_streak2026"))
        #expect(route == .personalRecord(id: "pr_streak2026"))
    }

    @Test("Valid metric slug is accepted")
    func happyMetricSlug() throws {
        let route = try DeepLinkRoute(url: url("healthlog://insights/blood-pressure"))
        #expect(route == .insights(metric: "blood-pressure"))
    }

    // MARK: - Traversal attempts

    @Test("Percent-encoded slash traversal lands in .unknown")
    func traversalEncodedSlash() throws {
        // `%2F` decodes to `/` in `pathComponents`; the resulting "abc/../bad"
        // would survive into `.medication(id:)` without the guard.
        let parsedURL = try url("healthlog://medications/abc%2F..%2Fbadroute")
        let route = DeepLinkRoute(url: parsedURL)
        guard case let .unknown(actual) = route else {
            Issue.record("Expected .unknown for traversal attempt, got \(String(describing: route))")
            return
        }
        #expect(actual == parsedURL)
    }

    @Test("Literal `..` segment lands in .unknown")
    func traversalDotDot() throws {
        // `healthlog://medications/..` parses Host="medications", parts=[".."]
        // ".." matches neither the cuid allowlist nor the metric slug.
        let parsedURL = try url("healthlog://medications/..")
        let route = DeepLinkRoute(url: parsedURL)
        guard case .unknown = route else {
            Issue.record("Expected .unknown for `..` ID, got \(String(describing: route))")
            return
        }
    }

    @Test("Personal-record ID with slash chars lands in .unknown")
    func personalRecordTraversal() throws {
        // `personal-records/pr_abc%2F..` → parts[0] decodes to "pr_abc/.."
        // — the allowlist rejects the slash.
        let parsedURL = try url("healthlog://personal-records/pr_abc%2F..")
        guard case .unknown = DeepLinkRoute(url: parsedURL) else {
            Issue.record("Expected .unknown for personal-record traversal")
            return
        }
    }

    @Test("Insights metric slug with traversal lands in .unknown")
    func insightsTraversal() throws {
        let parsedURL = try url("healthlog://insights/blood-pressure%2F..")
        guard case .unknown = DeepLinkRoute(url: parsedURL) else {
            Issue.record("Expected .unknown for insights metric traversal")
            return
        }
    }

    // MARK: - Over-length attempts

    @Test("Medication ID longer than 64 chars lands in .unknown")
    func overlongMedication() throws {
        let oversized = String(repeating: "a", count: 65)
        let parsedURL = try url("healthlog://medications/\(oversized)")
        guard case .unknown = DeepLinkRoute(url: parsedURL) else {
            Issue.record("Expected .unknown for over-length medication id")
            return
        }
    }

    @Test("Personal-record ID exactly 64 chars accepted")
    func boundary64Chars() throws {
        let id = String(repeating: "a", count: 64)
        let route = try DeepLinkRoute(url: url("healthlog://personal-records/\(id)"))
        #expect(route == .personalRecord(id: id))
    }

    @Test("Insights metric slug longer than 48 chars lands in .unknown")
    func overlongMetricSlug() throws {
        let slug = String(repeating: "x", count: 49)
        let parsedURL = try url("healthlog://insights/\(slug)")
        guard case .unknown = DeepLinkRoute(url: parsedURL) else {
            Issue.record("Expected .unknown for over-length metric slug")
            return
        }
    }

    // MARK: - Charset attempts

    @Test("Medication ID with unicode character lands in .unknown")
    func unicodeIDRejected() throws {
        let parsedURL = try url("healthlog://medications/med%E2%9C%93")
        guard case .unknown = DeepLinkRoute(url: parsedURL) else {
            Issue.record("Expected .unknown for unicode-containing id")
            return
        }
    }

    @Test("Medication ID with dot lands in .unknown (dot is not in cuid/UUID alphabet)")
    func dotInIDRejected() throws {
        let parsedURL = try url("healthlog://medications/abc.def")
        guard case .unknown = DeepLinkRoute(url: parsedURL) else {
            Issue.record("Expected .unknown for dot-containing id")
            return
        }
    }

    @Test("Metric slug with upper-case letter lands in .unknown")
    func upperCaseSlugRejected() throws {
        let parsedURL = try url("healthlog://insights/BloodPressure")
        guard case .unknown = DeepLinkRoute(url: parsedURL) else {
            Issue.record("Expected .unknown for upper-case metric slug")
            return
        }
    }

    // MARK: - Empty / structural

    @Test("Bare `medications` host with no ID → .medications (Meds list root, W0-2)")
    func bareMedications() throws {
        // v0.12 W0-2 — the host-only form now resolves to the Meds list root
        // (`.medications`), not `.unknown` → Dashboard. The med-reminder no-id
        // fallback relies on this so a tap lands on the medications list.
        try #expect(DeepLinkRoute(url: url("healthlog://medications")) == .medications)
    }

    @Test("Trailing-slash bare medications host → .medications (Meds list root, W0-2)")
    func emptyIDComponent() throws {
        // `healthlog://medications/` → URL has trailing slash; pathComponents =
        // ["/"]; filter("/" != $0) = [] → host-only form. v0.12 W0-2: this is
        // now the Meds list root, same as the no-trailing-slash bare host.
        let parsedURL = try url("healthlog://medications/")
        #expect(DeepLinkRoute(url: parsedURL) == .medications)
    }
}
