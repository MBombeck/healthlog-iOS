import Foundation
@testable import HealthLog
import Testing

/// Locks the v2 report-selection wire shape (CU-01 / server v1.32.39):
/// `{ "v": 2, "leaves": [String] }`, `leaves` ≤ 91 entries of 1…64 characters,
/// plus the ``SavedReportProfile`` wrapper that
/// `GET|PUT /api/auth/me/report-selection` speaks.
///
/// **Fixture discipline — the point of this file.** The 14 structured section
/// ids below appear here and ONLY here. They are a test fixture standing in for
/// what the server serves live at
/// `GET /api/meta/capabilities` → `share.leaves`; the app must never carry a
/// production copy of the vocabulary. Every vocabulary-aware assertion feeds the
/// fixture in through ``ReportSelection/validate(against:)``, exactly as
/// production code will feed in the capabilities response.
@Suite("ReportSelection — v2 wire contract")
struct ReportSelectionTests {
    /// **Test fixture only.** The 13 structured sections named in the catch-up
    /// brief plus `ANAMNESIS`, which the server catalogue carries today. Stands
    /// in for `capabilities.share.leaves`; never a production constant.
    static let structuredLeafFixture: [String] = [
        "PATIENT_IDENTITY", "INSURANCE", "GLUCOSE_PANEL", "LAB_RESULTS",
        "MEDICATION_LIST", "MEDICATION_ADMINISTRATIONS", "MEDICATION_COMPLIANCE",
        "GLP1_THERAPY", "ALLERGIES", "ILLNESS_EPISODES", "FAMILY_HISTORY",
        "MOOD", "CYCLE", "ANAMNESIS"
    ]

    /// A few `MeasurementType` members, as the server would serve them alongside
    /// the structured sections. Fixture only.
    static let measurementLeafFixture: [String] = [
        "WEIGHT", "BLOOD_PRESSURE_SYSTOLIC", "BLOOD_PRESSURE_DIASTOLIC",
        "HEART_RATE", "BLOOD_GLUCOSE", "ACTIVITY_STEPS"
    ]

    static var vocabularyFixture: Set<String> {
        Set(structuredLeafFixture + measurementLeafFixture)
    }

    // MARK: - Codable

    @Test("decodes the wire shape verbatim")
    func decodesWireShape() throws {
        let json = Data(#"{"v":2,"leaves":["WEIGHT","LAB_RESULTS"]}"#.utf8)
        let selection = try JSONDecoder().decode(ReportSelection.self, from: json)
        #expect(selection.v == 2)
        #expect(selection.leaves == ["WEIGHT", "LAB_RESULTS"])
        #expect(selection.has("WEIGHT"))
        #expect(selection.has("MOOD") == false)
    }

    @Test("encodes v as the constant 2 regardless of how it was built")
    func encodesConstantVersion() throws {
        let data = try JSONEncoder().encode(ReportSelection(leaves: ["MOOD"]))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["v"] as? Int == 2)
        #expect(object["leaves"] as? [String] == ["MOOD"])
        // `.strict()` server schema — exactly two keys, no extras.
        #expect(object.keys.sorted() == ["leaves", "v"])
    }

    @Test("empty leaves is legal and means 'no health data', not 'everything'")
    func emptyIsLegalAndMeansNothing() throws {
        let json = Data(#"{"v":2,"leaves":[]}"#.utf8)
        let selection = try JSONDecoder().decode(ReportSelection.self, from: json)
        #expect(selection.isEmpty)
        #expect(selection.validate(against: Self.vocabularyFixture).isEmpty)
        #expect(selection.has("WEIGHT") == false)
        #expect(ReportSelection.empty == selection)
    }

    @Test("round-trips through encode/decode unchanged")
    func roundTrips() throws {
        let original = ReportSelection(leaves: Self.structuredLeafFixture)
        let decoded = try JSONDecoder().decode(
            ReportSelection.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    // MARK: - Validation

    @Test("a selection drawn from the live vocabulary validates clean")
    func validSelectionHasNoIssues() {
        let selection = ReportSelection(leaves: ["WEIGHT", "MOOD", "ALLERGIES"])
        #expect(selection.validate(against: Self.vocabularyFixture).isEmpty)
        #expect(selection.isValid(against: Self.vocabularyFixture))
    }

    @Test("an id outside the live vocabulary is reported, never silently dropped")
    func unknownLeafIsReported() {
        let selection = ReportSelection(leaves: ["WEIGHT", "NOT_A_LEAF", "ALSO_NOT"])
        let issues = selection.validate(against: Self.vocabularyFixture)
        #expect(issues == [.unknownLeaves(["NOT_A_LEAF", "ALSO_NOT"])])
        // Without a vocabulary the client has NO opinion about which ids exist.
        #expect(selection.validate().isEmpty)
    }

    @Test("more than 91 leaves is refused pre-flight")
    func tooManyLeavesIsRefused() {
        let selection = ReportSelection(leaves: (0 ..< 92).map { "LEAF_\($0)" })
        #expect(selection.validate().contains(.tooManyLeaves(count: 92, max: 91)))
        // Exactly 91 is the boundary and must pass.
        let atLimit = ReportSelection(leaves: (0 ..< 91).map { "LEAF_\($0)" })
        #expect(atLimit.validate().isEmpty)
    }

    @Test("leaf ids must be 1…64 characters")
    func leafLengthBounds() {
        let tooLong = String(repeating: "X", count: 65)
        let issues = ReportSelection(leaves: ["", tooLong]).validate()
        #expect(issues.contains(.leafIdLengthOutOfRange("")))
        #expect(issues.contains(.leafIdLengthOutOfRange(tooLong)))
        // 64 characters exactly is legal.
        #expect(ReportSelection(leaves: [String(repeating: "X", count: 64)]).validate().isEmpty)
    }

    @Test("an unsupported grammar version is recognised, not silently accepted")
    func unsupportedVersionIsRecognised() throws {
        let json = Data(#"{"v":3,"leaves":["WEIGHT"]}"#.utf8)
        let selection = try JSONDecoder().decode(ReportSelection.self, from: json)
        #expect(selection.validate() == [.unsupportedVersion(3)])
    }

    @Test("duplicate ids are named")
    func duplicatesAreNamed() {
        let issues = ReportSelection(leaves: ["WEIGHT", "MOOD", "WEIGHT"]).validate()
        #expect(issues == [.duplicateLeaves(["WEIGHT"])])
    }

    @Test("filtered(to:) mirrors the server's stored-blob policy — drop unknown, keep order")
    func filteredDropsUnknownPreservingOrder() {
        let selection = ReportSelection(leaves: ["MOOD", "GONE_LEAF", "WEIGHT"])
        #expect(selection.filtered(to: Self.vocabularyFixture).leaves == ["MOOD", "WEIGHT"])
    }

    // MARK: - SavedReportProfile

    @Test("SavedReportProfile decodes the report-selection route payload")
    func profileDecodes() throws {
        let json = Data(#"""
        {"v":2,"leaves":["WEIGHT","LAB_RESULTS"],"format":"fhir","rangeDays":90,"includeCharts":true}
        """#.utf8)
        let profile = try JSONDecoder().decode(SavedReportProfile.self, from: json)
        #expect(profile.v == 2)
        #expect(profile.format == .fhir)
        #expect(profile.rangeDays == 90)
        #expect(profile.includeCharts)
        #expect(profile.selection.leaves == ["WEIGHT", "LAB_RESULTS"])
    }

    @Test("SavedReportProfile encodes exactly the five strict-schema keys")
    func profileEncodesStrictBody() throws {
        let profile = SavedReportProfile(
            selection: ReportSelection(leaves: ["MOOD"]),
            format: .package,
            rangeDays: 365,
            includeCharts: false
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        )
        #expect(object.keys.sorted() == ["format", "includeCharts", "leaves", "rangeDays", "v"])
        #expect(object["v"] as? Int == 2)
        #expect(object["format"] as? String == "package")
        #expect(object["rangeDays"] as? Int == 365)
        #expect(object["includeCharts"] as? Bool == false)
    }

    @Test("every wire format literal maps to a case", arguments: ["pdf", "fhir", "package"])
    func formatLiterals(raw: String) {
        #expect(ReportFormat(rawValue: raw) != nil)
    }

    @Test("rangeDays outside 1…365 is refused pre-flight")
    func profileRangeDaysBounds() {
        func profile(_ days: Int) -> SavedReportProfile {
            SavedReportProfile(
                selection: ReportSelection(leaves: []),
                format: .pdf,
                rangeDays: days,
                includeCharts: true
            )
        }
        #expect(profile(0).validate() == [.rangeDaysOutOfRange(0)])
        #expect(profile(366).validate() == [.rangeDaysOutOfRange(366)])
        #expect(profile(1).validate().isEmpty)
        #expect(profile(365).validate().isEmpty)
    }

    @Test("profile validation forwards the selection's own issues")
    func profileForwardsSelectionIssues() {
        let profile = SavedReportProfile(
            selection: ReportSelection(leaves: ["NOT_A_LEAF"]),
            format: .pdf,
            rangeDays: 30,
            includeCharts: true
        )
        #expect(
            profile.validate(against: Self.vocabularyFixture)
                == [.selection(.unknownLeaves(["NOT_A_LEAF"]))]
        )
    }
}
