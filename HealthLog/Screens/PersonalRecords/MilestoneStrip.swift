import SwiftUI

/// v0.5.5.6 POLISH-PR — All-time milestones strip.
///
/// Small Apple-Award-sticker row that surfaces broad, all-time-cumulative
/// achievements that don't belong in the metric-by-metric record grid:
/// "100 Tage geloggt", "100k Schritte gesamt", "Erste Monat-Streak".
///
/// **Why we synthesise these locally:** the server doesn't ship a
/// dedicated milestones surface and the operator's mental model is
/// "Achievements = collection-game shelf, Milestones = single-line
/// proof that I've been here a while". Computing them from
/// `enrichedRecords` keeps the strip rendering even when the back-end
/// has no records of its own to surface.
///
/// **Anatomy** (horizontal scroll):
/// - 36pt SF Symbol in a tinted circle (mono Theme-2.0 surface, not the
///   record's kind tint — milestones are app-anchor, not metric-anchor).
/// - 13pt-semibold label.
///
/// **Empty state**: when no milestone qualifies, the strip omits itself
/// via the parent's `if !milestones.isEmpty` guard.
struct MilestoneStrip: View {
    let milestones: [Milestone]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.md) {
                ForEach(milestones) { milestone in
                    MilestoneSticker(milestone: milestone)
                }
            }
            .padding(.horizontal, HLSpace.lg)
        }
        .scrollClipDisabled()
    }
}

/// One milestone — a small celebratory pill the user has hit.
struct Milestone: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String

    /// Synthesise the canonical milestones from the user's enriched
    /// records. Returns 0-N pills depending on which thresholds the
    /// user has crossed; the strip never renders empty pills.
    ///
    /// **Rules** (operator-validated):
    /// - "Erste Bestleistung" — at least one record exists.
    /// - "100 Tage Daten" — Steps record with `metricSlot == "Bester
    ///   Tag"` and `sparklineValues.count >= 100`.
    /// - "Erste Wochen-Streak" — at least one streak record with
    ///   `value >= 7`.
    /// - "Monats-Streak" — at least one streak record with `value >= 30`.
    static func synthesise(from records: [PersonalRecord]) -> [Milestone] {
        guard !records.isEmpty else { return [] }
        var out: [Milestone] = [
            .init(id: "first", symbol: "rosette", title: "Erste Bestleistung")
        ]
        let sparkLong = records.contains { $0.sparklineValues.count >= 100 }
        if sparkLong {
            out.append(.init(id: "100days", symbol: "calendar", title: "100 Tage Daten"))
        }
        let weekStreak = records.contains { record in
            let slot = (record.base.metricSlot ?? "").lowercased()
            return (slot.contains("serie") || slot.contains("streak")) && record.base.value >= 7
        }
        if weekStreak {
            out.append(.init(id: "week-streak", symbol: "flame.fill", title: "Wochen-Streak"))
        }
        let monthStreak = records.contains { record in
            let slot = (record.base.metricSlot ?? "").lowercased()
            return (slot.contains("serie") || slot.contains("streak")) && record.base.value >= 30
        }
        if monthStreak {
            out.append(.init(id: "month-streak", symbol: "flame.circle.fill", title: "Monats-Streak"))
        }
        return out
    }
}

private struct MilestoneSticker: View {
    let milestone: Milestone

    var body: some View {
        VStack(spacing: HLSpace.xs) {
            ZStack {
                Circle()
                    .fill(HLSurface.tertiary)
                    .frame(width: 52, height: 52)
                Image(systemName: milestone.symbol)
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(
                        size: 24,
                        weight: .semibold
                    )) // Glyph centred in the fixed 52×52 milestone medallion — sized to the fixed frame, not body text; routing it through
                    // .hero (28pt) would overflow the chip.
                    .foregroundStyle(HLAccent.userBrandTint)
            }
            Text(milestone.title)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 80)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Meilenstein: \(milestone.title)"))
    }
}

#Preview("MilestoneStrip") {
    MilestoneStrip(milestones: [
        Milestone(id: "first", symbol: "rosette", title: "Erste Bestleistung"),
        Milestone(id: "100days", symbol: "calendar", title: "100 Tage Daten"),
        Milestone(id: "week-streak", symbol: "flame.fill", title: "Wochen-Streak"),
        Milestone(id: "month-streak", symbol: "flame.circle.fill", title: "Monats-Streak")
    ])
    .padding(.vertical, HLSpace.md)
    .background(HLSurface.primary)
}
