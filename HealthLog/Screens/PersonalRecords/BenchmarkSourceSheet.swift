import SwiftUI

/// Disclaimer + source sheet for the
/// `ComparisonBand`.
///
/// **Why a dedicated sheet rather than a popover:** the band paints
/// a one-line claim ("Dein Bestwert liegt im typischen Bereich"); WHERE
/// that reference curve comes from deserves a full surface. Tap
/// surfaces this sheet with: per-metric source label, the reference
/// band, and the global provenance line at the full-height `.form`
/// detent per `hlSheetPresentation` contract.
///
/// **UI-Standard R17 + R18:** das Sheet heißt *Quellen*-Sheet, und
/// genau das trägt es jetzt — „Quelle: CDC / WHO Daten 2020–2024."
/// Der angehängte Pauschalteil („Werte sind Richtwerte, kein
/// medizinischer Befund. Bei Fragen wende dich an deinen Arzt oder deine
/// Ärztin.") ist gefallen; er lebt am Ack-Sheet und in Einstellungen →
/// Über diese App. Gleichzeitig sind die bis dahin hart im `Layout`-Enum
/// kodierten deutschen Literale echte Katalogschlüssel geworden — sie
/// waren `LocalizedStringKey`s ohne Katalogeintrag und rannen damit
/// unübersetzt durch (PROJECT_GUIDE.md: keine hardcodierten UI-Strings).
///
/// **1.0.3 (App Review 1.4.1):** die Pauschalzeile „Quelle: CDC / WHO Daten
/// 2020–2024" war eine Behauptung ohne Beleg. Sie ist durch die benannten
/// Referenzen aus ``MedicalSourceCatalog`` ersetzt (`.personalRecords(kind)`),
/// jede als Safari-`Link` über ``HLSourceRow``. Das Quellenlabel der Kurve
/// selbst kommt jetzt aus `benchmark.sourceLabel.<kind>` (de + en) statt aus
/// einem deutschen Literal im Provider.
///
/// **Localization:** every string surfaced here flows through
/// `LocalizedStringKey` + the project `Localizable.xcstrings` so the
/// EN translation can extend without code edits. The source label
/// and the band are the server's (`benchmark.sourceLabel`, already in the
/// account's language; `low` and `high` in the record's unit).
struct BenchmarkSourceSheet: View {
    let metricLabel: String
    /// 1.0.3 (App Review 1.4.1) — which metric's references to cite.
    let kind: MetricKind
    let band: RecordBenchmarkBand
    let onDismiss: () -> Void

    private var sources: [MedicalSource] {
        MedicalSourceCatalog.sources(for: .personalRecords(kind))
    }

    var body: some View {
        // A sheet that only shows something: the close button, nothing to
        // confirm. `onDismiss` stays on the surface so the host can react.
        HLSheetScaffold(LocalizedStringKey(Layout.navigationTitle)) {
            HLPage {
                header
                sourceCard
                if !sources.isEmpty {
                    referencesCard
                }
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.hlIcon(HLIconSize.lg))
                    .foregroundStyle(HLAccent.userBrandTint)
                    .accessibilityHidden(true)
                HLCardLabel(LocalizedStringKey(Layout.eyebrow))
            }
            Text(metricLabel)
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
        }
    }

    private var sourceCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLCardLabel(LocalizedStringKey(Layout.sourceTitle))
                Text(band.sourceLabel)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                referenceRangeRow
            }
        }
    }

    private var referenceRangeRow: some View {
        HStack(spacing: HLSpace.xs) {
            Text(LocalizedStringKey(Layout.typicalRangeLabel))
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            Text(band.formattedRange)
                .font(.hlCaption)
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
        }
        .padding(.top, HLSpace.xs)
    }

    /// 1.0.3 (App Review 1.4.1) — the named references themselves, each a
    /// Safari `Link` (A360-3), rendered with the shared ``HLSourceRow``.
    private var referencesCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "text.book.closed")
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(HLText.secondary)
                        .accessibilityHidden(true)
                    HLCardLabel("sources.sheet.referencesTitle")
                }
                ForEach(sources) { source in
                    HLSourceRow(name: source.name, year: source.year, caveatKey: source.caveatKey, url: source.url)
                }
            }
        }
        .accessibilityIdentifier("benchmark.source.references")
    }
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
    }
}

#Preview("BenchmarkSourceSheet — VO2 max") {
    BenchmarkSourceSheet(
        metricLabel: "VO₂ max",
        kind: .vo2Max,
        band: RecordBenchmarkBand(low: 35, high: 43, value: 41, unit: "ml/kg/min", sourceLabel: "ACSM, 11th edition"),
        onDismiss: {}
    )
}
