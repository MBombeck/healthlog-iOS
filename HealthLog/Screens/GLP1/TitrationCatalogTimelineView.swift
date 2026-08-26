import SwiftUI

/// The catalog titration-ladder "you-are-here" plan — iOS mirror of the web
/// v1.18.5 titration-timeline (`titration-timeline.tsx`). Renders the drug's
/// standard escalation ladder as a calm vertical timeline: completed rungs
/// checked behind, the current rung on the tint accent with a "Du bist hier"
/// marker, upcoming rungs dimmed with a dashed connector.
///
/// **MDR copy guard:** the ladder is the manufacturer's standard sequence
/// (EMA EPAR §4.2), shown for orientation only — no rung is presented as a
/// recommendation to escalate, no dates are attached. See
/// `GLP1DrugCatalog` GROUND RULE 9.
///
/// **Self-suppressing:** renders nothing when `steps` is empty (non-titrating
/// med — no catalog drug or a single-rung ladder).
///
/// **Reduce-motion safe:** static layout, no entrance animation.
struct TitrationCatalogTimelineView: View {
    let steps: [TitrationCatalogTimeline.Step]

    var body: some View {
        if steps.count >= 2 {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("medication.titration.plan.title")

                let markerAfter = TitrationCatalogTimeline.markerAfterIndex(steps)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        // "You are here" marker sits between the current rung
                        // and the first upcoming rung — or before the first
                        // rung when nothing is yet in effect (markerAfter == -1).
                        if (markerAfter == index - 1 && index > 0)
                            || (markerAfter == -1 && index == 0)
                        {
                            youAreHereMarker
                        }
                        TitrationCatalogRow(
                            step: step,
                            isLast: index == steps.count - 1,
                            nextIsPastOrCurrent: index + 1 < steps.count
                                && (steps[index + 1].isPast || steps[index + 1].isCurrent)
                        )
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var youAreHereMarker: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "location.fill")
                .font(.hlCaption2)
                .foregroundStyle(.tint)
            Text(String(localized: "medication.titration.plan.youAreHere"))
                .font(.hlCaption.weight(.medium))
                .foregroundStyle(.tint)
        }
        .padding(.leading, Self.railLeadingInset)
        .padding(.vertical, HLSpace.xxs)
        .accessibilityElement(children: .combine)
    }

    /// Leading inset that aligns the marker label with the rung dose text
    /// (node width 20 + gap 12).
    fileprivate static let railLeadingInset: CGFloat = 32
}

// MARK: - Row

private struct TitrationCatalogRow: View {
    let step: TitrationCatalogTimeline.Step
    let isLast: Bool
    let nextIsPastOrCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            rail
            VStack(alignment: .leading, spacing: 0) {
                Text(TitrationLadderSection.formatDose(step.doseMg))
                    .font(step.isCurrent ? .hlHeadline : .hlSubhead)
                    .foregroundStyle(doseColor)
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
                connector
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
                    nodeStroke,
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: step.isUpcoming ? [2, 2] : []
                    )
                )
                .background(Circle().fill(nodeFill))
                .frame(width: 20, height: 20)
            if step.isPast {
                Image(systemName: "checkmark")
                    .font(.hlCaption2.weight(.bold))
                    .foregroundStyle(HLText.secondary)
            } else if step.isCurrent {
                Circle().fill(.tint).frame(width: 7, height: 7)
            }
        }
        .padding(.top, HLSpace.xs)
    }

    @ViewBuilder
    private var connector: some View {
        if nextIsPastOrCurrent {
            HLColor.separator
        } else {
            // Dashed connector for the planned-ahead segment.
            Rectangle()
                .fill(HLColor.separator)
                .opacity(0.55)
                .mask(
                    VStack(spacing: 3) {
                        ForEach(0 ..< 12, id: \.self) { _ in
                            Rectangle().frame(height: 3)
                        }
                    }
                )
        }
    }

    private var doseColor: Color {
        if step.isCurrent {
            Color.accentColor
        } else if step.isPast {
            HLText.primary
        } else {
            HLText.tertiary
        }
    }

    private var nodeStroke: Color {
        if step.isCurrent {
            Color.accentColor
        } else if step.isPast {
            HLColor.separator
        } else {
            HLColor.separator.opacity(0.7)
        }
    }

    private var nodeFill: Color {
        step.isCurrent ? Color.accentColor.opacity(0.12) : .clear
    }

    private var accessibilityLabel: Text {
        let dose = TitrationLadderSection.formatDose(step.doseMg)
        let state = if step.isCurrent {
            String(localized: "medication.titration.plan.a11y.current")
        } else if step.isPast {
            String(localized: "medication.titration.plan.a11y.past")
        } else {
            String(localized: "medication.titration.plan.a11y.upcoming")
        }
        return Text("\(dose), \(state)")
    }
}
