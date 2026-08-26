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
    /// **15-01 (B1)** — called when the operator chooses "Zeit bearbeiten".
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

    /// **POLISH-MED (v0.5.5.6).** Slimmed from the prior `.hlHeadline`
    /// timestamp + `HLBadge` chip layout (~64 pt) to a ~52 pt row with
    /// `.hlSubhead.weight(.semibold)` timestamp + inline 14 pt SF Symbol
    /// status. The `HLBadge` pills duplicated the colour the icon now
    /// carries and read as visual noise in a dense history list.
    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(timestamp)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .lineLimit(1)
                if let site = event.injectionSite {
                    Text(siteLabel(site))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusIcon
            // v0.6.1.18 Y10.4 — operator brief 2026-05-24: "Genommene
            // Medikamente können nicht mehr bearbeitet oder gelöscht
            // werden." The original `.contextMenu` (long-press) was
            // not discoverable after the Y4 redesign moved the
            // at-a-glance read onto VerlaufGlyphTrack — the operator
            // didn't realise rows below were still tappable. Surface
            // a visible trailing menu button so edit + delete are
            // one-tap reachable. The same actions remain reachable via
            // long-press for muscle-memory users.
            //
            // v0.14.8 — the menu now renders on *every* row: past/due
            // rows carry the full retro-mark + delete set, future rows
            // carry delete only (operator brief 2026-06-07).
            retroMutateMenuButton
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
        .accessibilityHint(menuAccessibilityHint)
        .contentShape(Rectangle())
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

    /// A11y hint reflecting what the trailing menu actually offers on
    /// this row: edit-or-delete for retro-markable rows, delete-only for
    /// future/planned rows.
    private var menuAccessibilityHint: Text {
        canRetroMark
            ? Text(String(localized: "Tap the menu to edit or delete"))
            : Text(String(localized: "Tap the menu to delete the entry"))
    }

    /// v0.6.1.18 Y10.4 — visible trailing menu button so retro-mutate
    /// edit/delete actions don't depend on the operator discovering
    /// long-press. `Menu` opens a popover sheet anchored on the
    /// trailing edge, mirroring iOS Mail / Reminders row patterns.
    private var retroMutateMenuButton: some View {
        Menu {
            // v0.19 / 15-01 (B1) — the edit the row's own doc comment and its
            // "Edit or delete entry" label have promised since T-3: correct the
            // time a logged dose was actually taken.
            if canEditTime, let onEditTime {
                Button {
                    onEditTime()
                } label: {
                    Label(
                        String(localized: "med.history.edit_time.action"),
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }
            // Retro-mark actions only on past/due rows. `showMarkTaken`
            // / `showMarkSkipped` mirror the current state so the menu
            // only carries actions that actually flip something.
            if canRetroMark {
                if event.takenAt == nil || event.skipped {
                    Button {
                        onMarkTaken()
                    } label: {
                        Label(
                            String(localized: "Mark as taken"),
                            systemImage: "checkmark.circle"
                        )
                    }
                }
                if !event.skipped {
                    Button {
                        onMarkSkipped()
                    } label: {
                        Label(
                            String(localized: "Mark as skipped"),
                            systemImage: "xmark.circle"
                        )
                    }
                }
                // A retro-markable row always offers at least one mark
                // action above (taken when skipped/pending, skipped when
                // not-skipped), so the divider never orphans. A delete-only
                // (future) menu skips this whole block → no stray divider.
                Divider()
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(
                    String(localized: "Delete entry"),
                    systemImage: "trash"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.hlIcon(HLIconSize.lg, weight: .regular))
                .foregroundStyle(HLText.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .accessibilityLabel(menuButtonAccessibilityLabel)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    /// Trailing-menu button label: full edit-or-delete affordance on
    /// retro-markable rows, delete-only on future/planned rows.
    private var menuButtonAccessibilityLabel: Text {
        canRetroMark
            ? Text(String(localized: "Edit or delete entry"))
            : Text(String(localized: "Delete entry"))
    }

    private var timestamp: String {
        let date = event.takenAt ?? event.scheduledFor
        // M3 — date part keeps the locale order; the clock honours the user's
        // time-format preference via the central `HLTimeFormat` helper.
        let datePart = date.formatted(.dateTime.day().month(.abbreviated))
        return "\(datePart), \(HLTimeFormat.time(date))"
    }

    /// Inline 14 pt SF Symbol status, status-tinted. Replaces the prior
    /// `HLBadge` chip cluster (POLISH-MED v0.5.5.6). REG-10 auto-skip
    /// branch preserved.
    @ViewBuilder
    private var statusIcon: some View {
        // REG-10 (v0.5.6): treat past-due-pending rows older than the grace
        // window as visually skipped. Server still carries `skipped: false`
        // + `takenAt: null` until a cron worker reconciles (see B2-report);
        // this is the iOS-side visual fix so the operator stops seeing
        // March entries chip-rendered as "Offen" in mid-May.
        if event.skipped || event.isEffectivelySkipped(now: now) {
            Image(systemName: "xmark.circle.fill")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.tertiary)
                .accessibilityLabel(String(localized: "medications.history.intake.skipped_a11y"))
        } else if event.takenAt != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLColor.statusOK)
                .accessibilityLabel(String(localized: "medications.history.intake.taken_a11y"))
        } else if event.scheduledFor > now {
            Image(systemName: "clock")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
                .accessibilityLabel(String(localized: "medications.history.intake.scheduled_a11y"))
        } else {
            Image(systemName: "circle.dotted")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.tertiary)
                .accessibilityLabel(String(localized: "medications.history.intake.pending_a11y"))
        }
    }

    private func siteLabel(_ site: String) -> String {
        // Server emits canonical strings (`abdomen`, `thigh_left`, etc.) —
        // the catalog of localized names lives in the Settings/InjectionSites
        // module (out of Delta scope); fall back to capitalised raw for now.
        let cleaned = site.replacingOccurrences(of: "_", with: " ")
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }
}

/// Wrapper modifier so the context menu logic stays out of the row
/// body — keeps the row's `body` reviewable as pure layout.
///
/// v0.14.8 — the long-press menu now attaches to *every* row (the
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
    /// 15-01 (B1) — `nil` on rows where a time correction is meaningless
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
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(
                    String(localized: "Delete entry"),
                    systemImage: "trash"
                )
            }
        }
    }
}

// MARK: - REG-10 auto-skip grace

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

// v0.14.8 — renders the three menu shapes side by side so the operator's
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
