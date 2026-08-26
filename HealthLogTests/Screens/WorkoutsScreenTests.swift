import Foundation
@testable import HealthLog
import Testing

/// v0.5.3-F3 — Workouts surface contract tests.
///
/// Pins the layout-descriptor strings + the pure `WorkoutFormatter`
/// helpers so a future wave can't silently rename the navigation title or
/// break the sport-type → German label mapping. Snapshot tests of the
/// SwiftUI view are deliberately skipped — the formatter is the actual
/// behaviour worth pinning.
@Suite("WorkoutsScreen — formatter + layout descriptor")
struct WorkoutsScreenTests {
    // MARK: - Layout descriptors

    @Test("Navigation title remains 'Workouts'")
    func navigationTitle() {
        #expect(WorkoutsScreen.Layout.navigationTitle == "Workouts")
    }

    @Test("Empty title + subtitle wording is locked")
    func emptyStateCopy() {
        #expect(WorkoutsScreen.Layout.emptyTitle == "No workouts yet")
        #expect(WorkoutsScreen.Layout.emptySubtitle.contains("Apple Watch"))
        #expect(WorkoutsScreen.Layout.emptySubtitle.contains("Withings"))
    }

    // MARK: - Sport title mapping

    @Test("Sport-type mapping covers the common HK identifiers")
    func sportTitleCoverage() {
        #expect(WorkoutFormatter.sportTitle("HKWorkoutActivityTypeRunning") == "Laufen")
        #expect(WorkoutFormatter.sportTitle("running") == "Laufen")
        #expect(WorkoutFormatter.sportTitle("RUNNING") == "Laufen")
        #expect(WorkoutFormatter.sportTitle("cycling") == "Radfahren")
        #expect(WorkoutFormatter.sportTitle("walking") == "Gehen")
        #expect(WorkoutFormatter.sportTitle("yoga") == "Yoga")
        #expect(WorkoutFormatter.sportTitle("highIntensityIntervalTraining") == "HIIT")
    }

    @Test("Server sport-type enum tokens (our own ingest) render mapped titles")
    func sportTitleServerEnumTokens() {
        // W-WORKOUT-E2E: `WorkoutHealthKitMapping` uploads these exact tokens
        // (server `workoutSportTypeEnum`); the list must not render raw
        // fallbacks like "Hiit" / "Mindandbody" for rows we wrote ourselves.
        #expect(WorkoutFormatter.sportTitle("strength") == "Krafttraining")
        #expect(WorkoutFormatter.sportTitle("hiit") == "HIIT")
        #expect(WorkoutFormatter.sportTitle("mindAndBody") == "Geist & Körper")
        #expect(WorkoutFormatter.sportTitle("stairClimber") == "Treppen")
        #expect(WorkoutFormatter.sportTitle("crossTraining") == "Crosstraining")
        #expect(WorkoutFormatter.sportTitle("dance") == "Tanzen")
    }

    @Test("WHOOP sport labels render readable titles, never the raw token")
    func sportTitleWhoopLabels() {
        // Server WHOOP ingest stores `sport_name` ("Cycling") or the generic
        // `whoop_sport_<id>` token when WHOOP omits the name. The generic
        // token folds to the localized workout title; named sports ride the
        // normal lowercase lookup.
        #expect(WorkoutFormatter.sportTitle("whoop_sport_1") == "Training")
        #expect(WorkoutFormatter.sportTitle("whoop_sport_44") == "Training")
        #expect(WorkoutFormatter.sportTitle("Cycling") == "Radfahren")
        #expect(WorkoutFormatter.sportTitle("Running") == "Laufen")
        // Unmapped WHOOP sport names stay readable via the title-case fallback.
        #expect(WorkoutFormatter.sportTitle("Weightlifting") == "Weightlifting")
        // Generic token still gets the generic activity icon, not a blank.
        #expect(WorkoutFormatter.sportSymbol("whoop_sport_1") == "figure.mixed.cardio")
    }

    @Test("Unknown sport falls back to capitalised raw identifier")
    func sportTitleFallback() {
        // Surface chosen so a future server addition (e.g. "kayaking") still
        // renders something readable rather than the literal enum value.
        #expect(WorkoutFormatter.sportTitle("kayaking") == "Kayaking")
        #expect(WorkoutFormatter.sportTitle(nil) == "Training")
        #expect(WorkoutFormatter.sportTitle("") == "Training")
    }

    // MARK: - Duration formatter

    @Test("Duration formatter renders minutes:seconds and hours:minutes:seconds")
    func durationFormat() {
        #expect(WorkoutFormatter.duration(0) == nil)
        #expect(WorkoutFormatter.duration(nil) == nil)
        #expect(WorkoutFormatter.duration(125) == "2:05")
        #expect(WorkoutFormatter.duration(7322) == "2:02:02")
    }

    // MARK: - Distance formatter

    @Test("Distance under 1km renders as metres, above as km with one decimal")
    func distanceFormat() {
        // Pin a POSIX locale so the assertion is deterministic regardless of the
        // sim's locale — production uses `.current`, so a de-DE device correctly
        // renders "1,5 km" (locale-aware separator, L10N-5).
        let posix = Locale(identifier: "en_US_POSIX")
        #expect(WorkoutFormatter.distanceLabel(metres: 820, locale: posix) == "820 m")
        #expect(WorkoutFormatter.distanceLabel(metres: 1500, locale: posix) == "1.5 km")
        #expect(WorkoutFormatter.distanceLabel(metres: 12345, locale: posix) == "12.3 km")
    }

    // MARK: - Subtitle composition

    @Test("Subtitle stitches available fields with separator, skipping nil + zero")
    func subtitleComposition() {
        let date = Date(timeIntervalSince1970: 1_716_000_000) // 2024-05-18
        let entry = WorkoutListEntryDTO(
            id: "w1",
            sportType: "running",
            startedAt: date,
            endedAt: nil,
            durationSec: 1800,
            distanceM: 5000,
            activeEnergyKcal: 350,
            avgHr: nil,
            maxHr: nil,
            source: "APPLE_HEALTH",
            externalId: nil
        )
        let subtitle = WorkoutFormatter.subtitle(entry, locale: Locale(identifier: "en_US_POSIX"))
        #expect(subtitle.contains("5.0 km"))
        #expect(subtitle.contains("350 kcal"))
    }

    @Test("Subtitle omits empty segments cleanly")
    func subtitleHandlesNilFields() {
        let entry = WorkoutListEntryDTO(
            id: "w2",
            sportType: "yoga",
            startedAt: nil,
            endedAt: nil,
            durationSec: nil,
            distanceM: nil,
            activeEnergyKcal: 0,
            avgHr: nil,
            maxHr: nil,
            source: "APPLE_HEALTH",
            externalId: nil
        )
        // No segments → empty string, never " · " orphans.
        #expect(WorkoutFormatter.subtitle(entry).isEmpty)
    }
}

/// Source-label mapping shared with WorkoutDetailView + SourcePriorityRow.
@Suite("WorkoutDetailView — source label parity")
@MainActor
struct WorkoutDetailViewSourceLabelTests {
    @Test("Source enum values render to readable German labels")
    func sourceLabels() {
        #expect(WorkoutDetailView.sourceLabel("APPLE_HEALTH") == "Apple Health")
        #expect(WorkoutDetailView.sourceLabel("apple_health") == "Apple Health")
        #expect(WorkoutDetailView.sourceLabel("WITHINGS") == "Withings")
        #expect(WorkoutDetailView.sourceLabel("MANUAL") == "Manuell")
        #expect(WorkoutDetailView.sourceLabel("IMPORT") == "Import")
        // W-WORKOUT-E2E — server ingests WHOOP (v1.11.0) + Fitbit (v1.12.0)
        // workouts; brand spellings, not `.capitalized` ("Whoop").
        #expect(WorkoutDetailView.sourceLabel("WHOOP") == "WHOOP")
        #expect(WorkoutDetailView.sourceLabel("FITBIT") == "Fitbit")
        // Unknown source → capitalised pass-through (never empty).
        #expect(WorkoutDetailView.sourceLabel("STRAVA") == "Strava")
    }
}
