import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

/// Build 274 (public #2) — build 273 did not launch on iOS 18: dyld aborted with
/// "Symbol not found: _HKMedicationGeneralFormCapsule". The typed constants of
/// `HKMedicationGeneralForm` are plain `extern NSString *const` globals with NO
/// availability annotation in the iOS 26.5 SDK, so a `switch` over them is a
/// STRONG link that `@available(iOS 26.0, *)` on the function does not weaken.
/// The mapping now runs on the raw string; this suite pins (a) the mapping on
/// any OS and (b) the raw strings against the live SDK on the iOS 26 simulator.
/// The binary-level guard is `scripts/verify-no-strong-ios26-symbols.sh`.
@Suite("Apple Health medication form — mapped by raw string, never by symbol")
struct AppleHealthMedicationFormLinkageTests {
    @Test("raw forms map onto the server deliveryForm enum")
    func rawFormsMap() {
        #expect(AppleHealthMedicationReader.deliveryForm(fromRawForm: "injection") == "INJECTION")
        for oral in ["tablet", "capsule", "liquid", "drops", "powder"] {
            #expect(AppleHealthMedicationReader.deliveryForm(fromRawForm: oral) == "ORAL", "\(oral)")
        }
        #expect(AppleHealthMedicationReader.deliveryForm(fromRawForm: "unknown") == nil)
        #expect(AppleHealthMedicationReader.deliveryForm(fromRawForm: "patch") == "OTHER")
        #expect(AppleHealthMedicationReader.deliveryForm(fromRawForm: "") == "OTHER")
    }

    #if canImport(HealthKit)
        /// Build 274 (public #2) — the test bundle MAY reference the typed
        /// constants: it only ever runs on an iOS 26 simulator. The app binary
        /// may not.
        @Test("the raw strings are the SDK's own")
        func rawStringsMatchTheSDK() {
            guard #available(iOS 26.0, *) else { return }
            #expect(HKMedicationGeneralForm.injection.rawValue == "injection")
            #expect(HKMedicationGeneralForm.tablet.rawValue == "tablet")
            #expect(HKMedicationGeneralForm.capsule.rawValue == "capsule")
            #expect(HKMedicationGeneralForm.liquid.rawValue == "liquid")
            #expect(HKMedicationGeneralForm.drops.rawValue == "drops")
            #expect(HKMedicationGeneralForm.powder.rawValue == "powder")
            #expect(HKMedicationGeneralForm.unknown.rawValue == "unknown")
        }
    #endif
}
