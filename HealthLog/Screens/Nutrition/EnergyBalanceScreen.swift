import SwiftUI

/// The energy balance's row in the Ernährung list: the headline per day and
/// what it averages, opening ``EnergyBalanceScreen``. A failed read keeps a
/// quiet row with a retry; a hidden one (module off, older server, no intake
/// yet) shows nothing.
struct EnergyBalanceSection: View {
    let model: EnergyBalanceModel

    var body: some View {
        switch model.state {
        case let .loaded(balance):
            Section {
                HLRow(
                    title: Text("nutrients.energyBalance.title"),
                    detail: Text(verbatim: EnergyBalanceFormat.rowDetail(balance)),
                    value: balance.headlineKcal.map { Text(verbatim: EnergyBalanceFormat.signedKcal($0)) }
                )
                .hlRowLink(inList: true) {
                    EnergyBalanceScreen(model: model)
                }
                .accessibilityIdentifier("nutrients.energyBalance.row")
            }
        case .failed:
            Section {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLEmptyNote("nutrients.energyBalance.loadError")
                    HLButton(HLControlWord.retry.key, variant: .secondary) {
                        Task { await model.reload() }
                    }
                    .accessibilityIdentifier("nutrients.energyBalance.retry")
                }
                .padding(.vertical, HLSpace.xs)
            } header: {
                HLSectionHeader("nutrients.energyBalance.title")
            }
        case .idle, .hidden:
            EmptyView()
        }
    }
}

/// The energy balance page (server 1.49.0, web `EnergyBalanceCard`): what was
/// eaten against resting plus active energy. The headline is the latest
/// seven-day trend, else the window's mean; under it the last complete days,
/// newest first, and today while it runs, outside the trend. A day without a
/// balance is left out, never shown as zero. A resting figure the server
/// estimated from the profile is marked on its day and named once below.
struct EnergyBalanceScreen: View {
    let model: EnergyBalanceModel

    var body: some View {
        HLPage {
            if case let .loaded(balance) = model.state {
                headline(balance)
                daysSection(balance)
            } else {
                HLEmptyState(icon: "scalemass", title: "nutrients.energyBalance.title")
            }
        }
        .navigationTitle(Text("nutrients.energyBalance.title"))
        .navigationBarTitleDisplayMode(.inline)
        .hlRefresh(in: .scrollView) {
            await model.reload()
        }
    }

    private func headline(_ balance: EnergyBalanceDTO) -> some View {
        HLCard {
            if let value = balance.headlineKcal {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("nutrients.energyBalance.perDay \(EnergyBalanceFormat.signedKcal(value))")
                        .hlText(.heroValue)
                        .accessibilityIdentifier("nutrients.energyBalance.headline")
                    Text(verbatim: EnergyBalanceFormat.headlineMeta(balance))
                        .hlText(.note)
                    if let means = EnergyBalanceFormat.means(balance) {
                        Text(verbatim: means)
                            .hlText(.note)
                    }
                }
            } else if let reason = balance.missingReason {
                HLEmptyNote(verbatim: EnergyBalanceFormat.missing(reason))
                    .accessibilityIdentifier("nutrients.energyBalance.missing")
            }
        }
    }

    @ViewBuilder
    private func daysSection(_ balance: EnergyBalanceDTO) -> some View {
        let listed = balance.listedDays()
        let running = balance.runningDay.flatMap { $0.balanceKcal == nil ? nil : $0 }
        if running != nil || !listed.isEmpty {
            HLSectionHeader("nutrients.energyBalance.section.days", rank: .area)
            HLCard(layout: .rows) {
                if let running {
                    dayRow(running)
                }
                ForEach(listed) { day in
                    dayRow(day)
                }
            }
            if let note = EnergyBalanceFormat.estimatedNote(balance) {
                Text(verbatim: note)
                    .hlText(.footnote)
                    .accessibilityIdentifier("nutrients.energyBalance.estimated")
            }
        }
    }

    private func dayRow(_ day: EnergyBalanceDTO.Day) -> some View {
        HLHistoryRow(
            date: Text(verbatim: EnergyBalanceFormat.dayTitle(day)),
            detail: EnergyBalanceFormat.dayLine(day).map { Text(verbatim: $0) },
            value: Text(verbatim: day.balanceKcal.map(EnergyBalanceFormat.signedKcal) ?? ""),
            status: Self.status(for: day)
        )
        .accessibilityIdentifier("nutrients.energyBalance.day.\(day.day)")
    }

    /// Today runs and stays out of the trend; an estimated resting figure
    /// says so on its day.
    nonisolated static func status(for day: EnergyBalanceDTO.Day) -> HLRowStatus? {
        if day.partial { return HLRowStatus(String(localized: "nutrients.energyBalance.running")) }
        if day.restingEstimated { return HLRowStatus(String(localized: "nutrients.energyBalance.restingEstimated")) }
        return nil
    }
}
