import Foundation

// The Erfassen sheet's values — its navigation payloads and the offer it
// resolves — lifted out of `MedicationQuickIntakeSheet.swift` (15-04,
// W-FILELEN) so that file stays under SwiftLint's 600-line ceiling once the
// as-needed section is in it.
//
// These three and not the confirm screen: a verbatim move still has to leave
// each file's own UI-standard debt where it was, and the confirm view carries a
// legacy HLButton variant that the R9 ledger counts against the file it lives
// in. Moving values moves no debt.

/// Navigation-path payload tying an intake to its parent medication for
/// the confirm screen render. Hashable so `NavigationStack` can diff it;
/// equality is intake-id-keyed so duplicate appends are no-ops.
struct IntakeOption: Hashable, Identifiable {
    let intake: MedicationIntake
    let medication: Medication

    var id: String {
        intake.id
    }

    /// `"HH:mm"` rendering for the scheduled-time column on the chooser
    /// + confirm screen. Honours the user's time-format preference.
    var scheduledTimeString: String {
        HLTimeFormat.time(intake.scheduledAt)
    }

    static func == (lhs: IntakeOption, rhs: IntakeOption) -> Bool {
        lhs.intake.id == rhs.intake.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(intake.id)
    }
}

// MARK: - What the Erfassen sheet has to offer

/// **The Erfassen sheet's offer, as a value.**
///
/// Lifted out of `MedicationQuickIntakeSheet.actionable` so what the
/// sheet lists can be read without a view host. `due` is verbatim: today's
/// pending intakes whose time has come, earliest first, joined to their active
/// medication — the resolution documented in the sheet's own header.
///
/// `asNeeded` is the second list this sheet has never had. A PRN medication has
/// no slot and can therefore never be "due", which is why the sheet — whose
/// only question was "which slot is due?" — could not offer it at all.
struct MedicationQuickIntakeOptions: Equatable {
    /// Pending scheduled slots whose time has come, earliest first.
    let due: [IntakeOption]
    /// As-needed medications, which have no slot to be due.
    let asNeeded: [Medication]
    /// Today's pending slots whose time has not come yet, earliest first.
    /// Home counts them as open (the server's `scheduledToday − takenToday`);
    /// the sheet names them so it never says "nothing open" beside Home's
    /// "1 still open". They are not offered for logging before their time.
    var later: [IntakeOption] = []

    /// Nothing to log right now (later slots are not loggable yet).
    var isEmpty: Bool {
        due.isEmpty && asNeeded.isEmpty
    }

    static func resolve(
        medications: [Medication],
        intakes: [MedicationIntake],
        now: Date,
        timeZone: TimeZone = .current
    ) -> MedicationQuickIntakeOptions {
        let calendar = MedicationDueRule.calendar(timeZone: timeZone)
        let pending = intakes
            .filter { $0.status == .pending }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .compactMap { intake -> IntakeOption? in
                guard let med = medications.first(where: { $0.id == intake.medicationId }),
                      med.active, med.offersIntakeActions else { return nil }
                return IntakeOption(intake: intake, medication: med)
            }
        // Due from the moment the slot's window opens, as the card says it.
        // #191 point 10: with the resolved state the server says which dose
        // is open now (`due` or `overdue`); without it the window rule.
        let serverState = MedicationServerResolvedSlots.isAvailable()
        let due = pending.filter {
            if serverState, let phase = MedicationDosePhase(wire: $0.intake.doseState?.state) {
                return phase == .due || phase == .overdue
            }
            return MedicationDueRule.isDue(scheduledAt: $0.intake.scheduledAt, medication: $0.medication, now: now, calendar: calendar)
        }
        // The intakes are today's already (profile day); the rest is later.
        let dueIDs = Set(due.map(\.id))
        let later = pending.filter { !dueIDs.contains($0.id) }
        // The second question. A PRN medication has no slot, so it is
        // offered on its own terms: active, as-needed (the medication-level
        // `asNeeded` flag — the 09-14 spelling), and not already standing in
        // the due list under a materialised slot.
        let dueMedicationIDs = Set(due.map(\.medication.id))
        let asNeeded = medications
            // v1.39.1 — a medication kept as a record offers no intake;
            // v1.39.4 — nor one the server calls not actionable today.
            .filter { $0.active && $0.asNeeded && $0.offersIntakeActions && !dueMedicationIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return MedicationQuickIntakeOptions(due: due, asNeeded: asNeeded, later: later)
    }
}

/// When a dose slot counts as due, one rule for the card, the list and the
/// intake sheet.
///
/// The window of a slot is ``MedicationWindowStatus/resolveDoseBands(_:)``,
/// the same per-dose band the card's "Jetzt fällig" and the Live Activity
/// read through ``MedicationWindowStatus/reduce``. The intake sheet used to
/// call a slot due only at its exact time, so at 19:20 the card said "due
/// now" for the 20:00 Naproxen while the sheet listed it under "later
/// today". The sheet now asks this rule, in the account's time zone like
/// the card. Reminders fire and the next-dose widget names the slot time
/// itself; they say when, not whether a dose is due now.
enum MedicationDueRule {
    /// A calendar in the account's zone, the one the card reads.
    nonisolated static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The instant the slot at `scheduledAt` becomes due: the wall-clock
    /// start of its window on the slot's day, or the slot itself when no
    /// band names that time. Wall-clock arithmetic, so a day with a clock
    /// change keeps the window an hour before the slot as the card sees it.
    nonisolated static func dueFrom(scheduledAt: Date, medication: Medication, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: scheduledAt)
        let slot = TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        let slotMinutes = slot.hour * 60 + slot.minute
        let bands = medication.schedule.entries.flatMap(MedicationWindowStatus.resolveDoseBands)
        guard let band = bands.first(where: { $0.timeOfDay == slot }),
              band.startMinutes < slotMinutes,
              let start = calendar.date(
                  bySettingHour: band.startMinutes / 60,
                  minute: band.startMinutes % 60,
                  second: 0,
                  of: scheduledAt
              ),
              start <= scheduledAt else
        {
            return scheduledAt
        }
        return start
    }

    /// Whether the slot is due at `now`.
    nonisolated static func isDue(
        scheduledAt: Date,
        medication: Medication,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        dueFrom(scheduledAt: scheduledAt, medication: medication, calendar: calendar) <= now
    }

    /// The card's check: every dose of today is taken or skipped, and at
    /// least one was taken. A snoozed, missed, open or unknown dose beside a
    /// taken one is not "done"; the card still says what is due.
    nonisolated static func allDosesSettled(medicationId: String, todayIntakes: [MedicationIntake]) -> Bool {
        let doses = todayIntakes.filter { $0.medicationId == medicationId }
        guard doses.contains(where: { $0.status == .taken }) else { return false }
        return doses.allSatisfy { $0.status == .taken || $0.status == .skipped }
    }
}
