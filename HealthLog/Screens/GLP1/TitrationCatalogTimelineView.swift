import SwiftUI

/// The label's standard titration schedule, truncated at the dose the user has
/// actually reached, as a calm vertical list of plain informational rows.
///
/// **1.4.2 boundary (ruling R10):** the forward ladder is gone. Earlier
/// versions drew every rung of the escalation sequence with the upcoming ones
/// dimmed behind a dashed connector and a "You are here" marker pointing at
/// the next step — a dosage projection derived from the user's own dose, which
/// Guideline 1.4.2 reserves for manufacturers, hospitals, universities,
/// insurers and pharmacies. Nothing above the current dose renders any more,
/// and no rung is styled as a suggestion to escalate. What is left is the
/// manufacturer's published sequence (EMA EPAR §4.2) up to where the user
/// stands, cited through the Sources link. See `GLP1DrugCatalog` GROUND RULE 9.
///
/// **Self-suppressing:** renders nothing when `steps` is empty (non-titrating
/// med, or no recorded dose to anchor the schedule at).
///
/// **Reduce-motion safe:** static layout, no entrance animation.
struct TitrationCatalogTimelineView: View {
    let steps: [TitrationCatalogTimeline.Step]
    let drugID: GLP1DrugCatalog.DrugID

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("medication.titration.plan.title")

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        TitrationCatalogRow(step: step, isLast: index == steps.count - 1)
                    }
                }

                // The schedule is the manufacturer's, not the app's — say so,
                // and hand the reader the EMA source it comes from. The link
                // stays outside every `.combine` group above it.
                Text(String(localized: "Per the manufacturer's guide — discuss any change with your doctor."))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HLSourcesLink(topic: .titration(drugID))
            }
        }
    }
}

// MARK: - Row

private struct TitrationCatalogRow: View {
    let step: TitrationCatalogTimeline.Step
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            rail
            VStack(alignment: .leading, spacing: 0) {
                Text(TitrationLadderSection.formatDose(step.doseMg))
                    .font(step.isCurrent ? .hlHeadline : .hlSubhead)
                    .foregroundStyle(step.isCurrent ? Color.accentColor : HLText.primary)
                    .monospacedDigit()
                    .padding(.vertical, HLSpace.xs)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            node
            if !isLast {
                HLColor.separator
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 20)
    }

    private var node: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    step.isCurrent ? Color.accentColor : HLColor.separator,
                    lineWidth: 1.5
                )
                .background(
                    Circle().fill(step.isCurrent ? Color.accentColor.opacity(0.12) : .clear)
                )
                .frame(width: 20, height: 20)
            if step.isCurrent {
                Circle().fill(.tint).frame(width: 7, height: 7)
            }
        }
        .padding(.top, HLSpace.xs)
    }

    private var accessibilityLabel: Text {
        let dose = TitrationLadderSection.formatDose(step.doseMg)
        let state = step.isCurrent
            ? String(localized: "medication.titration.plan.a11y.current")
            : String(localized: "medication.titration.plan.a11y.past")
        return Text("\(dose), \(state)")
    }
}
