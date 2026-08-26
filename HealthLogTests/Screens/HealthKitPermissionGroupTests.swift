import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// CAT-1: HK-Permission-Picker-Gruppierung über die Server-Categorisation-
/// Overlay. Die Tests pinnen:
///
///   - Jede Default-Row trägt eine gültige `categoryId`, die zu einem
///     `CategoryAssignmentMap`-Bucket gehört (Drift-Sentinel — wenn der
///     Server eine Kategorie umbenennt, schreit hier ein Test).
///   - `ordered(by:)` reordert die Rows so, dass alle Buckets nach
///     `Category.order` geschlossen erscheinen.
///   - Innerhalb desselben Buckets bleibt die UX-Default-Reihenfolge
///     erhalten (stable sort).
///   - Unbekannte Bucket-Ids werden hinten angefügt (defensive Default).
@Suite("HealthKitPermissionGroup — Category-driven ordering (CAT-1)")
struct HealthKitPermissionGroupTests {
    @Test("Every onboarding default row carries a valid categoryId from the bundled fallback")
    func everyDefaultRowHasKnownCategoryId() {
        let known = Set(CategoryAssignmentMap.bundledFallback.categories.map(\.id))
        for group in HealthKitPermissionGroup.onboardingDefaults {
            #expect(known.contains(group.categoryId), "Row \(group.id) carries unknown categoryId \(group.categoryId)")
        }
    }

    @Test("ordered(by:) groups rows by category order")
    func orderedByGroupsByCategoryOrder() {
        let map = CategoryAssignmentMap.bundledFallback
        let ordered = HealthKitPermissionGroup.ordered(by: map)
        // Translate every row into the index of its category bucket in
        // the server's `orderedCategories`. The resulting sequence must
        // be non-decreasing — same bucket grouped together.
        let categoryIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: map.orderedCategories.enumerated().map { ($1.id, $0) }
        )
        let indices = ordered.map { categoryIndex[$0.categoryId] ?? Int.max }
        let isMonotonic = zip(indices, indices.dropFirst()).allSatisfy { $0 <= $1 }
        #expect(isMonotonic, "Bucket ordering must be monotonic non-decreasing; got \(indices)")
    }

    @Test("ordered(by:) preserves the input order within a single bucket")
    func orderStableWithinBucket() {
        let map = CategoryAssignmentMap.bundledFallback
        let inputVitals = HealthKitPermissionGroup.onboardingDefaults
            .filter { $0.categoryId == "vitals" }
            .map(\.id)
        let orderedVitals = HealthKitPermissionGroup.ordered(by: map)
            .filter { $0.categoryId == "vitals" }
            .map(\.id)
        #expect(orderedVitals == inputVitals, "Within `vitals`, the UX-tuned default order must survive")
    }

    @Test("Unknown bucket-ids fall to the end of the ordering")
    func unknownBucketsLandAtEnd() {
        // Build a map that only knows `vitals` — every other bucket
        // becomes "unknown" from the map's POV.
        let restrictedMap = CategoryAssignmentMap(
            version: 1,
            categories: [.init(id: "vitals", labelKey: "categories.vitals", order: 0)],
            assignments: [:]
        )
        let ordered = HealthKitPermissionGroup.ordered(by: restrictedMap)
        // Find where `vitals` rows end — everything after must be a
        // non-vitals row.
        let lastVitalsIndex = ordered.lastIndex(where: { $0.categoryId == "vitals" })
        let firstUnknownIndex = ordered.firstIndex(where: { $0.categoryId != "vitals" })
        if let lastVitalsIndex, let firstUnknownIndex {
            #expect(lastVitalsIndex < firstUnknownIndex, "Vitals must precede every unknown bucket")
        }
    }

    @Test("All ten onboarding rows survive a re-order (no drop / no dup)")
    func reorderPreservesEveryRow() {
        let ordered = HealthKitPermissionGroup.ordered(by: .bundledFallback)
        let inputIds = Set(HealthKitPermissionGroup.onboardingDefaults.map(\.id))
        let outputIds = Set(ordered.map(\.id))
        #expect(inputIds == outputIds)
        #expect(ordered.count == HealthKitPermissionGroup.onboardingDefaults.count)
    }

    @Test("First bucket in bundled fallback is `vitals`, last visible is `metabolic`")
    func bundledFallbackOrderIsCanonical() {
        let ordered = HealthKitPermissionGroup.ordered(by: .bundledFallback).map(\.categoryId)
        let firstBucket = ordered.first
        let lastBucket = ordered.last
        #expect(firstBucket == "vitals")
        // Last permission row's categoryId is whatever sits at the end —
        // currently `metabolic` (Blutzucker is in metabolic). If the
        // server reshuffles, this test surfaces the change explicitly.
        #expect(lastBucket == "metabolic")
    }
}
