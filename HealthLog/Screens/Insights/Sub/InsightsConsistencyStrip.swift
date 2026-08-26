import SwiftUI

/// 7-day consistency visualisation. One 12 pt circle per Berlin-tz daily
/// bucket, coloured by `in-band` (OK), `near-band` (warn), `out-band` (bad);
/// `nil` → a hollow outline (no reading that day).
///
/// **v0.11 W-A:** extracted out of the retired `TargetsScreen` so the
/// per-metric target reference panel (`InsightsTargetReferencePanel`) on each
/// `ChartDetailScreen` can render the same strip the web's `MetricTargetSummary`
/// shows. Color is signal-only (monochrome doctrine): the dots are the one
/// place a target's status earns a hue.
struct ConsistencyStrip: View {
    let buckets: [InsightsTargetsResponseDTO.TargetItem.ConsistencyBucket?]

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                Circle()
                    .fill(color(for: bucket))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .strokeBorder(HLColor.separator, lineWidth: bucket == nil ? 1 : 0)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "7-day consistency: \(summary)")))
    }

    private func color(for bucket: InsightsTargetsResponseDTO.TargetItem.ConsistencyBucket?) -> Color {
        switch bucket {
        case .inBand: HLColor.statusOK
        case .nearBand: HLColor.statusWarn
        case .outBand: HLColor.statusBad
        case .none: HLSurface.tertiary
        }
    }

    /// Accessible summary string — counts of in / near / out / missing.
    private var summary: String {
        let inCount = buckets.filter { $0 == .inBand }.count
        let nearCount = buckets.filter { $0 == .nearBand }.count
        let outCount = buckets.filter { $0 == .outBand }.count
        let missingCount = buckets.filter { $0 == nil }.count
        var parts: [String] = []
        if inCount > 0 { parts.append(String(localized: "\(inCount) in range")) }
        if nearCount > 0 { parts.append(String(localized: "\(nearCount) near target")) }
        if outCount > 0 { parts.append(String(localized: "\(outCount) out of range")) }
        if missingCount > 0 { parts.append(String(localized: "\(missingCount) without entry")) }
        return parts.isEmpty ? String(localized: "no data") : parts.joined(separator: ", ")
    }
}

#Preview("ConsistencyStrip") {
    ConsistencyStrip(buckets: [.inBand, .inBand, .nearBand, nil, .outBand, .inBand, .inBand])
        .padding()
        .background(HLSurface.secondary)
}
