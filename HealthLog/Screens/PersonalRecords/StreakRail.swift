import SwiftUI

/// v0.5.5.6 POLISH-PR — Streak rail.
///
/// Horizontal scroll of capsule pills, one per streak-class record
/// (`PersonalRecordsStore.streakRecords`). Min capsule height 44pt
/// (HIG-compliant tap target). Tap fires `onTap(record)` upstream so
/// the screen can present detail or share.
///
/// **Visual**: `Capsule` filled at `HLSurface.tertiary` with a
/// kind-tinted leading icon. The current streak length lives in
/// `record.base.value` (e.g. `12.0` from `StreakComputer`); the
/// label format reads "X Tage" / "X Wochen" depending on magnitude
/// so the rail stays scannable.
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
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "flame.fill")
                    .font(.hlIcon(HLIconSize.rowAction))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(metricLabel)
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        .lineLimit(1)
                    Text(streakLabel)
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .frame(minHeight: 44)
            .background(HLSurface.tertiary, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(HLPressableButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(metricLabel): \(streakLabel)"))
    }

    private var tint: Color {
        PersonalRecordKindTint.color(for: record.kind)
    }

    private var metricLabel: String {
        MetricTypeLocalisation.label(forType: record.base.metricType)
    }

    private var streakLabel: String {
        let value = Int(record.base.value.rounded())
        return "\(value) \(record.base.unit.isEmpty ? "Tage" : record.base.unit)"
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
