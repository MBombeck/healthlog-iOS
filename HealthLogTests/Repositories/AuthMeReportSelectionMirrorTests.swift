import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **CU-01** — the read-only `reportSelection` mirror on `GET /api/auth/me`
/// (server v1.32.39).
///
/// The `/me` payload is consumed by five narrow, purpose-built projections
/// (`AuthMeServerPrefs`, `AuthMeModules`, `AuthMeDisclaimer`,
/// `AuthMeOnboarding`, `AuthMeMfaEnrollment`), each of which decodes only its
/// own keys — so a new top-level key is structurally tolerated. This suite
/// proves that (the "does the existing model take it?" question CU-01 had to
/// answer) **and** pins the one place that now actually reads it, so the mirror
/// rides a round-trip the settings hydration already makes instead of costing a
/// second GET.
///
/// Writes never go through here: `PUT /api/auth/me/report-selection` via
/// ``ReportSelectionRepository`` is the only write path.
@Suite("GET /api/auth/me — reportSelection mirror", .serialized)
struct AuthMeReportSelectionMirrorTests {
    private func makeRepo() -> SettingsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return SettingsRepository(
            api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        )
    }

    private func respond(_ json: String) {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
    }

    @Test("a saved profile on /me decodes into the projection")
    func mirrorDecodes() async throws {
        respond(#"""
        {"data":{"id":"u1","username":"anna","unitPreference":"metric",
        "reportSelection":{"v":2,"leaves":["PATIENT_IDENTITY","WEIGHT"],
        "format":"fhir","rangeDays":180,"includeCharts":false}},"error":null}
        """#)
        let prefs = try await makeRepo().authMeServerPrefs()
        let mirrored = try #require(prefs.reportSelection)
        #expect(mirrored.selection.leaves == ["PATIENT_IDENTITY", "WEIGHT"])
        #expect(mirrored.format == .fhir)
        #expect(mirrored.rangeDays == 180)
        #expect(mirrored.includeCharts == false)
        // The neighbouring prefs still decode — the new key is additive.
        #expect(prefs.unitPreference == "metric")
    }

    @Test("an explicit null means 'never saved' — not an empty selection")
    func explicitNullIsNil() async throws {
        respond(#"""
        {"data":{"id":"u1","unitPreference":"metric","reportSelection":null},"error":null}
        """#)
        #expect(try await makeRepo().authMeServerPrefs().reportSelection == nil)
    }

    @Test("an older server that omits the key decodes unchanged")
    func absentKeyIsTolerated() async throws {
        respond(#"{"data":{"id":"u1","unitPreference":"imperial"},"error":null}"#)
        let prefs = try await makeRepo().authMeServerPrefs()
        #expect(prefs.reportSelection == nil)
        #expect(prefs.unitPreference == "imperial")
    }

    @Test("a blob this build cannot read fails soft — it must not take down the profile load")
    func unreadableBlobFailsSoft() async throws {
        // A drifted / future selection shape. The mirror resolves to nil; the
        // rest of the projection is untouched. The authoritative read is
        // `GET /api/auth/me/report-selection`, which answers `profile: null`
        // for exactly the same reason.
        respond(#"""
        {"data":{"id":"u1","unitPreference":"metric","cycleTrackingEnabled":true,
        "reportSelection":{"v":2,"leaves":"not-an-array"}},"error":null}
        """#)
        let prefs = try await makeRepo().authMeServerPrefs()
        #expect(prefs.reportSelection == nil)
        #expect(prefs.unitPreference == "metric")
        #expect(prefs.cycleTrackingEnabled == true)
    }

    @Test("the other /me projections ignore the new key entirely")
    func otherProjectionsUnaffected() async throws {
        respond(#"""
        {"data":{"id":"u1","modules":{"cycle":false},
        "reportSelection":{"v":2,"leaves":["MOOD"],"format":"pdf",
        "rangeDays":30,"includeCharts":true}},"error":null}
        """#)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        let modules = try #require(try await ModuleGateRepository(api: api).fetchModules())
        #expect(modules["cycle"] == false)
    }
}

// swiftlint:enable force_unwrapping
