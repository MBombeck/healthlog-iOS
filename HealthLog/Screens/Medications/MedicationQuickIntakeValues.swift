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

/// **Build 6.1** — navigation marker that pushes the free / back-dated intake
/// form onto the quick-intake `NavigationStack`. Carries no payload (the form
/// picks its own medication); the singleton value keeps the push idempotent.
struct FreeIntakeRoute: Hashable {}

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
    /// + confirm screen. M3 — honours the user's time-format preference.
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

// MARK: - 15-04 (B6) — what the Erfassen sheet has to offer

/// **The Erfassen sheet's offer, as a value.**
///
/// Lifted out of `MedicationQuickIntakeSheet.actionable` (15-04) so what the
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

    var isEmpty: Bool {
        due.isEmpty && asNeeded.isEmpty
    }

    static func resolve(
        medications: [Medication],
        intakes: [MedicationIntake],
        now: Date
    ) -> MedicationQuickIntakeOptions {
        let due = intakes
            .filter { $0.status == .pending && $0.scheduledAt <= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .compactMap { intake -> IntakeOption? in
                guard let med = medications.first(where: { $0.id == intake.medicationId }),
                      med.active else { return nil }
                return IntakeOption(intake: intake, medication: med)
            }
        // B6 — the second question. A PRN medication has no slot, so it is
        // offered on its own terms: active, as-needed (the medication-level
        // `asNeeded` flag — the 09-14 spelling), and not already standing in
        // the due list under a materialised slot.
        let dueMedicationIDs = Set(due.map(\.medication.id))
        let asNeeded = medications
            .filter { $0.active && $0.asNeeded && !dueMedicationIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return MedicationQuickIntakeOptions(due: due, asNeeded: asNeeded)
    }
}
