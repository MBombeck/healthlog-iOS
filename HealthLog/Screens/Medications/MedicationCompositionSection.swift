import Observation
import SwiftUI

/// SUPP (1.5.0, #131) — the composition of a medication, read from its
/// single read (`GET /api/medications/{id}`, which the "Related" section
/// already makes; one read feeds both, see `MedicationDetailScreen+Related`).
///
/// No list, no section: an older server, a medication without a composition,
/// offline (the page's sync footer says so) and a refusal show nothing. A
/// failed read shows the heading with one sentence and "Retry", but only when
/// the list row says a composition is stored (`hasIngredients`), so a
/// medication without one never gains an error card.
@MainActor
@Observable
final class MedicationCompositionModel {
    enum State: Equatable {
        case idle
        case loaded([MedicationIngredient])
        case failed
    }

    private(set) var state: State = .idle
    /// SUPP-EDIT — the single read carried `ingredients` (server v1.43), so
    /// the composition can be edited. An older server never gets the link.
    private(set) var serverKnowsComposition = false

    func apply(_ medication: Medication) {
        serverKnowsComposition = medication.ingredients != nil
        state = .loaded(medication.compositionLines ?? [])
    }

    func apply(_ error: Error) {
        switch RelatedRecordsModel.stateAfter(error) {
        case .none: break
        case .failed: state = .failed
        default: state = .loaded([])
        }
    }
}

struct MedicationCompositionSection: View {
    let model: MedicationCompositionModel
    let medication: Medication
    /// Re-reads the medication (retry, and after a saved edit).
    let reload: () async -> Void

    @Environment(\.appContainer) private var container

    var body: some View {
        // Behind the opt-in nutrients module, as on the web.
        if container?.moduleGate.isEnabled(.nutrients) != false {
            switch model.state {
            case .idle:
                EmptyView()
            case let .loaded(lines):
                VStack(spacing: HLSpace.sm) {
                    if !lines.isEmpty { MedicationCompositionCard(lines: lines) }
                    MedicationCompositionEditLink(
                        medication: medication,
                        lines: lines,
                        serverKnowsComposition: model.serverKnowsComposition,
                        onSaved: reload
                    )
                }
            case .failed:
                if medication.expectsComposition { failedCard }
            }
        }
    }

    private var failedCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("medications.composition.title")
                Text("medications.composition.loadFailed")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HLButton("Retry", variant: .secondary, size: .compact) {
                    Task { await reload() }
                }
                .accessibilityIdentifier("medications.composition.retry")
            }
        }
    }
}

/// The lines as delivered: the server's name, the amount per unit in the
/// canonical unit and, where it was entered in another unit, that amount too.
struct MedicationCompositionCard: View {
    let lines: [MedicationIngredient]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("medications.composition.title")
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
                Text("medications.composition.perUnitNote")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("medications.composition")
    }

    private func row(_ line: MedicationIngredient) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: HLSpace.sm))
        return layout {
            Text(verbatim: line.displayName)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: line.amountText())
                .font(.hlSubhead.monospacedDigit())
                .foregroundStyle(HLText.secondary)
        }
        .padding(.vertical, HLSpace.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("medications.composition.row.\(line.nutrient)")
    }
}
