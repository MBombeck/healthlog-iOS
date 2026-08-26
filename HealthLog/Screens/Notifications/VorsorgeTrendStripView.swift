import SwiftUI

/// **W-VORSORGE-CARDS (v0.15.1 web-parity) — the discreet 7-day trend strip on
/// a preventive-care card.**
///
/// The iOS mirror of the web `vorsorge-trend-strip.tsx` (v1.18.7): the metric's
/// last seven readings as seven quiet bars (oldest → newest), heights
/// normalised across the window via ``VorsorgeCard/stripHeights(values:)``. The
/// colour is intentionally muted (`HLText.tertiary` at low opacity) so the strip
/// reads as calm context under the metric — never an alarming status signal, in
/// keeping with the no-loud-colour card ethos.
///
/// Pulls the bounded last-7 readings for one metric through the existing
/// `MeasurementsRepository.recent(kind:limit:)` (a single small read per card,
/// SWR-cached by kind) — no new heavy aggregate query. A free-text reminder (no
/// `measurementType`, or a type the capture catalog can't map) renders nothing;
/// a metric with fewer than two readings in the window renders nothing (a single
/// dot is no trend). The fetch is best-effort: any error renders nothing rather
/// than surfacing an alarming failure on a secondary card affordance.
struct VorsorgeTrendStripView: View {
    let measurementType: String?

    @Environment(\.appContainer) private var container
    @State private var heights: [Double]?

    var body: some View {
        Group {
            if let heights, heights.count >= 2 {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(HLText.tertiary.opacity(0.45))
                            .frame(width: 6, height: CGFloat(h) * 22)
                    }
                }
                .frame(height: 22, alignment: .bottom)
                .accessibilityElement()
                .accessibilityLabel(Text("vorsorge.card.trendStrip.label"))
            }
        }
        .task(id: measurementType) { await load() }
    }

    private func load() async {
        heights = nil
        guard
            let kind = VorsorgeNextDue.prefillKind(forServerType: measurementType),
            let container else { return }
        // Best-effort: a failed read just leaves the strip absent (the card
        // height stays stable). Newest-first from the server → reverse to
        // oldest→newest so bars read left (older) → right (newest).
        let recent = await (try? container.measurementsRepo.recent(kind: kind, limit: 7)) ?? []
        let values = recent.map(\.primaryValue).reversed().map { $0 }
        heights = VorsorgeCard.stripHeights(values: values)
    }
}
