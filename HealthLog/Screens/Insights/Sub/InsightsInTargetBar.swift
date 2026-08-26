import SwiftUI

/// v0.14 FINAL-QA DRIFT-1/DRIFT-8 — the ONE canonical "Im Zielbereich" /
/// "In range" bar.
///
/// Before this, `InsightsPrimaryTile.inTargetBar` and `BPStatusCard.bpInTargetBar`
/// were byte-identical copies (same `targetTone`, same raw `cornerRadius: 4`,
/// same labels, same a11y) — two code paths for one bar, guaranteed to drift.
/// This extracts the shared header + rail + percentage into a single primitive
/// so the primary tile (every non-BP metric) and the BP status card render the
/// IDENTICAL bar, and a future change lands in one place.
///
/// **DRIFT-8 — one empty-track treatment.** The rail track uses the single
/// `Self.trackTone` token (`HLColor.backgroundEleva`) and the single
/// `Self.cornerRadius` shape, the SAME pair `RangeBandRow` (`HLRangeBand`) uses,
/// so every percentage rail in Insights reads as one family. The compliance bar
/// on the Medications page keeps its capsule silhouette (a deliberately distinct
/// affordance) but shares this empty-track token.
///
/// **Monochrome doctrine:** the only colour is the status-toned fill + the
/// percentage label (`targetTone` — ≥80 OK · 50–79 warn · <50 bad); the track
/// and labels ride the `HLText.*` / `HLColor.backgroundEleva` mono scale.
struct InsightsInTargetBar: View {
    /// Server-provided in-target share (0…100). Clamped on render so a malformed
    /// payload can never paint past the rail.
    let pct: Int

    /// b183 coherence — the window this share is measured over ("90 T" for BP,
    /// "30 T" for the locally-computed non-BP metrics). The two call sites carry
    /// DIFFERENT windows (BP rides the server's 90-day `bpPctInTarget`, every
    /// other metric the local 30-day day-count share), so the bare "N %" was
    /// ambiguous — the operator read the BP 90-day figure as if it were a yearly
    /// one. Rendered as "· <label>" next to "In range" + spoken in the a11y
    /// label. `nil` ⇒ no window suffix (legacy / unknown window).
    var windowLabel: String?

    /// The single empty-track token shared across every Insights percentage rail
    /// (in-target bar + `RangeBandRow`). DRIFT-8: one token, one family.
    static let trackTone: Color = HLColor.backgroundEleva
    /// The single rail corner radius. Below the token grid (`HLRadius.xs` = 6) on
    /// purpose — an 8 pt rail reads cleaner with a tighter 4 pt round; kept as one
    /// named constant so the two call sites can't drift on the literal.
    static let cornerRadius: CGFloat = 4
    /// The canonical rail height.
    static let railHeight: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                Text(inRangeLabel)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Spacer()
                Text(HLNumberFormat.percent(pct))
                    .font(.hlCaption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Self.targetTone(pct: pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(Self.trackTone)
                        .frame(height: Self.railHeight)
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(Self.targetTone(pct: pct))
                        .frame(
                            width: geo.size.width * CGFloat(min(100, max(0, pct))) / 100,
                            height: Self.railHeight
                        )
                }
            }
            .frame(height: Self.railHeight)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// "In range · 90 T" — the header label with the window suffix appended when
    /// a `windowLabel` is set. Keeps the "· <window>" convention the trend chips
    /// and compliance bar already use so every windowed figure reads one way.
    private var inRangeLabel: String {
        let base = String(localized: "In range")
        guard let windowLabel else { return base }
        return "\(base) · \(windowLabel)"
    }

    /// Spoken a11y label — folds the window into the sentence so VoiceOver reads
    /// "84 percent of measurements in range over 90 T" rather than dropping the
    /// window the sighted user now sees.
    private var accessibilityText: String {
        guard let windowLabel else {
            return String(localized: "\(pct) percent of measurements in range")
        }
        return String(localized: "\(pct) percent of measurements in range over \(windowLabel)")
    }

    /// Status tone for the fill + percentage label. ≥80 OK · 50–79 warn · <50 bad
    /// — mirrors `RangeBand.tone` verbatim so BP / RangeBand / primary tile share
    /// one threshold vocabulary.
    static func targetTone(pct: Int) -> Color {
        switch pct {
        case 80...: HLColor.statusOK
        case 50 ..< 80: HLColor.statusWarn
        default: HLColor.statusBad
        }
    }
}
