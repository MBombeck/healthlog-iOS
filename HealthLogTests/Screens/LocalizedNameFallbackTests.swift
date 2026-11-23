import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Names that used to reach the screen raw: the ball sports of the server's
/// sport enum, and HealthKit identifiers in the list of refused readings.
@Suite("Localized names instead of raw sport tokens and HealthKit identifiers")
struct LocalizedNameFallbackTests {
    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("Every sport token of the server enum resolves through the catalogue")
    func serverSportTokensHaveTitles() {
        // `workoutSportTypeEnum` in the server's `src/lib/validations/workout.ts`.
        let tokens = [
            "walking", "running", "cycling", "hiking", "swimming", "rowing", "elliptical",
            "stairClimber", "yoga", "mindAndBody", "strength", "hiit", "dance", "golf",
            "badminton", "tennis", "basketball", "soccer", "crossTraining", "mixedCardio"
        ]
        for token in tokens {
            let title = WorkoutFormatter.sportTitle(token)
            #expect(!title.isEmpty, "\(token)")
            #expect(title != String(localized: "Workout"), "\(token) falls back to the generic title")
        }
        #expect(WorkoutFormatter.sportTitle("soccer") == String(localized: "Soccer"))
        #expect(WorkoutFormatter.sportTitle("basketball") == String(localized: "Basketball"))
    }

    @Test(
        "Ball sports carry the server's names in each language",
        arguments: [
            ("de", ["Golf", "Tennis", "Basketball", "Fußball"]),
            ("en", ["Golf", "Tennis", "Basketball", "Soccer"]),
            ("nl", ["Golf", "Tennis", "Basketbal", "Voetbal"])
        ]
    )
    func ballSportNames(language: String, names: [String]) throws {
        let bundle = try bundle(language)
        for (key, expected) in zip(["Golf", "Tennis", "Basketball", "Soccer"], names) {
            #expect(bundle.localizedString(forKey: key, value: "MISSING", table: nil) == expected, "\(language) \(key)")
        }
    }

    @Test("A refused reading of a type the diagnostics table does not name shows the permission name")
    func refusedRowUsesPermissionName() {
        let identifier = "HKCategoryTypeIdentifierSleepApneaEvent"
        #expect(SettingsHKSkippedRowsScreen.kindTitle(identifier) == HealthAccessTypeNaming.displayName(for: identifier))
        #expect(SettingsHKSkippedRowsScreen.kindTitle(identifier) != "SleepApneaEvent")
        #expect(SettingsHKSkippedRowsScreen.kindTitle("HKWorkoutTypeIdentifier") == String(localized: "health.permissions.type.workouts"))
    }
}
