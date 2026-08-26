import SwiftUI

/// **08-21 (#219 / v1.37.19) — the per-slot inventory-dose control.**
///
/// One dose time, two values, and they are deliberately not the same value:
///
/// - The **picker** writes the RAW field (`MedicationScheduleDTO.unitsPerDose`).
///   "Standard" clears the override so the slot inherits the medication-level
///   dose; a curated unit sets an explicit one. Clearing is a real choice, not
///   an absence of one, which is why the sheet holds a tri-state and not a
///   `Double?`.
/// - The **caption** reads the server's `resolvedUnitsPerDose` for the slot —
///   the effective figure the server's own intake-consumption resolver uses.
///   It is displayed, never written (`MedicationScheduleDTO.encode(to:)` drops
///   the key) and never re-derived here.
///
/// The caption is withheld the moment anything it depends on has moved locally
/// — this slot's own picker, or the medication-level dose it inherits from —
/// because a stale server figure sitting under a changed picker reads as a
/// confirmation of the change and is worse than showing nothing. It comes back
/// after the save, from the server's own recomputation.
struct SlotDosePicker: View {
    /// The dose time this row edits, `HH:mm` — the key both maps are keyed by.
    let timeKey: String
    /// Row position, for a stable accessibility identifier only.
    let index: Int
    @Binding var intents: MedicationCadenceLogic.SlotDoseIntents
    /// The RAW overrides the server sent. A slot missing from this map inherits.
    let baseline: [String: Double]
    /// The server-EFFECTIVE dose per slot, read verbatim.
    let serverEffective: [String: Double]
    /// True once the medication-level `unitsPerDose` moved in this form.
    let medicationDoseChanged: Bool

    var body: some View {
        Picker("med.schedule.slotDose.label", selection: selection) {
            Text("med.schedule.slotDose.inherit").tag(SlotDoseSelection.inherit)
            ForEach(options) { option in
                Text(option.label).tag(SlotDoseSelection.override(option))
            }
        }
        .accessibilityIdentifier("med.schedule.slotDose.\(index)")
        if let effective = serverEffective[timeKey], !isLocallyEdited {
            Text("med.schedule.slotDose.effective \(MedicationUnitsPerDose.from(decimal: effective).label)")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
    }

    /// The curated options, plus this slot's current override when it is a
    /// valid server value outside the curated set (a web-set 15) — same
    /// reasoning as ``UnitsPerDosePicker``: without a matching tag the
    /// selection would snap to something the user never chose.
    private var options: [MedicationUnitsPerDose] {
        var all = MedicationUnitsPerDose.allCases
        if case let .override(current) = current, !all.contains(current) {
            all.append(current)
        }
        return all
    }

    /// The tri-state collapsed to what the picker should show right now.
    private var current: SlotDoseSelection {
        switch intents[timeKey] {
        case .clear:
            return .inherit
        case let .set(value):
            return .override(MedicationUnitsPerDose.from(decimal: value))
        case .unchanged, .none:
            guard let raw = baseline[timeKey] else { return .inherit }
            return .override(MedicationUnitsPerDose.from(decimal: raw))
        }
    }

    private var selection: Binding<SlotDoseSelection> {
        Binding(
            get: { current },
            set: { choice in
                switch choice {
                case .inherit:
                    intents[timeKey] = .clear
                case let .override(units):
                    intents[timeKey] = .set(units.decimalValue)
                }
            }
        )
    }

    private var isLocallyEdited: Bool {
        intents[timeKey] != nil || medicationDoseChanged
    }
}
