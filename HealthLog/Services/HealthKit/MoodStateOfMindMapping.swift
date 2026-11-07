import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// **v0.10.0 W-Mood-B** — pure mapping between HealthLog mood (`score 1…5` +
/// free-text `tags`) and `HKStateOfMind` (`valence -1…1` + closed-enum
/// `Label`/`Association`).
///
/// Lossiness is documented (R-Mood-3 §2e): score↔valence is exact for our own
/// writes (anchored values) and bucketed for foreign samples; `note` has no HK
/// home (HealthLog-only); free-text tags map best-effort one-way into the
/// closed `Label`/`Association` enums via a small German+English keyword table
/// (unmatched tags are simply dropped from the HK sample — they still live in
/// HealthLog). Never round-trip labels back into our free-text tags on import.
///
/// Foundation-pure so it unit-tests without a live `HKHealthStore`; the
/// HealthKit-typed surfaces are `iOS 18+`-gated.
enum MoodStateOfMindMapping {
    /// score 1…5 → valence anchor (-1.0 … +1.0). Evenly spaced; let
    /// `valenceClassification` derive from this — never set it manually.
    static func valence(forScore score: Int) -> Double {
        switch max(1, min(5, score)) {
        case 1: -1.0
        case 2: -0.5
        case 3: 0.0
        case 4: 0.5
        default: 1.0
        }
    }

    /// valence (-1…1, continuous) → score 1…5 (bucketed). Cutpoints at
    /// ±0.25 / ±0.75. Round-trip is stable for our own writes (anchors land
    /// back on the same bucket); foreign slider precision is lost (acceptable —
    /// our UI is 5-level).
    static func score(forValence valence: Double) -> Int {
        switch valence {
        case ..<(-0.75): 1
        case ..<(-0.25): 2
        case ..<0.25: 3
        case ..<0.75: 4
        default: 5
        }
    }

    #if canImport(HealthKit)
        /// Best-effort one-way map: free-text tags → `HKStateOfMind.Label`.
        /// Unmatched tags are dropped. Deduped + order-stable.
        @available(iOS 18.0, *)
        static func labels(forTags tags: [String]) -> [HKStateOfMind.Label] {
            var seen = Set<HKStateOfMind.Label>()
            var out: [HKStateOfMind.Label] = []
            for tag in tags {
                if let label = labelTable[normalize(tag)], seen.insert(label).inserted {
                    out.append(label)
                }
            }
            return out
        }

        /// Best-effort one-way map: free-text tags → `HKStateOfMind.Association`.
        @available(iOS 18.0, *)
        static func associations(forTags tags: [String]) -> [HKStateOfMind.Association] {
            var seen = Set<HKStateOfMind.Association>()
            var out: [HKStateOfMind.Association] = []
            for tag in tags {
                if let assoc = associationTable[normalize(tag)], seen.insert(assoc).inserted {
                    out.append(assoc)
                }
            }
            return out
        }

        /// Small German, English and Dutch keyword → emotion `Label` table.
        /// Keys are lower-cased; matching is exact on the normalized tag. A
        /// word two languages share ("stress", "familie") is listed once: a
        /// dictionary literal with a duplicate key traps at runtime.
        @available(iOS 18.0, *)
        private static var labelTable: [String: HKStateOfMind.Label] {
            [
                "angst": .anxious, "ängstlich": .anxious, "anxious": .anxious, "angstig": .anxious, "bang": .anxious,
                "gestresst": .stressed, "stress": .stressed, "stressed": .stressed, "gestrest": .stressed,
                "dankbar": .grateful, "grateful": .grateful, "dankbaar": .grateful,
                "glücklich": .happy, "happy": .happy, "blij": .happy, "gelukkig": .happy,
                "traurig": .sad, "sad": .sad, "verdrietig": .sad, "somber": .sad,
                "ruhig": .calm, "calm": .calm, "rustig": .calm, "kalm": .calm,
                "müde": .drained, "tired": .drained, "erschöpft": .drained, "moe": .drained, "uitgeput": .drained,
                "wütend": .angry, "angry": .angry, "boos": .angry,
                "froh": .joyful, "joyful": .joyful, "vrolijk": .joyful,
                "einsam": .lonely, "lonely": .lonely, "eenzaam": .lonely,
                "überfordert": .overwhelmed, "overwhelmed": .overwhelmed, "overweldigd": .overwhelmed,
                "zufrieden": .content, "content": .content, "tevreden": .content,
                "hoffnungsvoll": .hopeful, "hopeful": .hopeful, "hoopvol": .hopeful
            ]
        }

        /// Small German, English and Dutch keyword → context `Association` table.
        @available(iOS 18.0, *)
        private static var associationTable: [String: HKStateOfMind.Association] {
            [
                "arbeit": .work, "work": .work, "job": .work, "werk": .work,
                "familie": .family, "family": .family, "gezin": .family,
                "freunde": .friends, "friends": .friends, "vrienden": .friends,
                "gesundheit": .health, "health": .health, "gezondheid": .health,
                "fitness": .fitness, "sport": .fitness, "sporten": .fitness,
                "geld": .money, "money": .money, "finanzen": .money, "financiën": .money,
                "schlaf": .selfCare, "sleep": .selfCare, "selbstfürsorge": .selfCare, "slaap": .selfCare, "zelfzorg": .selfCare,
                "hobby": .hobbies, "hobbies": .hobbies, "hobby's": .hobbies,
                "partner": .partner, "beziehung": .partner, "relatie": .partner,
                "reise": .travel, "travel": .travel, "urlaub": .travel, "reizen": .travel, "vakantie": .travel,
                "wetter": .weather, "weather": .weather, "weer": .weather,
                "lernen": .education, "education": .education, "schule": .education,
                "leren": .education, "studie": .education, "school": .education
            ]
        }
    #endif

    /// Lower-case + trim a free-text tag for table lookup.
    private static func normalize(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
