import SwiftUI

/// Streak rail.
///
/// Horizontal scroll of tags, one per streak-class record
/// (`PersonalRecordsStore.streakRecords`), each the shared `HLBadge` capsule
/// inside a 44 pt tap target. Tap fires `onTap(record)` upstream so the
/// screen can present detail or share.
///
/// The current streak length lives in `record.base.value` (e.g. `12.0` from
/// `StreakComputer`); the tag reads "Schritte, 12 Tage" so the rail stays
/// scannable.
///
/// **Empty state**: when no streak records exist, the rail collapses
/// to zero height (parent VStack hides it via `if !streaks.isEmpty`).
struct StreakRail: View {
    let streaks: [PersonalRecord]
    let onTap: (PersonalRecord) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.sm) {
                ForEach(streaks) { record in
                    StreakCapsule(record: record) {
                        onTap(record)
                    }
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.vertical, HLSpace.xxs)
        }
        .scrollClipDisabled()
    }
}

private struct StreakCapsule: View {
    let record: PersonalRecord
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            // The tag is the shared capsule; the frame around it keeps the
            // tap target at the minimum size.
            HLBadge(HLRowDetail.joined([metricLabel, streakLabel]) ?? streakLabel, icon: "flame.fill")
                .frame(minHeight: HLHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hlRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(metricLabel): \(streakLabel)"))
    }

    private var metricLabel: String {
        MetricTypeLocalisation.label(forType: record.base.metricType)
    }

    private var streakLabel: String {
        let value = Int(record.base.value.rounded())
        let unit = record.base.unit.isEmpty ? String(localized: "records.streak.unit") : record.base.unit
        return "\(value) \(unit)"
    }
}

#Preview("StreakRail") {
    let dto = PersonalRecordDTO(
        id: "preview.streak",
        userId: "u1",
        metricType: "ACTIVITY_STEPS",
        metricSlot: "Längste Serie ≥ 10.000 (12 Tage)",
        direction: .max,
        value: 12,
        unit: "Tage",
        achievedAt: Date(),
        sourceMeasurementId: nil,
        source: "HEALTHLOG_CLIENT",
        externalId: nil,
        createdAt: Date()
    )
    let record = PersonalRecord(
        id: dto.id,
        base: dto,
        kind: .steps,
        sparklineValues: [],
        peakIndex: nil,
        previousValue: nil,
        bucket: .month,
        impressiveness: 0.6
    )
    return StreakRail(streaks: [record, record, record], onTap: { _ in })
        .background(HLSurface.primary)
}
