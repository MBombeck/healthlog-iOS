import SwiftUI

/// v0.5.5.7 RECONCILE-COMPARE — disclaimer + source sheet for the
/// `ComparisonBand`.
///
/// **Why a dedicated sheet rather than a popover:** the band paints
/// a one-line claim ("Dein Bestwert liegt im typischen Bereich"); WHERE
/// that reference curve comes from deserves a full surface. Tap
/// surfaces this sheet with: per-metric source label, the reference
/// band, and the global provenance line at the full-height `.form`
/// detent per `hlSheetPresentation` contract.
///
/// **UI-Standard R17 + R18 (U1):** das Sheet heißt *Quellen*-Sheet, und
/// genau das trägt es jetzt — „Quelle: CDC / WHO Daten 2020–2024."
/// Der angehängte Pauschalteil („Werte sind Richtwerte, kein
/// medizinischer Befund. Bei Fragen wende dich an deinen Arzt oder deine
/// Ärztin.") ist gefallen; er lebt am Ack-Sheet und in Einstellungen →
/// Über diese App. Gleichzeitig sind die bis dahin hart im `Layout`-Enum
/// kodierten deutschen Literale echte Katalogschlüssel geworden — sie
/// waren `LocalizedStringKey`s ohne Katalogeintrag und rannen damit
/// unübersetzt durch (PROJECT_GUIDE.md: keine hardcodierten UI-Strings).
///
/// **Localization:** every string surfaced here flows through
/// `LocalizedStringKey` + the project `Localizable.xcstrings` so the
/// EN translation can extend without code edits. Source label comes
/// from `ClinicalBenchmark.sourceLabel` (plain-string carrier, also
/// localised at definition site in `LiveClinicalBenchmarkProvider`).
struct BenchmarkSourceSheet: View {
    let metricLabel: String
    let benchmark: ClinicalBenchmark
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.xl) {
                    header
                    sourceCard
                    provenanceCard
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.vertical, HLSpace.xl)
            }
            .hlScreenBackground()
            .navigationTitle(LocalizedStringKey(Layout.navigationTitle))
            .navigationBarTitleDisplayMode(.inline)
            // v0.6.1 Y2 — Home-Compliance pattern: drop the 'Schließen'
            // confirmationAction. Drag-indicator dismisses. `onDismiss`
            // stays on the surface so the host can react to interactive
            // dismissal if needed.
        }
        .hlSheetPresentation(.form)
        .presentationBackground(HLColor.surface)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.hlIcon(HLIconSize.lg))
                    .foregroundStyle(HLAccent.userBrandTint)
                    .accessibilityHidden(true)
                HLSectionLabel(LocalizedStringKey(Layout.eyebrow))
            }
            Text(metricLabel)
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel(LocalizedStringKey(Layout.sourceTitle))
            Text(benchmark.sourceLabel)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            referenceRangeRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.lg)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
    }

    private var referenceRangeRow: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.xs) {
                Text(LocalizedStringKey(Layout.typicalRangeLabel))
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                Text(formattedBand)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
            }
            if let floor = benchmark.clinicalFloor {
                HStack(spacing: HLSpace.xs) {
                    Text(LocalizedStringKey(Layout.clinicalFloorLabel))
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                    Text(format(floor))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                }
            }
            if let ceiling = benchmark.clinicalCeiling {
                HStack(spacing: HLSpace.xs) {
                    Text(LocalizedStringKey(Layout.clinicalCeilingLabel))
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                    Text(format(ceiling))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.top, HLSpace.xs)
    }

    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "info.circle")
                    .font(.hlIcon(HLIconSize.rowAction))
                    .foregroundStyle(HLText.secondary)
                    .accessibilityHidden(true)
                HLSectionLabel(LocalizedStringKey(Layout.provenanceTitle))
            }
            Text(LocalizedStringKey(Layout.provenanceBody))
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.lg)
        .background(HLSurface.tertiary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
    }

    // MARK: - Derived

    private var formattedBand: String {
        "\(format(benchmark.bandLow)) – \(format(benchmark.bandHigh))"
    }

    private func format(_ value: Double) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }()
}

extension BenchmarkSourceSheet {
    /// Katalogschlüssel dieser Fläche. Bis U1 standen hier deutsche Literale,
    /// die als `LocalizedStringKey` durchgereicht wurden — ohne Katalogeintrag
    /// blieben sie in jeder Sprache deutsch.
    enum Layout {
        static let navigationTitle = "benchmark.source.title"
        static let eyebrow = "benchmark.source.eyebrow"
        static let sourceTitle = "benchmark.source.sourceTitle"
        static let typicalRangeLabel = "benchmark.source.typicalRange"
        static let clinicalFloorLabel = "benchmark.source.clinicalFloor"
        static let clinicalCeilingLabel = "benchmark.source.clinicalCeiling"
        static let provenanceTitle = "benchmark.source.provenanceTitle"
        static let provenanceBody = "benchmark.source.provenanceBody"
    }
}

#Preview("BenchmarkSourceSheet — Schritte") {
    BenchmarkSourceSheet(
        metricLabel: "Steps",
        benchmark: ClinicalBenchmark(
            mean: 7500,
            sigma: 3000,
            clinicalFloor: nil,
            clinicalCeiling: nil,
            favorability: .higherIsBetter,
            sourceLabel: "Tudor-Locke et al. 2011 + CDC BRFSS 2019-2023"
        ),
        onDismiss: {}
    )
}
