import Foundation
import ModelsR4

/// audit-v0162 — the ModelsR4-typed FHIR helpers live in this extension so the
/// `@Observable ExportStore` declaration file need not `import ModelsR4`: that
/// module exports an `Observation` type which shadows the `Observation`
/// framework the `@Observable` macro expands against (build error
/// "'Observable' is not a member type of class 'ModelsR4.Observation'").
extension ExportStore {
    /// Emit the local FHIR bundle JSON for the report period + additive clinical
    /// blocks. `nil` if the local emitter or encode throws. `nonisolated static`
    /// so it is a pure function, unit-testable from a `@MainActor` test without a
    /// store instance. `@MainActor` because `DoctorReportSpecBuilder.build` is
    /// main-actor-isolated.
    @MainActor static func makeLocalBundleJSON(
        periodDays: Int,
        snapshot: DoctorReportSpecBuilder.Snapshot,
        generatedAt end: Date,
        labs: DoctorReportSpec.LabsBlock?,
        illnesses: DoctorReportSpec.IllnessBlock?
    ) -> Data? {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -periodDays, to: end) ?? end
        let base = DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: start,
            periodEnd: end,
            generatedAt: end,
            selection: .all,
            locale: .de,
            calendar: calendar
        )
        // Re-init the spec with the additive clinical blocks — the builder owns
        // the PDF sections; labs/illness are FHIR-only additions.
        let spec = DoctorReportSpec(
            cover: base.cover,
            vitals: base.vitals,
            charts: base.charts,
            medications: base.medications,
            adherence: base.adherence,
            mood: base.mood,
            labs: labs,
            illnesses: illnesses,
            footer: base.footer
        )
        guard let bundle = try? DoctorReportToFHIRBundle.bundle(from: spec) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(bundle)
    }

    /// Encode + write a FHIR `Bundle` to the temp dir under complete file
    /// protection. `internal` (not `private`) so the PHI-protection regression
    /// test can exercise the real write path through `@testable import`.
    static func writeBundle(_ bundle: ModelsR4.Bundle, generatedAt: Date) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        return try writeData(data, generatedAt: generatedAt)
    }
}
