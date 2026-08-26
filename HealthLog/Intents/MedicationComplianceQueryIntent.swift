import AppIntents
import Foundation

/// **v0.8.4 WWIDGET-3 — the compliance READ intent.**
///
/// The one gap in the App-Intents surface: every shipped intent is a *write*
/// action (log BG / log BP / mark taken). This is the read counterpart the
/// operator's own wishlist named — "Hab ich heute meine Medikamente
/// genommen?" Returns today's adherence ("X von Y Dosen genommen") as a
/// spoken / Spotlight `ProvidesDialog` snippet. Read-only, side-effect-free,
/// safe to run from Siri / Spotlight / Shortcuts.
///
/// **Fast + offline-friendly, server-first as backstop.** First reads the
/// App Group ``WidgetSnapshot`` the app already writes (the same compliance
/// the widget paints) — sub-millisecond, works with no network. When the
/// snapshot is missing / stale (app never launched today, fresh install),
/// it falls back to a **server-first** fetch via the shared
/// ``IntentDependencies`` (`MedicationsRepository.compliance(days:)`),
/// exactly the launch-independent resolver the write intents use. On a
/// network error with no snapshot it surfaces a soft "couldn't check" line
/// rather than a hard failure.
struct MedicationComplianceQueryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check today’s medication adherence"

    static let description = IntentDescription(
        "Tells you how many of today’s medication doses you’ve taken."
    )

    static let openAppWhenRun: Bool = false

    /// Read-only — surface it as a query in Spotlight / Siri.
    static let isDiscoverable: Bool = true

    /// Test seam — overrides the snapshot the intent reads first. Production
    /// never sets this. `@MainActor`-isolated (perform runs on the main
    /// actor) so the mutable static is Swift-6 concurrency-safe.
    @MainActor static var snapshotStoreOverride: WidgetSnapshotStore?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        // Fast path: the App Group snapshot the app + widget already share.
        let store = Self.snapshotStoreOverride ?? WidgetSnapshotStore()
        if let snapshot = store.read(), snapshot.generatedAt > .distantPast {
            let summary = snapshot.compliance
            return .result(
                dialog: ComplianceQueryCopy.dialog(scheduled: summary.scheduled, taken: summary.taken)
            )
        }

        // Backstop: server-first fetch (launch-independent resolver).
        do {
            let days = try await deps.medicationsRepo.compliance(days: 1)
            let today = ComplianceDayMatcher.today(in: days) ?? days.last
            guard let today else {
                return .result(dialog: ComplianceQueryCopy.dialog(scheduled: 0, taken: 0))
            }
            return .result(
                dialog: ComplianceQueryCopy.dialog(scheduled: today.scheduled, taken: today.taken)
            )
        } catch {
            return .result(dialog: ComplianceQueryCopy.unavailable)
        }
    }
}

/// **M1 — timezone-robust "is this the compliance day for today?" matcher.**
///
/// `ComplianceDay.date` carries two different day-key bases depending on the
/// data source:
/// - **server** path → **UTC** midnight (`JSONDecoder.hlDayKey`, UTC, mirrors
///   the server's `medications/intake?scope=compliance` convention).
/// - **standalone** path → **local** midnight
///   (`MedicationsRepository+Standalone` uses `Calendar.current.startOfDay`).
///
/// A naive `Calendar.current.isDateInToday($0.date)` misses the server's
/// UTC-midnight day for any user west of UTC (the Americas) — UTC-midnight maps
/// to the *previous* local calendar day — surfacing yesterday's compliance in
/// the Siri/Shortcut answer, and giving a different result online vs offline.
///
/// The matcher accepts a `ComplianceDay` as "today" when its `.date` is the
/// start-of-today under **either** the current calendar (standalone/local) OR a
/// UTC-pinned calendar (server), so both bases resolve correctly regardless of
/// the device timezone. Static + pure for unit testing with an injected `now`.
enum ComplianceDayMatcher {
    static func today(in days: [ComplianceDay], now: Date = .now) -> ComplianceDay? {
        var utc = Calendar(identifier: .iso8601)
        utc.timeZone = .gmt
        let local = Calendar.current
        let localToday = local.startOfDay(for: now)
        let utcToday = utc.startOfDay(for: now)
        return days.first {
            local.isDate($0.date, inSameDayAs: localToday)
                || utc.isDate($0.date, inSameDayAs: utcToday)
        }
    }
}

/// **v0.8.4 WWIDGET-3 — pure, localized copy for the compliance query.**
///
/// Split out so the scheduled/taken → spoken-summary mapping is unit-testable
/// without an AppIntent perform or a live snapshot/server. The three buckets
/// the operator cares about — *nothing scheduled*, *all taken*, *some
/// remaining* — each get a distinct, natural line in EN + DE.
enum ComplianceQueryCopy {
    /// Build the spoken / Spotlight dialog for today's `taken` of `scheduled`
    /// doses. Counts are clamped defensively (`taken` never exceeds
    /// `scheduled`, both ≥ 0) so a transient out-of-range snapshot can't read
    /// as "5 of 3 doses".
    static func dialog(scheduled: Int, taken: Int) -> IntentDialog {
        IntentDialog(resource(scheduled: scheduled, taken: taken))
    }

    /// The pure `LocalizedStringResource` the dialog wraps — the unit-tested
    /// seam. Picks the rest-day / complete / remaining variant and formats
    /// the counts.
    static func resource(scheduled rawScheduled: Int, taken rawTaken: Int) -> LocalizedStringResource {
        let scheduled = max(0, rawScheduled)
        let taken = max(0, min(rawTaken, scheduled))

        if scheduled == 0 {
            return LocalizedStringResource(
                "You have no doses scheduled for today.",
                comment: "AppIntents — compliance query, nothing scheduled today"
            )
        }
        if taken >= scheduled {
            return LocalizedStringResource(
                "You’ve taken all \(scheduled) of today’s doses.",
                comment: "AppIntents — compliance query, all doses taken; %lld is the total"
            )
        }
        return LocalizedStringResource(
            "You’ve taken \(taken) of \(scheduled) doses today.",
            comment: "AppIntents — compliance query, partial; %1$lld taken of %2$lld scheduled"
        )
    }

    /// No snapshot and the server fetch failed — soft, retry-from-app line.
    static var unavailable: IntentDialog {
        IntentDialog(
            LocalizedStringResource(
                "I couldn’t check your adherence right now. Please open HealthLog and try again.",
                comment: "AppIntents — compliance query, snapshot missing + server unreachable"
            )
        )
    }
}
