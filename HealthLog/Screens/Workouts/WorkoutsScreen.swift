import SwiftUI

/// Workouts surface (parity to web `/insights/workouts`).
///
/// Liste aller Workouts, die der Server nach `pickCanonicalWorkoutRows()`
/// (v1.4.30 cross-source-dedup) ausliefert. Jede Zeile zeigt Sport-Typ,
/// Datum, Dauer, Distanz (falls Cardio) und Energie. Tap öffnet das Detail
/// in derselben Mehr-Tab-NavigationStack.
///
/// **Daten:** `WorkoutsStore` → `WorkoutsRepository` →
/// `GET /api/workouts` mit SWR 60s. Load erst on `.task`, refresh via
/// Pull-to-Refresh (wieder ab Seite eins, Sportfilter bleibt).
///
/// **Paging:** Der Server liefert 50 Zeilen pro Seite. Kopfzeile zeigt
/// `meta.total` („50 von 730 Workouts“), die Fußzeile lädt die nächste Seite,
/// sobald sie in der lazy `List` sichtbar wird, bis `meta.total` erreicht ist.
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
                HLPage {
                    SectionRootHeader(LocalizedStringResource(String.LocalizationValue(Layout.navigationTitle)))
                    emptyState.hlStateFreeArea()
                }
            } else {
                list
            }
        }
        .hlScreenBackground()
        .hlScrollEdgeSoft()
        // Inline when pushed; as a sidebar tab the page heads itself.
        .hlSectionRootTitle(Text(LocalizedStringKey(Layout.navigationTitle)))
        .task { await store.revalidateIfStale() }
        .hlRefresh(in: .list) {
            await store.refresh()
            refreshTick &+= 1
        }
        // Success-tick on pull-to-refresh completion.
        .sensoryFeedback(.success, trigger: refreshTick)
        // The banner below still presents as this overlay; this
        // reserves its height at the top so it covers nothing.
        .hlReserveErrorBannerSpace(store.error)
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.refresh() }
            }
        }
    }

    private var list: some View {
        List {
            SectionRootHeader(LocalizedStringResource(String.LocalizationValue(Layout.navigationTitle)), inList: true)
            // "50 von 128 Workouts" is the list's own section header,
            // not a row of its own; the note that duplicates were merged is
            // gone (an implementation detail with nothing to act on).
            Section {
                // A data row: the whole row opens the workout, no chevron.
                ForEach(store.workouts) { workout in
                    WorkoutRow(workout: workout)
                        .hlRowLink(inList: true) {
                            WorkoutDetailView(workout: workout)
                        }
                        .accessibilityIdentifier("workouts.row.\(workout.id)")
                }
            } header: {
                if store.meta != nil, !store.workouts.isEmpty {
                    Text(WorkoutsListSummary.headerText(for: store))
                        .textCase(nil)
                        .accessibilityLabel(WorkoutsListSummary.headerAccessibilityLabel(for: store))
                        .accessibilityIdentifier("workouts.count")
                }
            }
            .hlFormRowSurface()
            // The footer is a lazy row: it only exists once the user
            // scrolled to the end, so its task is the "next page" trigger.
            // Keyed on the offset so a page that left the footer on screen
            // asks for the following one; the store drops repeats.
            Section {
                WorkoutsPagingFooter()
                    .task(id: store.currentOffset) { await store.loadNextPage() }
            }
            .listRowBackground(Color.clear)
            // Canonical sync-status footer (same primitive
            // as Dashboard/Insights, self-suppressing via empty-section footer).
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        .listStyle(.insetGrouped)
        .hlPageMargins()
    }

    /// The Workouts empty surface: the canonical `HLEmptyState`, centred in
    /// the free area of the page.
    private var emptyState: some View {
        HLEmptyState(
            icon: "figure.run",
            title: LocalizedStringKey(Layout.emptyTitle),
            message: LocalizedStringKey(Layout.emptySubtitle)
        )
        .accessibilityIdentifier("workouts.empty")
    }
}

extension WorkoutsScreen {
    /// Declarative layout descriptor — pinned by contract tests so a future
    /// wave can't silently drop the navigation title or the empty copy.
    enum Layout {
        static let navigationTitle = "Workouts"
        static let emptyTitle = "No workouts yet"
        static let emptySubtitle = "Workouts appear here as soon as Apple Watch or Withings reports one."
    }
}

// MARK: - Row

/// One workout in the shared row form: the sport's symbol in the row's
/// symbol column, sport and "date, distance, energy" on the left, the
/// duration as the value on the right.
struct WorkoutRow: View {
    let workout: WorkoutListEntryDTO

    var body: some View {
        let subtitle = WorkoutFormatter.subtitle(workout)
        HLRow(
            title: Text(WorkoutFormatter.sportTitle(workout.sportType)),
            detail: subtitle.isEmpty ? nil : Text(subtitle),
            value: WorkoutFormatter.duration(workout.durationSec).map { Text($0) }
        ) {
            HLRowGlyph(symbol: WorkoutFormatter.sportSymbol(workout.sportType))
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
        // The server's locked sport-type enum
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
        // The server's sport-type enum grew `badminton` after
        // v1.32.8. `sportType` is a raw `String?`, so the row always DECODED;
        // what was missing was a title + icon, so it fell through to the
        // capitalized raw token and the generic cardio glyph.
        "badminton": "Badminton",
        // The ball and racket sports the server enum carries; without a title
        // they read as the capitalised English token ("Soccer" under German).
        "golf": "Golf",
        "tennis": "Tennis",
        "basketball": "Basketball",
        "soccer": "Soccer"
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
        // Server sport-type enum tokens (see
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
        // New server sport-type literal (see `sportTitles`).
        "badminton": "figure.badminton"
    ]

    /// Subtitle stitched together as "<Datum> · <Distanz> · <Energie>".
    /// Skips any segment that's nil so the line never reads "· · 0 kcal".
    public static func subtitle(
        _ workout: WorkoutListEntryDTO,
        locale: Locale = .current,
        system: HLUnitPreference = .current()
    ) -> String {
        var parts: [String] = []
        if let start = workout.startedAt {
            // Day+month, plus the year when the workout isn't in the
            // current year, so historical workouts aren't ambiguous ("14. Juni"
            // vs "14. Juni 2024").
            parts.append(HLDateFormat.dayMonth(start, locale: locale))
        }
        if let distance = workout.distanceM, distance > 0 {
            parts.append(distanceLabel(metres: distance, locale: locale, system: system))
        }
        if let kcal = workout.activeEnergyKcal, kcal > 0 {
            parts.append("\(Int(kcal.rounded())) kcal")
        }
        return parts.joined(separator: ", ")
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
        // A stopwatch length ("2:05"), not a time of day: the 12/24-hour
        // setting does not apply.
        // swiftlint:disable:next hl_date_via_helper
        return String(format: "%d:%02d", minutes, secs)
    }

    /// `< 1000m` rendered as `820 m`, otherwise `12,3 km`.
    ///
    /// On an imperial account (`system`, the account's
    /// `unitPreference` mirror) the distance reads in miles, `3.1 mi`, like
    /// every other distance in the app.
    public static func distanceLabel(
        metres: Double,
        locale: Locale = .current,
        system: HLUnitPreference = .current()
    ) -> String {
        if system == .imperial {
            let miles = metres / metresPerMile
            return "\(HLNumberFormat.decimal(miles, fractionDigits: miles < 10 ? 2 : 1, locale: locale)) mi"
        }
        if metres < 1000 {
            return "\(Int(metres.rounded())) m"
        }
        let km = metres / 1000
        return "\(HLNumberFormat.decimal(km, fractionDigits: 1, locale: locale)) km"
    }

    /// A distance as `HLValueText` draws it: number, unit, precision.
    struct DistanceReading: Equatable {
        let value: Double
        let unit: HLUnit
        let fractionDigits: ClosedRange<Int>
    }

    /// The same distance as ``distanceLabel(metres:locale:system:)``, for a
    /// value drawn by `HLValueText`.
    static func distanceReading(
        metres: Double,
        system: HLUnitPreference = .current()
    ) -> DistanceReading {
        if system == .imperial {
            let miles = metres / metresPerMile
            let digits = miles < 10 ? 2 : 1
            return DistanceReading(value: miles, unit: .custom("mi"), fractionDigits: digits ... digits)
        }
        if metres < 1000 {
            return DistanceReading(value: metres.rounded(), unit: .meters, fractionDigits: 0 ... 0)
        }
        return DistanceReading(value: metres / 1000, unit: .kilometers, fractionDigits: 1 ... 1)
    }

    /// Metres in one statute mile — the unit conversion factor for pace.
    private static let metresPerMile = 1609.344

    /// True when pace reads in min/mi.
    ///
    /// The ACCOUNT's unit system decides, not the device locale.
    /// Keying off `Locale.measurementSystem` gave a US-locale phone "/mi" pace
    /// next to a "km" distance, and an imperial account on a German phone
    /// "/km" next to every other value in lb and °F.
    static func usesImperialPace(_ system: HLUnitPreference) -> Bool {
        system == .imperial
    }

    /// Pace label from a per-kilometre pace, unit-adapted to the account:
    /// `5:30 /km` (metric) or `8:51 /mi` (imperial). Seconds are rounded to whole
    /// seconds and formatted `m:ss` (minutes never zero-padded, seconds always
    /// two digits). Returns nil for a non-positive pace so the caller can hide
    /// the value rather than paint `0:00`.
    public static func paceLabel(secondsPerKm: Double, system: HLUnitPreference = .current()) -> String? {
        guard secondsPerKm > 0 else { return nil }
        let imperial = usesImperialPace(system)
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
    /// to the account. Convenience over ``paceLabel(secondsPerKm:system:)`` for
    /// the workout-summary case where only totals are known. Returns nil when
    /// either input is non-positive (no honest pace to show).
    public static func paceLabel(metres: Double, durationSec: Int, system: HLUnitPreference = .current()) -> String? {
        guard metres > 0, durationSec > 0 else { return nil }
        let secondsPerKm = Double(durationSec) / (metres / 1000)
        return paceLabel(secondsPerKm: secondsPerKm, system: system)
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
