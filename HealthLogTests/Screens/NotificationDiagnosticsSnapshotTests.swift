import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    /// v0.5.5 W-MED — pin the diagnostics snapshot builder.
    ///
    /// The screen consumes a `Snapshot` derived from
    /// `UNUserNotificationCenter`'s three async queries. Those queries
    /// can't be stubbed in the host-app-less test runner, so we exercise
    /// the pure-data builder via `buildForTesting(...)` instead. The
    /// screen never mutates a Snapshot — every assertion below is a
    /// UI-stability anchor (sort order, action-list formatting, preview
    /// cap, placeholder shape).
    @Suite("NotificationDiagnosticsScreen — snapshot builder")
    @MainActor
    struct NotificationDiagnosticsSnapshotTests {
        @Test("categories are sorted alphabetically by identifier")
        func categoriesSorted() {
            let snapshot = NotificationDiagnosticsScreen.Snapshot.buildForTesting(
                authorizationLabel: "Erlaubt",
                categories: [
                    ("MOOD_REMINDER", ["mood.log.now", "mood.snooze.1h"]),
                    ("DAILY_BRIEFING_NUDGE", ["BRIEFING_OPEN"]),
                    ("MEDICATION_REMINDER", ["med.taken", "med.snooze.15m", "med.skipped"])
                ],
                pendingCount: 0,
                previews: []
            )
            let ids = snapshot.categories.map(\.identifier)
            #expect(ids == ["DAILY_BRIEFING_NUDGE", "MEDICATION_REMINDER", "MOOD_REMINDER"])
        }

        @Test("category with empty action list renders fallback label")
        func emptyCategoryActionsRenderFallback() {
            let snapshot = NotificationDiagnosticsScreen.Snapshot.buildForTesting(
                authorizationLabel: "Erlaubt",
                categories: [("LEGACY_EMPTY", [])],
                pendingCount: 0,
                previews: []
            )
            #expect(snapshot.categories.count == 1)
            #expect(snapshot.categories[0].actionsLabel == String(localized: "Keine Aktionen"))
        }

        @Test("category action identifiers join with a comma + space separator")
        func categoryActionsConcatenate() {
            let snapshot = NotificationDiagnosticsScreen.Snapshot.buildForTesting(
                authorizationLabel: "Erlaubt",
                categories: [
                    ("MEDICATION_REMINDER", ["med.taken", "med.snooze.15m", "med.skipped"])
                ],
                pendingCount: 0,
                previews: []
            )
            #expect(snapshot.categories[0].actionsLabel == "med.taken, med.snooze.15m, med.skipped")
        }

        @Test("pendingCount surfaces the raw input count regardless of preview cap")
        func pendingCountStaysRaw() {
            // pendingCount comes from the FULL pending-request list; the
            // preview cap (5 rows) is a UI concern. A center holding 17
            // pending requests must still surface "17" — operator
            // self-diagnosis depends on the unrounded count, otherwise
            // a queue bloated by stale local reminders looks healthy.
            let snapshot = NotificationDiagnosticsScreen.Snapshot.buildForTesting(
                authorizationLabel: "Erlaubt",
                categories: [],
                pendingCount: 17,
                previews: Array(repeating: (identifier: "x", fireLabel: "in 1 Min."), count: 5)
            )
            #expect(snapshot.pendingCount == 17)
            #expect(snapshot.nextPendingPreviews.count == 5)
        }

        @Test("placeholder shows loading copy + empty surfaces")
        func placeholderShape() {
            let placeholder = NotificationDiagnosticsScreen.Snapshot.placeholder
            #expect(placeholder.authorizationLabel == String(localized: "notifications.diagnostics.loading"))
            #expect(placeholder.categories.isEmpty)
            #expect(placeholder.pendingCount == 0)
            #expect(placeholder.nextPendingPreviews.isEmpty)
        }
    }
#endif
