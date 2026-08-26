import SwiftUI

/// Per-nutrient detail (Build 7.6, GH #48): the dense day-series
/// (`GET /api/nutrients/daily`) plus the server-resolved EFSA reference and the
/// latest day's progress against it. The reference + its sex-resolution are the
/// server's (`null` when the profile sex is unknown → the reference line hides);
/// this view never resolves a reference itself.
struct NutrientDetailScreen: View {
    let code: NutrientCode
    let store: NutrientStore

    var body: some View {
        List {
            if let series = store.dailyByCode[code] {
                referenceSection(series)
                daysSection(series)
            } else if store.loadingDaily.contains(code) {
                Section { HLAsyncListSkeletonRows() }
            } else {
                Section {
                    HLEmptyState(
                        icon: "leaf",
                        title: "nutrients.detail.empty.title",
                        message: "nutrients.detail.empty.subtitle"
                    )
                }
            }
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.loadingDaily.contains(code))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NutrientDisplay.name(for: code)))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadDaily(code) }
        .refreshable { await store.loadDaily(code) }
    }

    // MARK: - Reference + progress

    @ViewBuilder
    private func referenceSection(_ series: NutrientDailySeriesDTO) -> some View {
        let latest = series.latestNonEmptyDay
        Section(header: Text("nutrients.detail.section.today")) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(NutrientDisplay.formatted(amount: latest?.amount ?? 0, wireUnit: series.unit))
                    .font(.hlTitle2)
                    .foregroundStyle(HLText.primary)

                if let reference = series.reference {
                    referenceProgress(amount: latest?.amount ?? 0, reference: reference, unit: series.unit)
                } else {
                    // Honest to the server contract: no sex on file → no reference.
                    Text("nutrients.detail.reference.unknown")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            }
            .padding(.vertical, HLSpace.xxs)
        }
    }

    @ViewBuilder
    private func referenceProgress(
        amount: Double,
        reference: NutrientReferenceDTO,
        unit: String
    ) -> some View {
        let fraction = NutrientDisplay.progressFraction(amount: amount, reference: reference.value)
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            ProgressView(value: min(fraction ?? 0, 1))
                .tint(reference.direction == .upperGuidance ? HLColor.statusWarn : HLColor.statusOK)
                .accessibilityIdentifier("nutrients.detail.progress")
            HStack {
                Text(referenceHeadline(reference))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Text(NutrientDisplay.formatted(amount: reference.value, wireUnit: unit))
                    .font(.hlCaption.monospacedDigit())
                    .foregroundStyle(HLText.tertiary)
            }
            Text(reference.source)
                .font(.hlCaption2)
                .foregroundStyle(HLText.tertiary)
        }
    }

    /// "Referenzwert (PRI)" / "Zufuhrziel (AI)" / "Obergrenze" prose per kind +
    /// direction.
    private func referenceHeadline(_ reference: NutrientReferenceDTO) -> String {
        let kindKey = switch reference.kind {
        case .pri: "nutrients.reference.kind.pri"
        case .ai: "nutrients.reference.kind.ai"
        case .safeLevel: "nutrients.reference.kind.safeLevel"
        }
        let directionKey = reference.direction == .upperGuidance
            ? "nutrients.reference.direction.upper"
            : "nutrients.reference.direction.target"
        let kind = String(localized: String.LocalizationValue(kindKey))
        let direction = String(localized: String.LocalizationValue(directionKey))
        return "\(direction) (\(kind))"
    }

    // MARK: - Day series

    @ViewBuilder
    private func daysSection(_ series: NutrientDailySeriesDTO) -> some View {
        // Reverse-chronological, most recent first; a day with no data reads 0.
        let ordered = series.days.sorted { $0.day > $1.day }
        Section(header: Text("nutrients.detail.section.history")) {
            ForEach(ordered) { point in
                HStack {
                    Text(point.day)
                        .font(.hlBody.monospacedDigit())
                        .foregroundStyle(point.amount > 0 ? HLText.primary : HLText.tertiary)
                    Spacer(minLength: HLSpace.sm)
                    Text(NutrientDisplay.formatted(amount: point.amount, wireUnit: series.unit))
                        .font(.hlBody.monospacedDigit())
                        .foregroundStyle(point.amount > 0 ? HLText.secondary : HLText.tertiary)
                }
            }
        }
    }
}
