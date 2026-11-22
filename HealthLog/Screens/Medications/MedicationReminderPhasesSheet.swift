import SwiftUI

/// **The reminder phases of a medication** (web `PhaseConfigSheet`), offered
/// for every medication with a schedule.
///
/// One card per phase, in the order a dose goes through them: Due, Still due,
/// Overdue, Missed, each with what it does, minutes or a share of the dose
/// window, and its value. "Reset to defaults" fills in the server defaults
/// without saving; the check mark saves all four. A refused save names the
/// allowed range under the cards.
struct MedicationReminderPhasesSheet: View {
    @Bindable var model: MedicationPhaseConfigModel

    var body: some View {
        HLSheetScaffold(
            "med.phases.title",
            size: .form,
            action: .save(isEnabled: model.canSave) { await model.save() },
            isDirty: model.isDirty,
            isBusy: model.isSaving,
            confirmIdentifier: "med.phases.save"
        ) {
            HLPage {
                switch model.state {
                case .loaded:
                    form
                case .failed:
                    failedCard
                case .idle, .loading:
                    HLInlineProgress()
                        .frame(maxWidth: .infinity, minHeight: HLHitTarget.minimum)
                        .task { if model.state == .idle { await model.load() } }
                }
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        Text(verbatim: String(
            localized: "med.phases.description",
            defaultValue: "When each reminder comes and when a dose counts as missed."
        ))
        .hlText(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

        ForEach(MedicationReminderPhase.allCases) { phase in
            MedicationReminderPhaseCard(phase: phase, model: model)
        }

        if let message = model.saveError {
            HLFormErrorText(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("med.phases.error")
        }

        HLButton("med.phases.reset", variant: .secondary) {
            model.resetToDefaults()
        }
        .disabled(model.isSaving)
        .accessibilityIdentifier("med.phases.reset")
    }

    private var failedCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(verbatim: String(
                    localized: "med.phases.error.load",
                    defaultValue: "Could not load the reminder timing."
                ))
                .hlText(.factLabel)
                .fixedSize(horizontal: false, vertical: true)
                HLButton("med.phases.retry", variant: .secondary) {
                    Task { await model.load() }
                }
                .accessibilityIdentifier("med.phases.retry")
            }
        }
    }
}

/// One phase: its name and what it does, the unit, the value.
private struct MedicationReminderPhaseCard: View {
    let phase: MedicationReminderPhase
    @Bindable var model: MedicationPhaseConfigModel

    private static let modes = MedicationPhaseConfig.Mode.allCases

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(verbatim: phase.title)
                    .hlText(.rowTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: phase.hint)
                    .hlText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                HLAdaptiveSegmentedPicker(
                    "med.phases.mode",
                    selection: modeBinding,
                    labels: Self.modes.map(Self.label),
                    values: Self.modes
                ) {
                    ForEach(Self.modes, id: \.self) { mode in
                        Text(Self.label(mode)).tag(mode)
                    }
                }
                .accessibilityIdentifier("med.phases.\(phase.rawValue).mode")
                HLNumberField(
                    "med.phases.value",
                    value: valueBinding,
                    unit: model.mode(for: phase) == .minutes ? HLUnit.minutes : HLUnit.percent,
                    range: Double(MedicationPhaseConfig.valueRange.lowerBound) ...
                        Double(MedicationPhaseConfig.valueRange.upperBound),
                    fractionDigits: 0 ... 0
                )
                .accessibilityIdentifier("med.phases.\(phase.rawValue).value")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private static func label(_ mode: MedicationPhaseConfig.Mode) -> LocalizedStringKey {
        switch mode {
        case .minutes: "med.phases.mode.minutes"
        case .percent: "med.phases.mode.percent"
        }
    }

    private var modeBinding: Binding<MedicationPhaseConfig.Mode> {
        Binding(
            get: { model.mode(for: phase) },
            set: { model.setMode($0, for: phase) }
        )
    }

    private var valueBinding: Binding<Double?> {
        Binding(
            get: { model.value(for: phase) },
            set: { model.setValue($0, for: phase) }
        )
    }
}
