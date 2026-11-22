import SwiftUI

/// One row of the per-medication intake history (rendered inside
/// `MedicationDetailScreen` → `IntakeHistorySection`). Carries the
/// retro-mutate context-menu actions T-4 introduced: mark a past
/// intake as taken / skipped, or delete the row outright.
///
/// The row is wrapped in an `HLCard` upstream — SwiftUI's native
/// `.swipeActions` only render inside `List` rows, so we surface the
/// retro-mutate options via `.contextMenu` (tap-and-hold) instead.
/// Mirrors the same UX decision T-3 made for the MedicationsScreen
/// active-row context menu (PB-T3 report, Felt-quality notes →
/// "Edit access: contextMenu instead of swipeAction — swipe-actions
/// inside a HLCard-wrapped VStack don't render correctly").
///
/// **Past-vs-future boundary (v0.14.8 — operator brief 2026-06-07):**
/// **Delete** is now available on *every* row (past, due, and future).
/// The operator reported missing the trailing menu on future/planned
/// rows ("14. Juli 08:00", "13. Juli 08:00") and wanted to delete those
/// too. **Retro-mark** (mark as taken / skipped) stays gated to rows
/// whose `scheduledFor < now`: pre-marking next week's dose is still
/// semantically wrong ("log a dose I'm taking right now" ≠ a future
/// placeholder). So a future row's menu carries **only** "Löschen";
/// a past/due row's menu carries "Als genommen" / "Als ausgelassen" /
/// "Löschen" as before.
struct IntakeHistoryRow: View {
    let event: PaginatedIntakeEvent
    /// Whether retro-mark actions (mark as taken / skipped) are offered.
    /// Detail screen passes `event.scheduledFor < .now`. Future events
    /// stay read-only for marking — but Delete is offered regardless
    /// (the delete action renders unconditionally).
    let canRetroMark: Bool

    // Delete is always available — every history row can be removed,
    // including future/planned placeholders (operator brief 2026-06-07).
    // There is intentionally no `canDelete` flag: the delete button +
    // context-menu delete render unconditionally below.

    /// "Now" reference used by the auto-skip rendering. Injected so the
    /// previews + tests can pin a deterministic time. Production passes
    /// `.now` from the parent screen.
    var now: Date = .now
    /// Called when the operator chooses "Markieren als genommen".
    /// Parent applies the optimistic patch + calls
    /// `MedicationsStore.markIntakeRetroactively(... status: .taken)`.
    let onMarkTaken: () -> Void
    /// Called when the operator chooses "Markieren als ausgelassen".
    let onMarkSkipped: () -> Void
    /// Called when the operator chooses "Löschen". Parent shows the
    /// confirmation alert before calling
    /// `MedicationsStore.deleteIntake`.
    let onDelete: () -> Void
    /// Called when the operator chooses "Zeit bearbeiten".
    /// Parent opens the inline time picker and, on save, sends `takenAt` over
    /// the intake PUT (`MedicationsStore.editIntakeTakenAt`). Optional so a
    /// preview / a future host that offers no edit surface can leave it out;
    /// the action then does not render (see ``canEditTime``).
    var onEditTime: (() -> Void)?

    /// The time edit is offered on rows that actually carry an administration
    /// instant. A skipped row has no time to correct, and a still-pending row
    /// is served by "Als genommen" (which logs the scheduled instant) — B1 is
    /// about a dose that WAS taken and was recorded at the wrong time.
    private var canEditTime: Bool {
        onEditTime != nil && event.takenAt != nil && !event.skipped
    }

    /// Slimmed from the prior `.hlHeadline`
    /// timestamp + `HLBadge` chip layout (~64 pt) to a ~52 pt row with
    /// `.hlSubhead.weight(.semibold)` timestamp + inline 14 pt SF Symbol
    /// status. The `HLBadge` pills duplicated the colour the icon now
    /// carries and read as visual noise in a dense history list.
    /// One history entry in the shared form: date and time as the title,
    /// one detail line (auto-recorded, injection site), the status symbol
    /// on the right. The actions live in the row's context menu, so the row
    /// carries no second control beside the status (Z18, Z22).
    /// The medication's configured dose, shown on the right of a taken row.
    var dose: String = ""

    /// One intake as a history row (Z22), like the ledger rows: date and
    /// time as the title, the dose of a taken row on the right, the state as
    /// its status text.
    var body: some View {
        Group {
            if let shown = Self.shownDose(event: event, dose: dose) {
                HLHistoryRow(date: Text(timestamp), detail: detail, value: Text(verbatim: shown), status: status)
            } else {
                HLRow(title: Text(timestamp), detail: detail, status: status)
            }
        }
        .modifier(RetroMutateContextMenu(
            canRetroMark: canRetroMark,
            currentlyTaken: event.takenAt != nil && !event.skipped,
            currentlySkipped: event.skipped,
            onMarkTaken: onMarkTaken,
            onMarkSkipped: onMarkSkipped,
            onDelete: onDelete,
            onEditTime: canEditTime ? onEditTime : nil
        ))
    }

    private var detail: Text? {
        HLRowDetail.text([
            event.isAutoRecordedTake ? String(localized: "med.history.auto_recorded") : nil,
            event.injectionSite.map(siteLabel)
        ])
    }

    private var timestamp: String {
        let date = event.takenAt ?? event.scheduledFor
        // Date part keeps the locale order; the clock honours the user's
        // time-format preference via the central `HLTimeFormat` helper.
        let datePart = HLDateFormat.dayMonth(date)
        return "\(datePart), \(HLTimeFormat.time(date))"
    }

    /// The dose a taken row reports; a skipped, planned or open intake took
    /// nothing and shows none.
    nonisolated static func shownDose(event: PaginatedIntakeEvent, dose: String) -> String? {
        guard event.takenAt != nil, !event.skipped else { return nil }
        let trimmed = dose.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The state as text under the value. Past-due-pending rows older than
    /// the grace window read as skipped: the server keeps `skipped: false`
    /// until a cron worker reconciles them.
    private var status: HLRowStatus {
        // Term list (#191): Übersprungen, Genommen, Ausstehend, Fällig.
        if event.skipped || event.isEffectivelySkipped(now: now) {
            return HLRowStatus(MedicationDosePhase.skipped.title)
        }
        if event.takenAt != nil {
            return HLRowStatus(MedicationDosePhase.taken.title)
        }
        if event.scheduledFor > now {
            return HLRowStatus(MedicationDosePhase.pending.title)
        }
        return HLRowStatus(MedicationDosePhase.due.title)
    }

    private func siteLabel(_ site: String) -> String {
        Self.injectionSiteLabel(site)
    }

    /// The injection site in the person's language. The server sends its own
    /// enum (`ABDOMEN_UPPER_LEFT`) or a legacy local string; a site this build
    /// cannot name reads "unknown site" rather than the raw code.
    nonisolated static func injectionSiteLabel(_ raw: String) -> String {
        (InjectionSite.parse(raw) ?? .unknown).localizedLabel
    }
}

/// Wrapper modifier so the context menu logic stays out of the row
/// body — keeps the row's `body` reviewable as pure layout.
///
/// The long-press menu now attaches to *every* row (the
/// trailing menu button mirrors it). Future/planned rows
/// (`canRetroMark == false`) carry **delete only**; past/due rows carry
/// the retro-mark + delete set, eliding the "already taken" / "already
/// skipped" branch so the menu only carries actions that flip state.
/// The menu is never empty (delete is always present), so the prior
/// "empty long-press feels broken" concern no longer applies.
private struct RetroMutateContextMenu: ViewModifier {
    let canRetroMark: Bool
    let currentlyTaken: Bool
    let currentlySkipped: Bool
    let onMarkTaken: () -> Void
    let onMarkSkipped: () -> Void
    let onDelete: () -> Void
    /// `nil` on rows where a time correction is meaningless
    /// (skipped, or never taken). Mirrors the trailing menu exactly.
    var onEditTime: (() -> Void)?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let onEditTime {
                Button {
                    onEditTime()
                } label: {
                    Label(
                        String(localized: "med.history.edit_time.action"),
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }
            if canRetroMark {
                if !currentlyTaken {
                    Button {
                        onMarkTaken()
                    } label: {
                        Label(
                            String(localized: "Mark as taken"),
                            systemImage: "checkmark.circle"
                        )
                    }
                }
                if !currentlySkipped {
                    Button {
                        onMarkSkipped()
                    } label: {
                        Label(
                            String(localized: "Mark as skipped"),
                            systemImage: "xmark.circle"
                        )
                    }
                }
                Divider()
            }
            // #188 (7): deleted at once, undone from the toast.
            HLDeleteMenuItem(.undoable {
                onDelete()
            })
        }
    }
}

// MARK: - Auto-skip grace

extension PaginatedIntakeEvent {
    /// Grace window after which a still-pending scheduled intake should
    /// render as auto-skipped. 24h matches the operator decision in the
    /// v0.5.6 handoff: "wenn Sachen nicht genommen werden, dann sollten
    /// die irgendwann automatisch eigentlich als nicht genommen oder
    /// ausgelassen [angezeigt werden]". Server still carries
    /// `skipped: false` until a periodic worker reconciles — see
    /// `.planning/v056-marathon/B2-report.md` for the proposed cron
    /// spec. iOS-side `isEffectivelySkipped` is purely visual and does
    /// not mutate any persisted state.
    static let autoSkipGrace: TimeInterval = 24 * 60 * 60

    /// True when the event is still server-pending (`takenAt == nil`,
    /// `skipped == false`) but its scheduled window slipped past the
    /// auto-skip grace. Future-scheduled rows and explicitly-marked
    /// rows return `false` so the existing status-chip branches still
    /// apply.
    func isEffectivelySkipped(now: Date = .now) -> Bool {
        guard !skipped, takenAt == nil else { return false }
        return scheduledFor.addingTimeInterval(Self.autoSkipGrace) < now
    }
}

// MARK: - Preview

// Renders the three menu shapes side by side so the operator's
// device walkthrough can confirm: a future/planned row's trailing menu +
// long-press carries **only "Löschen"**, while past taken / past pending
// rows keep the full retro-mark + delete set. Tap the ⋯ button (or
// long-press a row) on each to compare.
#Preview("IntakeHistoryRow — delete everywhere") {
    let now = Date.now
    return VStack(spacing: 0) {
        IntakeHistoryRow(
            event: PaginatedIntakeEvent(
                id: "future",
                takenAt: nil,
                skipped: false,
                scheduledFor: now.addingTimeInterval(7 * 24 * 3600),
                injectionSite: nil
            ),
            canRetroMark: false, // future → menu shows Löschen only
            now: now,
            onMarkTaken: {},
            onMarkSkipped: {},
            onDelete: {}
        )
        Divider()
        IntakeHistoryRow(
            event: PaginatedIntakeEvent(
                id: "past-taken",
                takenAt: now.addingTimeInterval(-2 * 24 * 3600),
                skipped: false,
                scheduledFor: now.addingTimeInterval(-2 * 24 * 3600),
                injectionSite: nil
            ),
            canRetroMark: true, // past taken → "Als ausgelassen" + Löschen
            now: now,
            onMarkTaken: {},
            onMarkSkipped: {},
            onDelete: {}
        )
        Divider()
        IntakeHistoryRow(
            event: PaginatedIntakeEvent(
                id: "past-pending",
                takenAt: nil,
                skipped: false,
                scheduledFor: now.addingTimeInterval(-3600),
                injectionSite: nil
            ),
            canRetroMark: true, // past pending → both marks + Löschen
            now: now,
            onMarkTaken: {},
            onMarkSkipped: {},
            onDelete: {}
        )
    }
    .padding()
}
