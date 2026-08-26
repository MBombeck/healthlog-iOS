import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Truth-table tests for the pure `CycleGateResolver` (HealthLogCore).
/// The app-side `@Observable CycleGate` (which layers the feature flag +
/// SettingsStore on top) is tested separately in the app test target.
@Suite("CycleGateResolver truth table")
struct CycleGateResolverTests {
    @Test("Female profile gender → available")
    func femaleProfile() {
        #expect(CycleGateResolver.isAvailable(.init(profileGender: "female")))
    }

    @Test("Female profile gender is case-insensitive")
    func femaleProfileCaseInsensitive() {
        #expect(CycleGateResolver.isAvailable(.init(profileGender: "Female")))
        #expect(CycleGateResolver.isAvailable(.init(profileGender: "FEMALE")))
    }

    @Test("Male profile gender → not available")
    func maleProfile() {
        #expect(!CycleGateResolver.isAvailable(.init(profileGender: "male")))
    }

    @Test("Nil profile gender, no signals → not available")
    func nilProfileNoSignals() {
        #expect(!CycleGateResolver.isAvailable(.init(profileGender: nil)))
    }

    @Test("Other gender without opt-in → not available")
    func otherWithoutOptIn() {
        #expect(!CycleGateResolver.isAvailable(.init(profileGender: "other")))
    }

    @Test("Other gender WITH explicit opt-in → available")
    func otherWithOptIn() {
        #expect(CycleGateResolver.isAvailable(.init(
            profileGender: "other", explicitOptIn: true
        )))
    }

    @Test("Explicit opt-in overrides a male profile gender (trans/non-binary)")
    func optInOverridesMale() {
        #expect(CycleGateResolver.isAvailable(.init(
            profileGender: "male", explicitOptIn: true
        )))
    }

    @Test("HK biologicalSex == female (granted) → available as fallback")
    func hkFemaleFallback() {
        #expect(CycleGateResolver.isAvailable(.init(
            profileGender: nil, biologicalSex: .female
        )))
    }

    @Test("HK fallback only when granted — .unknown never enables")
    func hkUnknownDoesNotEnable() {
        #expect(!CycleGateResolver.isAvailable(.init(
            profileGender: nil, biologicalSex: .unknown
        )))
    }

    @Test("HK biologicalSex == male never enables (no false positive for men)")
    func hkMaleNeverEnables() {
        #expect(!CycleGateResolver.isAvailable(.init(
            profileGender: nil, biologicalSex: .male
        )))
    }

    @Test("HK biologicalSex == .notSet / .other does not enable")
    func hkNotSetOrOther() {
        #expect(!CycleGateResolver.isAvailable(.init(profileGender: nil, biologicalSex: .notSet)))
        #expect(!CycleGateResolver.isAvailable(.init(profileGender: nil, biologicalSex: .other)))
    }

    @Test("Male profile + HK female does not flip (profile male loses to HK female fallback)")
    func maleProfileButHKFemale() {
        // Profile says male, but a granted HK characteristic says female.
        // Per the resolution order the HK fallback still enables — this is the
        // intended behaviour (a granted female characteristic is a strong
        // signal; the profile may simply be unset/wrong). Documented here so a
        // future reconcile is a conscious decision, not an accident.
        #expect(CycleGateResolver.isAvailable(.init(
            profileGender: "male", biologicalSex: .female
        )))
    }

    // MARK: - CU-17 / GH #71 — the third gender value is decided, not dropped

    /// The server's canonical spelling is uppercase (`profileSchema` in
    /// `src/lib/validations/auth.ts`, verified 2026-07-30). The gate must read
    /// it as such — previously only the lowercase form was ever exercised.
    @Test(
        "Uppercase server spelling resolves identically",
        arguments: [("FEMALE", true), ("MALE", false), ("OTHER", false)]
    )
    func uppercaseServerSpelling(raw: String, expected: Bool) {
        #expect(CycleGateResolver.genderEnablesCycle(raw) == expected)
        #expect(CycleGateResolver.isAvailable(.init(profileGender: raw)) == expected)
    }

    /// `OTHER` is an explicit `false` from the gender signal — not a value that
    /// falls through a `== "female"` comparison. The distinction matters
    /// because #71's server-side twin was exactly this: a third value silently
    /// landing in the binary else-branch.
    @Test("OTHER is decided explicitly by genderEnablesCycle, not fallen through")
    func otherIsDecidedExplicitly() {
        #expect(CycleGateResolver.genderEnablesCycle("OTHER") == false)
        #expect(CycleGateResolver.genderEnablesCycle("other") == false)
        // …and the opt-in remains the documented route back in.
        #expect(CycleGateResolver.isAvailable(.init(profileGender: "OTHER", explicitOptIn: true)))
        // …as does an already-granted HealthKit characteristic.
        #expect(CycleGateResolver.isAvailable(.init(profileGender: "OTHER", biologicalSex: .female)))
    }

    /// Absence is not evidence: an unrecorded or unrecognised gender must not
    /// be read as either pole. It resolves the same way `OTHER` does.
    @Test(
        "Absent / unrecognised gender resolves like OTHER, never like FEMALE",
        arguments: [nil, "", "NON_BINARY", "divers", "space-alien"] as [String?]
    )
    func unknownGenderIsNotAPole(raw: String?) {
        #expect(CycleGateResolver.genderEnablesCycle(raw) == false)
        #expect(CycleGateResolver.genderEnablesCycle(raw) == CycleGateResolver.genderEnablesCycle("OTHER"))
    }
}
