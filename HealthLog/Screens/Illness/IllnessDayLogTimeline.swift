import SwiftUI

/// A compact day-log timeline for an episode detail. Each row is one logged day:
/// the date, a functional-impact chip, optional fever, and the symptom chips.
/// No timeline primitive exists, so this composes `HLCard` rows. Pure render —
/// every value is server-stored; nothing is recomputed.
struct IllnessDayLogTimeline: View {
    let state: IllnessDayLogTimelineState
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            switch state {
            case .loading:
                HStack(spacing: HLSpace.sm) {
                    ProgressView().controlSize(.small)
                    Text("illness.daylog.timeline.loading")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
            case .error:
                HLCard(style: .ghost) {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        Label("illness.daylog.timeline.error", systemImage: "exclamationmark.triangle")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                        HLButton("illness.daylog.timeline.retry", variant: .secondary, size: .compact) {
                            retry()
                        }
                    }
                }
            case .empty:
                Text("illness.daylog.timeline.empty")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            case let .loaded(dayLogs):
                ForEach(dayLogs) { log in
                    IllnessDayLogRow(log: log)
                }
            }
        }
    }
}

struct IllnessDayLogRow: View {
    let log: IllnessDayLogDTO

    var body: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack {
                    Text(IllnessDateFormat.mediumDate(log.date))
                        .font(.hlFootnote.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    if let impact = log.functionalImpact {
                        IllnessNeutralBadge(title: impactLabel(impact), tone: .info)
                    }
                }
                if let fever = log.feverC {
                    Label(feverLabel(fever), systemImage: "thermometer.medium")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
                if !log.symptoms.isEmpty {
                    symptomChips
                }
                if let note = log.note, !note.isEmpty {
                    Text(note)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symptomChips: some View {
        // Simple wrapping row of symptom chips.
        FlowChips(items: log.symptoms.map(symptomLabel))
    }

    private func symptomLabel(_ symptom: IllnessSymptom) -> String {
        let base: String = if let entry = IllnessSymptomCatalog.entry(for: symptom.key) {
            String(localized: String.LocalizationValue(entry.labelKey))
        } else {
            symptom.key.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let severity = symptom.severity {
            return "\(base) (\(severity))"
        }
        return base
    }

    private func impactLabel(_ impact: Int) -> String {
        IllnessPresentation.impactLabel(for: impact) ?? String(impact)
    }

    private func feverLabel(_ fever: Double) -> String {
        let value = fever.formatted(.number.precision(.fractionLength(0 ... 1)))
        let template = String(localized: "illness.daylog.fever.value")
        return String(format: template, value)
    }
}

/// A wrapping chip row — renders symptom labels as neutral capsules that wrap
/// to the next line. Uses a small `Layout` so chips never overflow the row.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        WrapLayout(spacing: HLSpace.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.hlCaption)
                    .padding(.horizontal, HLSpace.sm)
                    .padding(.vertical, HLSpace.xxs)
                    .background(Capsule().fill(HLSurface.secondary))
                    .foregroundStyle(HLText.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A minimal flow layout that wraps subviews to the next line when they exceed
/// the proposed width. Self-contained (no external Layout dependency).
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let added = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if added > maxWidth, rowWidth > 0 {
                rows.append([size])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(size)
                rowWidth = added
            }
        }
        var height: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight: CGFloat = row.map(\.height).max() ?? 0
            height += rowHeight
            if index > 0 { height += spacing }
            var w: CGFloat = 0
            for size in row {
                w += size.width
            }
            if row.count > 1 { w += spacing * CGFloat(row.count - 1) }
            maxRowWidth = max(maxRowWidth, w)
        }
        let boundedWidth = min(maxRowWidth, maxWidth)
        return CGSize(width: boundedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
