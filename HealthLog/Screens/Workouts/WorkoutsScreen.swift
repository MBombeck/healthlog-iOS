import SwiftUI

/// v0.5.3-F3 — Workouts surface (parity to web `/insights/workouts`).
///
/// Liste aller Workouts, die der Server nach `pickCanonicalWorkoutRows()`
/// (v1.4.30 cross-source-dedup) ausliefert. Jede Zeile zeigt Sport-Typ,
/// Datum, Dauer, Distanz (falls Cardio) und Energie. Tap öffnet das Detail
/// in derselben Mehr-Tab-NavigationStack.
///
/// **Daten:** `WorkoutsStore` (v0.5.2-A7) → `WorkoutsRepository` →
/// `GET /api/workouts` mit SWR 60s. Load erst on `.task`, refresh via
/// Pull-to-Refresh.
///
/// **Empty-State:** Server-Seite liefert leere Liste sobald die HK-Workout-
/// Batch-Ingest noch nichts hochgeladen hat. Empty-Copy verweist auf
/// Apple-Health-Sync.
struct WorkoutsScreen: View {
    @Environment(WorkoutsStore.self) private var store
    @State private var refreshTick: Int = 0

    var body: some View {
        Group {
            if store.workouts.isEmpty, !store.isLoading, store.error == nil {
                emptyState
            } else {
                list
            }
        }
        .hlScreenBackground()
        .hlScrollEdgeSoft()
        .navigationTitle(LocalizedStringKey(Layout.navigationTitle))
        .task { await store.revalidateIfStale() }
        .refreshable {
            await store.refresh()
            refreshTick &+= 1
        }
        // POLISH-SWEEP: success-tick on pull-to-refresh completion.
        .sensoryFeedback(.success, trigger: refreshTick)
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.refresh() }
            }
        }
    }

    private var list: some View {
        List {
            if let meta = store.meta, meta.droppedDuplicates > 0 {
                Section {
                    Text(LocalizedStringKey(Layout.duplicatesFootnoteKey))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(store.workouts) { workout in
                    NavigationLink {
                        WorkoutDetailView(workout: workout)
                    } label: {
                        WorkoutRow(workout: workout)
                    }
                    .accessibilityIdentifier("workouts.row.\(workout.id)")
                }
            }
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same primitive
            // as Dashboard/Insights, self-suppressing via empty-section footer).
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
    }

    /// v0.7.0 — adopted `ContentUnavailableView` (iOS 17+) for the
    /// Workouts empty surface — the canonical `HLEmptyState` lockup
    /// (audit-01 C1), centered like the system primitive was.
    private var emptyState: some View {
        HLEmptyState(
            icon: "figure.run",
            title: LocalizedStringKey(Layout.emptyTitle),
            message: LocalizedStringKey(Layout.emptySubtitle)
        )
        .accessibilityIdentifier("workouts.empty")
        .containerCentered()
    }
}

extension WorkoutsScreen {
    /// Declarative layout descriptor — pinned by contract tests so a future
    /// wave can't silently drop the navigation title or the duplicates
    /// footnote.
    enum Layout {
        static let navigationTitle = "Workouts"
        static let emptyTitle = "No workouts yet"
        static let emptySubtitle = "Workouts appear here as soon as Apple Watch or Withings reports one."
        static let duplicatesFootnoteKey = "Duplicate workouts (Watch + scale) were merged."
    }
}

// MARK: - Row

/// Single-line row showing the most important workout signals at a glance.
/// Mirrors the web `<WorkoutList>` row layout — sport name + date on the
/// leading edge, key metrics on the trailing edge.
struct WorkoutRow: View {
    let workout: WorkoutListEntryDTO

    var body: some View {
        HStack(spacing: HLSpace.md) {
            iconCircle
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(WorkoutFormatter.sportTitle(workout.sportType))
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Text(WorkoutFormatter.subtitle(workout))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: HLSpace.sm)
            if let duration = WorkoutFormatter.duration(workout.durationSec) {
                Text(duration)
                    .font(.hlSubhead.monospacedDigit())
                    .foregroundStyle(HLText.primary)
            }
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }

    private var iconCircle: some View {
        ZStack {
            Circle()
                .fill(HLSurface.tertiary)
                .frame(width: 40, height: 40)
            Image(systemName: WorkoutFormatter.sportSymbol(workout.sportType))
                .font(.hlIcon(HLIconSize.lg))
                .foregroundStyle(HLText.secondary)
        }
    }
}

// MARK: - Pure formatter (testable without UI)

/// Pure helpers — kept on the type so screen tests can exercise label
/// derivation without spinning up the full SwiftUI hierarchy.
public enum WorkoutFormatter {
    /// Translates the raw HKWorkoutActivityType identifier the server emits
    /// (e.g. `"HKWorkoutActivityTypeRunning"`, `"running"`, `"WALKING"`)
    /// into a human-readable, locale-adaptive title. Unknown values fall back
    /// to a stripped raw identifier so the user always sees something rather
    /// than an empty cell.
    public static func sportTitle(_ raw: String?) -> String {
        let normalised = normalise(raw)
        if normalised.isEmpty || normalised == "other" {
            return String(localized: "Workout")
        }
        // WHOOP rows whose `sport_name` was absent arrive as the server's
        // generic `whoop_sport_<id>` token (see `sportLabel()` in the
        // server's `src/lib/whoop/sync-workout.ts`). "Whoop_Sport_44" is
        // not a user-facing label — fold to the generic workout title.
        if normalised.hasPrefix("whoop_sport") {
            return String(localized: "Workout")
        }
        if let mapped = sportTitles[normalised] {
            return String(localized: mapped)
        }
        // Title-case the raw token so the user reads "Tennis" rather
        // than "tennis" / "TENNIS" / "HKWorkoutActivityTypeTennis".
        return normalised.capitalized
    }

    /// SF Symbol best-effort match. Falls back to a generic activity icon
    /// when the sport type is unknown so the row is never iconless.
    public static func sportSymbol(_ raw: String?) -> String {
        let normalised = normalise(raw)
        return sportSymbols[normalised] ?? "figure.mixed.cardio"
    }

    /// Maps a normalised HK activity token to an English source string that
    /// is resolved through `Localizable.xcstrings` at call time (`String(localized:)`),
    /// so the title follows the user's locale instead of being German-locked.
    private static let sportTitles: [String: String.LocalizationValue] = [
        "running": "Running",
        "walking": "Walking",
        "cycling": "Cycling",
        "swimming": "Swimming",
        "hiking": "Hiking",
        "yoga": "Yoga",
        "functionalstrengthtraining": "Strength training",
        "traditionalstrengthtraining": "Strength training",
        "highintensityintervaltraining": "HIIT",
        "pilates": "Pilates",
        "elliptical": "Elliptical",
        "rowing": "Rowing",
        "stairs": "Stairs",
        "stairclimbing": "Stairs",
        "dancing": "Dancing",
        "mixedcardio": "Cardio",
        "cardio": "Cardio",
        // v0.14.8 W-WORKOUT-E2E — the server's locked sport-type enum
        // (`workoutSportTypeEnum`, the tokens our own ingest uploads via
        // `WorkoutHealthKitMapping`) uses these spellings; without them the
        // list rendered raw fallbacks like "Hiit" / "Mindandbody" for rows
        // we wrote ourselves.
        "strength": "Strength training",
        "hiit": "HIIT",
        "mindandbody": "Mind & Body",
        "stairclimber": "Stairs",
        "crosstraining": "Cross-training",
        "dance": "Dancing",
        // CU-16 (A6) — the server's sport-type enum grew `badminton` after
        // v1.32.8. `sportType` is a raw `String?`, so the row always DECODED;
        // what was missing was a title + icon, so it fell through to the
        // capitalized raw token and the generic cardio glyph.
        "badminton": "Badminton"
    ]

    private static let sportSymbols: [String: String] = [
        "running": "figure.run",
        "walking": "figure.walk",
        "cycling": "figure.outdoor.cycle",
        "swimming": "figure.pool.swim",
        "hiking": "figure.hiking",
        "yoga": "figure.yoga",
        "functionalstrengthtraining": "figure.strengthtraining.traditional",
        "traditionalstrengthtraining": "figure.strengthtraining.traditional",
        "highintensityintervaltraining": "figure.mixed.cardio",
        "pilates": "figure.pilates",
        "elliptical": "figure.elliptical",
        "rowing": "figure.rower",
        "stairs": "figure.stairs",
        "stairclimbing": "figure.stairs",
        "dancing": "figure.dance",
        // v0.14.8 W-WORKOUT-E2E — server sport-type enum tokens (see
        // `sportTitles` note above) + the ball/racket sports the mapper
        // already uploads.
        "strength": "figure.strengthtraining.traditional",
        "hiit": "figure.mixed.cardio",
        "mindandbody": "figure.mind.and.body",
        "stairclimber": "figure.stairs",
        "crosstraining": "figure.cross.training",
        "dance": "figure.dance",
        "golf": "figure.golf",
        "tennis": "figure.tennis",
        "basketball": "figure.basketball",
        "soccer": "figure.outdoor.soccer",
        // CU-16 (A6) — new server sport-type literal (see `sportTitles`).
        "badminton": "figure.badminton"
    ]

    /// Subtitle stitched together as "<Datum> · <Distanz> · <Energie>".
    /// Skips any segment that's nil so the line never reads "· · 0 kcal".
    public static func subtitle(_ workout: WorkoutListEntryDTO, locale: Locale = .current) -> String {
        var parts: [String] = []
        if let start = workout.startedAt {
            // b215 — day+month, plus the year when the workout isn't in the
            // current year, so historical workouts aren't ambiguous ("14. Juni"
            // vs "14. Juni 2024").
            parts.append(HLDateFormat.dayMonth(start, locale: locale))
        }
        if let distance = workout.distanceM, distance > 0 {
            parts.append(distanceLabel(metres: distance, locale: locale))
        }
        if let kcal = workout.activeEnergyKcal, kcal > 0 {
            parts.append("\(Int(kcal.rounded())) kcal")
        }
        return parts.joined(separator: " · ")
    }

    /// `123` → `2:03`, `7322` → `2:02:02`. nil-safe.
    public static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// `< 1000m` rendered as `820 m`, otherwise `12,3 km`.
    public static func distanceLabel(metres: Double, locale: Locale = .current) -> String {
        if metres < 1000 {
            return "\(Int(metres.rounded())) m"
        }
        let km = metres / 1000
        return "\(HLNumberFormat.decimal(km, fractionDigits: 1, locale: locale)) km"
    }

    /// Metres in one statute mile — the unit conversion factor for pace.
    private static let metresPerMile = 1609.344

    /// True when the locale prefers imperial distance (pace in min/mi).
    /// `Locale.measurementSystem == .us` → miles; `.metric` / `.uk` → km.
    /// The UK deliberately runs metric distance despite mixed everyday units,
    /// matching the server + web (which key pace off the same metric default).
    static func usesImperialPace(_ locale: Locale) -> Bool {
        locale.measurementSystem == .us
    }

    /// Pace label from a per-kilometre pace, unit-adapted to the locale:
    /// `5:30 /km` (metric) or `8:51 /mi` (US). Seconds are rounded to whole
    /// seconds and formatted `m:ss` (minutes never zero-padded, seconds always
    /// two digits). Returns nil for a non-positive pace so the caller can hide
    /// the value rather than paint `0:00`.
    public static func paceLabel(secondsPerKm: Double, locale: Locale = .current) -> String? {
        guard secondsPerKm > 0 else { return nil }
        let imperial = usesImperialPace(locale)
        // min/mi is the time to cover one mile, i.e. km-pace × (metres/mile ÷ 1000).
        let secondsPerUnit = imperial
            ? secondsPerKm * (metresPerMile / 1000)
            : secondsPerKm
        let total = Int(secondsPerUnit.rounded())
        let minutes = total / 60
        let seconds = total % 60
        let unit = imperial ? "/mi" : "/km"
        return String(format: "%d:%02d %@", minutes, seconds, unit)
    }

    /// Pace derived from a distance (metres) + duration (seconds), unit-adapted
    /// to the locale. Convenience over ``paceLabel(secondsPerKm:locale:)`` for
    /// the workout-summary case where only totals are known. Returns nil when
    /// either input is non-positive (no honest pace to show).
    public static func paceLabel(metres: Double, durationSec: Int, locale: Locale = .current) -> String? {
        guard metres > 0, durationSec > 0 else { return nil }
        let secondsPerKm = Double(durationSec) / (metres / 1000)
        return paceLabel(secondsPerKm: secondsPerKm, locale: locale)
    }

    /// Strips the `HKWorkoutActivityType` prefix and lower-cases the
    /// remainder so the lookup table reads cleanly.
    private static func normalise(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let trimmed = raw.hasPrefix("HKWorkoutActivityType")
            ? String(raw.dropFirst("HKWorkoutActivityType".count))
            : raw
        return trimmed.lowercased()
    }
}
