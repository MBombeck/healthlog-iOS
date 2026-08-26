import Foundation
@testable import HealthLog
import Testing

/// v0.14.2 (#136) — picker kind-list logic: which kinds are shown, how they
/// group, how they order.
@Suite("MeasurementsPickerModel")
struct MeasurementsPickerModelTests {
    @Test("Empty data set yields no sections (→ empty state)")
    func emptyYieldsNoSections() {
        #expect(MeasurementsPickerModel.sections(kindsWithData: []).isEmpty)
        #expect(MeasurementsPickerModel.orderedKinds(kindsWithData: []).isEmpty)
    }

    @Test("Only kinds with data are listed")
    func onlyAvailableKindsListed() {
        let available: Set<MetricKind> = [.weight, .pulse]
        let listed = Set(MeasurementsPickerModel.orderedKinds(kindsWithData: available))
        #expect(listed == available)
    }

    @Test("Flat/primary kinds fold into a leading headerless Core section")
    func flatKindsInCoreSection() {
        // Parity Build 4 — the flat/pinned set shrank to the web five, so `pulse`
        // is no longer core (it moved into the `heart` group).
        let sections = MeasurementsPickerModel.sections(
            kindsWithData: [.weight, .bloodPressure, .sleep]
        )
        let core = sections.first
        #expect(core?.id == "core")
        #expect(core?.category == nil)
        #expect(Set(core?.kinds ?? []) == [.weight, .bloodPressure, .sleep])
    }

    @Test("Grouped kinds land in their Insights category section")
    func groupedKindsInCategorySection() {
        // Parity Build 4 — hrv → heart (was vitals), muscleMass → body.
        let sections = MeasurementsPickerModel.sections(
            kindsWithData: [.hrv, .muscleMass]
        )
        let ids = sections.map(\.id)
        #expect(ids.contains(InsightsMetricCategory.heart.rawValue))
        #expect(ids.contains(InsightsMetricCategory.body.rawValue))
        // No empty core section when every available kind is grouped.
        #expect(!ids.contains("core"))
    }

    @Test("Core section sorts first, then categories in InsightsMetricCategory order")
    func sectionOrdering() {
        let sections = MeasurementsPickerModel.sections(
            kindsWithData: [.muscleMass, .spo2, .weight]
        )
        #expect(sections.first?.id == "core")
        let categoryIDs = sections.dropFirst().compactMap(\.category)
        // vitals precedes body in InsightsMetricCategory.allCases.
        let vitalsIdx = categoryIDs.firstIndex(of: .vitals)
        let bodyIdx = categoryIDs.firstIndex(of: .body)
        #expect(vitalsIdx != nil)
        #expect(bodyIdx != nil)
        if let v = vitalsIdx, let b = bodyIdx { #expect(v < b) }
    }

    @Test("Within a section kinds follow canonical MetricKind.allCases order")
    func withinSectionOrdering() {
        // Use allCases order over the pinned/core kinds.
        let order = MetricKind.allCases
        let sample: Set<MetricKind> = [.sleep, .weight, .bloodPressure]
        let kinds = MeasurementsPickerModel.sections(kindsWithData: sample)
            .first(where: { $0.id == "core" })?.kinds ?? []
        let indices = kinds.compactMap { order.firstIndex(of: $0) }
        #expect(indices == indices.sorted())
    }

    @Test("Empty categories are dropped (no dead section)")
    func emptyCategoriesDropped() {
        let sections = MeasurementsPickerModel.sections(kindsWithData: [.weight])
        // Only the core section — no category sections for absent kinds.
        #expect(sections.count == 1)
        #expect(sections.first?.id == "core")
    }
}
