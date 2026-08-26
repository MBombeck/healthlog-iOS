import SwiftUI

/// v0.5.5.6 POLISH-PR — Hero Record card.
///
/// Apple-Fitness-Award-styled card that anchors the top of the
/// `PersonalRecordsScreen`. Picks the user's most impressive record
/// (`PersonalRecordsStore.heroRecord`) and renders it as a 280pt diagonal
/// gradient hero with a 60pt kind glyph (`.bounce` on appear), a
/// 56pt-bold value, "Bestleistung · seit \(date)" caption, and a
/// trailing share button that opens the system share sheet with an
/// `ImageRenderer`-rendered share image.
///
/// **Visual language** — diagonal gradient: kind tint at top-leading →
/// kind tint at 35% in the middle → near-black at 85% bottom-trailing.
/// Reduces to a single tint on Reduce Transparency.
///
/// **Liquid Glass** — on iOS 26+ the share button's background lifts
/// through `.hlGlassEffect` so the affordance reads as a glass pill on
/// the gradient. On iOS 18-25 it falls back to a translucent overlay.
struct HeroRecordCard: View {
    let record: PersonalRecord
    let onShare: (PersonalRecord) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    /// Audit-01 H3 — the hero value keeps its 56pt visual weight at the
    /// default setting but now scales with Dynamic Type (the pixel-locked
    /// `hlMetric(56)` ignored accessibility text sizes entirely).
    @ScaledMetric(relativeTo: .largeTitle) private var heroValueSize: CGFloat = 56

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backgroundGradient
            trophyWatermark
            content
            shareButton
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.xl, style: .continuous))
        .hlShadow(HLShadow.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
        .onAppear { hasAppeared = true }
    }

    // MARK: - Subviews

    private var backgroundGradient: some View {
        let tint = PersonalRecordKindTint.color(for: record.kind)
        return LinearGradient(
            stops: [
                .init(color: tint, location: 0.0),
                .init(color: tint.opacity(0.35), location: 0.55),
                .init(color: HLColor.recordHeroScrim.opacity(0.85), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            // Soft spotlight in the top-trailing corner — matches the
            // Apple-Fitness-Award gradient signature without needing a
            // real RadialGradient (cheaper to render at scroll time).
            RadialGradient(
                colors: [HLColor.recordHeroInk.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 220
            )
        )
    }

    /// v0.14.1 (#139) — a subtle monochrome trophy/Pokal watermark so the big
    /// hero card no longer reads as empty. Rendered in graphite/silver (white
    /// at very low opacity over the dark bottom-trailing of the gradient — NOT
    /// a loud accent colour, doctrine-safe), oversized and bled off the
    /// bottom-trailing corner so it sits clearly BEHIND the value + glyph as a
    /// texture, not a competing focal point. Hidden from VoiceOver (decorative)
    /// and clipped to the card's rounded rect by the parent `clipShape`.
    private var trophyWatermark: some View {
        Image(systemName: "trophy.fill")
            // Decorative background texture at a FIXED render size — it must NOT
            // grow with Dynamic Type (it is a watermark, not readable text), so a
            // pixel-locked size is correct here.
            // swiftlint:disable:next dynamic_type_bypass
            .font(.system(size: 240, weight: .bold))
            // Graphite/silver watermark: white ink at very low opacity over the
            // dark bottom-trailing of the existing gradient. Matches the file's
            // established in-gradient spotlight style (see `backgroundGradient`);
            // routed through the sanctioned `recordHeroInk` token (v0.14.8 W2,
            // Audit §1.1) — monochrome + doctrine-safe (no accent hue).
            .foregroundStyle(
                LinearGradient(
                    colors: [HLColor.recordHeroInk.opacity(0.14), HLColor.recordHeroInk.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .rotationEffect(.degrees(-12))
            .offset(x: 70, y: 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            kindGlyph
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(formattedValue)
                    // Design-system rounded-bold metric token, Dynamic-Type-
                    // scaled via `heroValueSize` (audit-01 H3).
                    .font(.hlMetric(heroValueSize))
                    .foregroundStyle(HLColor.recordHeroInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    // v0.8.0 W6 — 0.6 → 0.75: hero record value held above the
                    // legibility floor at large Dynamic Type.
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText(value: record.base.value))
                Text(unitLabel)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLColor.recordHeroInk.opacity(0.8))
            }
            Spacer(minLength: 0)
            HStack(spacing: HLSpace.sm) {
                if let slot = record.base.metricSlot, !slot.isEmpty {
                    Text(slot)
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLColor.recordHeroInk.opacity(0.9))
                        .padding(.horizontal, HLSpace.sm)
                        .padding(.vertical, HLSpace.xxs)
                        .background(HLColor.recordHeroInk.opacity(0.18), in: Capsule())
                }
                Text(achievedAtLabel)
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.recordHeroInk.opacity(0.85))
            }
        }
        .padding(HLSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindGlyph: some View {
        Image(systemName: glyphName)
            // Cover-scale hero glyph (audit-01 H2/M1 — the one-off 60pt pulled
            // onto the canonical `HLIconSize.cover`).
            .font(.hlIcon(HLIconSize.cover))
            .foregroundStyle(HLColor.recordHeroInk)
            .symbolEffect(.bounce, value: hasAppeared && !reduceMotion)
            .accessibilityHidden(true)
    }

    private var shareButton: some View {
        Button {
            onShare(record)
        } label: {
            Image(systemName: "square.and.arrow.up")
                // Audit-01 M1 — share-button glyph on the canonical scale
                // (was an unannotated fixed 17pt).
                .font(.hlIcon(HLIconSize.lg))
                .foregroundStyle(HLColor.recordHeroInk)
                .frame(width: 44, height: 44)
                .hlGlassEffect(in: Circle(), fallback: HLColor.recordHeroScrim.opacity(0.25))
        }
        .padding(HLSpace.md)
        .accessibilityLabel(Text("Share record"))
        .accessibilityHint(Text("Opens the share sheet for this record."))
    }

    // MARK: - Derived

    private var glyphName: String {
        guard let kind = record.kind else { return "rosette" }
        return MetricKindDescriptor.descriptor(for: kind).sfSymbol
    }

    private var formattedValue: String {
        Self.numberFormatter.string(from: NSNumber(value: record.base.value)) ?? "\(record.base.value)"
    }

    private var unitLabel: String {
        record.base.unit.isEmpty ? "" : record.base.unit
    }

    private var achievedAtLabel: String {
        "Bestleistung · seit \(Self.dateFormatter.string(from: record.base.achievedAt))"
    }

    private var accessibilityLabel: Text {
        let metric = MetricTypeLocalisation.label(forType: record.base.metricType)
        return Text(
            "Persönlicher Rekord \(metric): \(formattedValue) \(unitLabel), erreicht am \(Self.dateFormatter.string(from: record.base.achievedAt))"
        )
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .long
        return f
    }()
}

#Preview("HeroRecordCard") {
    let dto = PersonalRecordDTO(
        id: "preview.steps",
        userId: "u1",
        metricType: "ACTIVITY_STEPS",
        metricSlot: "Bester Tag",
        direction: .max,
        value: 23412,
        unit: "Steps",
        achievedAt: Date(timeIntervalSince1970: 1_716_854_400),
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
        previousValue: 21000,
        bucket: .month,
        impressiveness: 0.95
    )
    return HeroRecordCard(record: record, onShare: { _ in })
        .padding()
        .background(HLSurface.primary)
}
