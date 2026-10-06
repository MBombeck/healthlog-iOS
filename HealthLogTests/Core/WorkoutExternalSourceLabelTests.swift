import Foundation
@testable import HealthLog
import Testing

/// #115 R3 — server v1.39.6 stores workouts posted through the narrow
/// `workouts:write` token with `source: "EXTERNAL"`, and they reach
/// `GET /api/workouts/{id}`. The detail screen's source row used to fall
/// through to `raw.capitalized` and print "External" untranslated (and any
/// other unknown token as e.g. "Some_new_source"). Every source surface now
/// reads one table: `EXTERNAL` is "External" / "Extern", an unknown token the
/// neutral "Unknown source" / "Unbekannte Quelle".
@Suite("R3 — EXTERNAL and unknown sources read as words, not wire tokens")
@MainActor
struct WorkoutExternalSourceLabelTests {
    @Test("Workout detail: EXTERNAL is the localized 'External'")
    func workoutExternal() {
        #expect(WorkoutDetailView.sourceLabel("EXTERNAL") == String(localized: "measurement.source.external"))
    }

    @Test("Workout detail: an unknown token is neutral, never the capitalised raw value")
    func workoutUnknownIsNeutral() {
        let label = WorkoutDetailView.sourceLabel("SOME_NEW_SOURCE")
        #expect(label == String(localized: "measurement.source.unknown"))
        #expect(label != "Some_New_Source" && label != "Some_new_source")
    }

    @Test("Shared table: EXTERNAL, GOOGLE_HEALTH and unknown match the measurement row labels")
    func sharedTable() {
        #expect(SourcePriorityRow.displayLabel(forSource: "EXTERNAL") == String(localized: "measurement.source.external"))
        #expect(SourcePriorityRow.displayLabel(forSource: "external") == String(localized: "measurement.source.external"))
        #expect(SourcePriorityRow.displayLabel(forSource: "GOOGLE_HEALTH") == "Google Health")
        #expect(SourcePriorityRow.displayLabel(forSource: "GARMIN_FUTURE") == String(localized: "measurement.source.unknown"))
        // Brands stay byte-identical between the two surfaces.
        for brand in ["APPLE_HEALTH", "WITHINGS", "WHOOP", "FITBIT", "GOOGLE_HEALTH", "STRAVA", "OURA", "POLAR", "NIGHTSCOUT"] {
            #expect(WorkoutDetailView.sourceLabel(brand) == SourcePriorityRow.displayLabel(forSource: brand))
        }
    }

    @Test("Rhythm-event card: an EXTERNAL source is attributed as 'External', not dropped or raw")
    func rhythmCardExternal() {
        #expect(InsightsRhythmEventsCard.sourceLabel(for: "EXTERNAL", deviceType: nil)
            == String(localized: "measurement.source.external"))
    }

    @Test("Catalog carries both languages: External / Extern, Unknown source / Unbekannte Quelle")
    func catalogBothLanguages() throws {
        let expected: [String: [String: String]] = [
            "en": ["measurement.source.external": "External", "measurement.source.unknown": "Unknown source"],
            "de": ["measurement.source.external": "Extern", "measurement.source.unknown": "Unbekannte Quelle"]
        ]
        for (language, values) in expected {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for (key, value) in values {
                #expect(bundle.localizedString(forKey: key, value: "MISSING", table: nil) == value, "\(language) \(key)")
            }
        }
    }
}
