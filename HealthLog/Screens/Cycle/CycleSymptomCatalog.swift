import Foundation

/// Server seed catalogue order and grouping. Keys are wire values; labels are
/// localized only at the rendering boundary.
enum CycleSymptomCatalog {
    struct Item: Identifiable, Equatable {
        let key: String
        let labelKey: String
        var id: String {
            key
        }
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let titleKey: String
        let items: [Item]
    }

    static let seedSections: [Section] = [
        Section(
            id: "physical",
            titleKey: "cycle.capture.symptoms.category.physical",
            items: [
                Item(key: "cramps", labelKey: "cycle.symptom.cramps"),
                Item(key: "headache", labelKey: "cycle.symptom.headache"),
                Item(key: "bloating", labelKey: "cycle.symptom.bloating"),
                Item(key: "acne", labelKey: "cycle.symptom.acne"),
                Item(key: "breast_tenderness", labelKey: "cycle.symptom.breast_tenderness"),
                Item(key: "fatigue", labelKey: "cycle.symptom.fatigue"),
                Item(key: "back_pain", labelKey: "cycle.symptom.back_pain"),
                Item(key: "insomnia", labelKey: "cycle.symptom.insomnia")
            ]
        ),
        Section(
            id: "emotional",
            titleKey: "cycle.capture.symptoms.category.emotional",
            items: [
                Item(key: "libido_high", labelKey: "cycle.symptom.libido_high"),
                Item(key: "libido_low", labelKey: "cycle.symptom.libido_low"),
                Item(key: "mood_swings", labelKey: "cycle.symptom.mood_swings")
            ]
        ),
        Section(
            id: "digestive",
            titleKey: "cycle.capture.symptoms.category.digestive",
            items: [
                Item(key: "food_cravings", labelKey: "cycle.symptom.food_cravings"),
                Item(key: "nausea", labelKey: "cycle.symptom.nausea"),
                Item(key: "diarrhea", labelKey: "cycle.symptom.diarrhea"),
                Item(key: "constipation", labelKey: "cycle.symptom.constipation")
            ]
        )
    ]

    static let labelsByKey: [String: String] = Dictionary(
        uniqueKeysWithValues: seedSections.flatMap(\.items).map { ($0.key, $0.labelKey) }
    )
}
