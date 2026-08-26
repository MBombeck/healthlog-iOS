import SwiftUI

// MARK: - ROUTE-07 (v1.37.20) — skip and snooze

//
// Extracted from `VorsorgeReminderDetailSheet.swift` on 2026-08-23 (Plan 17-02,
// G2) so the SAME implementation can be mounted twice: once in the detail sheet
// where it has lived since 08-18, and once on the reminder tile, which is where
// the operator expects to reach it.
//
// It is one type rather than two, deliberately. The medication tile marks a dose
// taken or skipped without opening anything, and „Skip/Snooze funktionieren
// ordentlich" was read as sheet-only for exactly the reason the G2 button drift
// happened: a second copy is a second thing to forget. Both placements call the
// same store methods, reuse the same learned 404-refusal gate, and stamp nothing
// locally; only the button chrome differs, because a tile action and a sheet's
// full-width action are two different roles under R9.

/// The two accepted cycle actions, offered only where the server allows them.
///
/// **The capability gate is learned, not computed.** The accepted DTO publishes
/// nothing that identifies the one reminder family that refuses these routes —
/// appointment (encounter) reminders, which `404` on skip, snooze and history
/// alike — so a locally-derived gate would be a capability iOS invented. The
/// store offers the affordance until the server refuses it and then withdraws
/// it for that reminder, which is the only honest gate the contract exposes.
///
/// Nothing is stamped locally: the restarted interval, `lastSkippedAt`,
/// `skipCount`, the cleared snooze and the resolved `snoozedUntil` all arrive on
/// the canonical row. While a call is in flight the buttons disable and the row
/// above keeps saying exactly what it said before.
struct VorsorgeReminderLedgerActions: View {
    /// Where the pair is mounted. Both placements call the SAME store methods
    /// and reuse the SAME 404-refusal path; only the button shape differs,
    /// because a tile action and a sheet's full-width action are two different
    /// roles under R9 (and R9/E2-A1 for the tile one).
    enum Placement {
        /// Inside a reminder tile — quiet `HLTileActionButton` pair (G2).
        case tile
        /// Inside the detail sheet — the pre-existing full-width `.secondary`.
        case sheet
    }

    let row: MeasurementReminderRow
    let store: MeasurementRemindersStore
    var placement: Placement = .sheet

    @State private var isPickingSnoozeDay = false
    @State private var snoozeDay = VorsorgeReminderLedgerActions.firstSelectableDay()

    private var isBusy: Bool {
        store.pendingAction[row.id] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.sm) {
                if store.supports(.skip, id: row.id) { skipButton }
                if store.supports(.snooze, id: row.id) { snoozeButton }
            }
            if isPickingSnoozeDay, store.supports(.snooze, id: row.id) { snoozePicker }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var skipButton: some View {
        switch placement {
        case .tile:
            HLTileActionButton("vorsorge.card.action.skip", icon: "forward.end") {
                Task { await store.skip(id: row.id) }
            }
            .disabled(isBusy)
            .accessibilityIdentifier("vorsorge.card.action.skip")
        case .sheet:
            HLButton(String(localized: "vorsorge.action.skip"), icon: "forward.end", variant: .secondary) {
                Task { await store.skip(id: row.id) }
            }
            .disabled(isBusy)
            .accessibilityIdentifier("vorsorge.detail.skip")
        }
    }

    @ViewBuilder
    private var snoozeButton: some View {
        switch placement {
        case .tile:
            HLTileActionButton("vorsorge.card.action.snooze", icon: "clock.badge") {
                isPickingSnoozeDay.toggle()
            }
            .disabled(isBusy)
            .accessibilityIdentifier("vorsorge.card.action.snooze")
        case .sheet:
            HLButton(String(localized: "vorsorge.action.snooze"), icon: "clock.badge", variant: .secondary) {
                isPickingSnoozeDay.toggle()
            }
            .disabled(isBusy)
            .accessibilityIdentifier("vorsorge.detail.snooze")
        }
    }

    /// The day picker plus its confirm. The **range** is the published bound
    /// (at least tomorrow, at most five years out) because a picker must have
    /// one; the **value** is never clamped on the way out — an out-of-bounds day
    /// is the server's `422`, and rewriting it here would hide a refusal the
    /// contract deliberately put on the server.
    private var snoozePicker: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            DatePicker(
                "vorsorge.action.snooze.day",
                selection: $snoozeDay,
                in: Self.selectableRange(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .accessibilityIdentifier("vorsorge.detail.snooze.day")
            snoozeConfirmButton {
                isPickingSnoozeDay = false
                // The wire field is `format: date`, so the picked instant becomes
                // a calendar day in the zone the person read the picker in —
                // 08-19's `day(_:in:)`, never a `Date` through the ISO encoder.
                let day = MeasurementReminderSnooze.day(snoozeDay, in: .current)
                Task { await store.snooze(id: row.id, until: day) }
            }
        }
    }

    /// The confirm, in the placement's own shape. Same closure, same day
    /// arithmetic, same store call — only the chrome differs.
    @ViewBuilder
    private func snoozeConfirmButton(action: @escaping () -> Void) -> some View {
        switch placement {
        case .tile:
            HLTileActionButton("vorsorge.action.snooze.confirm", action: action)
                .disabled(isBusy)
                .accessibilityIdentifier("vorsorge.card.action.snooze.confirm")
        case .sheet:
            HLButton(String(localized: "vorsorge.action.snooze.confirm"), variant: .secondary, action: action)
                .disabled(isBusy)
                .accessibilityIdentifier("vorsorge.detail.snooze.confirm")
        }
    }

    /// Tomorrow, in the person's own calendar — the earliest day the accepted
    /// route accepts. This is picker geometry, not due-date arithmetic: no
    /// server field is read and nothing derived here is ever displayed as truth.
    private static func firstSelectableDay(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }

    /// The published window: at least tomorrow, at most five years out.
    private static func selectableRange(now: Date = .now, calendar: Calendar = .current) -> ClosedRange<Date> {
        let first = firstSelectableDay(now: now, calendar: calendar)
        let last = calendar.date(byAdding: .year, value: 5, to: first) ?? first
        return first ... last
    }
}
