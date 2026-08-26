import SwiftUI

/// Sleep debt · chronotype · average-per-night — the three peer cards from
/// `GET /api/sleep/rhythm` (parity Build 4 · item 4.7).
///
/// The web page renders these three side by side off ONE shared cache entry
/// (`insights/sleep/page.tsx`); iOS stacks them, because at 393 pt a three-up
/// grid would shrink each headline below the point where it reads as a
/// headline. Same data, same order, same calm empty states.
///
/// **Every card is server-rendered.** The balance, the band and the mean all
/// arrive computed — iOS chooses layout and copy only. The debt figure in
/// particular must never be recomputed here: the server owns the age-resolved
/// need table and the sub-linear recovery curve, and a second local estimate
/// would contradict the dashboard for the same night.
struct SleepRhythmSection: View {
    let rhythm: SleepRhythmDTO

    var body: some View {
        if !rhythm.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("sleep.rhythm.section")
                VStack(spacing: HLSpace.md) {
                    if let debt = rhythm.sleepDebt {
                        SleepDebtCard(debt: debt)
                    }
                    if let average = rhythm.averagePerNight {
                        AverageSleepCard(average: average)
                    }
                    if let chronotype = rhythm.chronotype {
                        ChronotypeCard(chronotype: chronotype)
                    }
                }
            }
        }
    }
}

// MARK: - Sleep debt

/// The rolling need-minus-got BALANCE, not a running total of every deficit:
/// catch-up sleep pays it down and it floors at zero.
private struct SleepDebtCard: View {
    let debt: SleepDebtDTO

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("sleep.debt.title")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                switch debt.state {
                case .partial:
                    // Below the night floor the card asserts NOTHING. A balance
                    // off two thin nights would be a confident-looking guess.
                    Text("sleep.debt.learning \(debt.nightsCounted) \(debt.nightsUntilReady)")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .ready:
                    Text(headline)
                        .font(.hlMetric(.title2))
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                    Text(caption)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    computedNote
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: String {
        debt.isCaughtUp
            ? String(localized: "sleep.debt.clearValue")
            : String(localized: "sleep.debt.value \(SleepDurationFormat.hoursMinutes(debt.debtMinutes))")
    }

    private var caption: String {
        debt.isCaughtUp
            ? String(localized: "sleep.debt.clearCaption \(debt.windowNights)")
            : String(localized: "sleep.debt.caption \(debt.windowNights)")
    }

    /// Discloses that a `COMPUTED` figure is HealthLog's OWN estimate, so it is
    /// never mistaken for a wearable's native sleep-debt number — those use a
    /// different need model and will legitimately disagree. Suppressed when a
    /// provider supplied the figure directly.
    @ViewBuilder
    private var computedNote: some View {
        if debt.source == nil || debt.source?.uppercased() == "COMPUTED" {
            Text("sleep.debt.computedInfo")
                .font(.hlCaption2)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Average per night

/// Mean asleep minutes over the rhythm window. Its span is deliberately WIDER
/// than the debt card's, so the caption names `nightsCounted` — two honest
/// figures over two spans beat one figure that quietly contradicts the other.
private struct AverageSleepCard: View {
    let average: AverageSleepDTO

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("sleep.average.title")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                switch average.state {
                case .partial:
                    Text("sleep.average.learning \(average.nightsCounted) \(average.nightsUntilReady)")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .ready:
                    Text(SleepDurationFormat.hoursMinutes(average.averageMinutes))
                        .font(.hlMetric(.title2))
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                    Text("sleep.average.caption \(average.nightsCounted)")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Chronotype

/// MCTQ chronotype: the band off the sleep-debt-corrected mid-sleep on free
/// days (MSFsc), plus social jetlag.
///
/// The free-vs-work day type is a documented MODELLING ASSUMPTION — the app
/// has no work calendar, so the server treats weekends as the alarm-free days.
/// The card says so rather than letting a shift worker read their band as
/// measured fact.
private struct ChronotypeCard: View {
    let chronotype: ChronotypeDTO

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("sleep.chronotype.title")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                switch chronotype.state {
                case .learning:
                    Text("sleep.chronotype.learning \(chronotype.freeNightsCounted) \(totalFreeNights)")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .ready:
                    readyBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Free nights seen plus those still wanted — the denominator the
    /// "N of M" learning copy needs, which the wire sends as two halves.
    private var totalFreeNights: Int {
        chronotype.freeNightsCounted + chronotype.freeNightsUntilReady
    }

    @ViewBuilder
    private var readyBody: some View {
        if let band = chronotype.band {
            Text(band.displayKey)
                .font(.hlMetric(.title3))
                .foregroundStyle(HLText.primary)
        }
        if let msf = chronotype.msfMinutes {
            Text("sleep.chronotype.midpointHeadline \(SleepDurationFormat.clockTime(minutesOfDay: msf))")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let jetlag = chronotype.socialJetlagMinutes {
            detailRow(
                value: String(localized: "sleep.chronotype.socialJetlagValue \(SleepDurationFormat.hoursMinutes(jetlag))"),
                caption: "sleep.chronotype.socialJetlagCaption"
            )
        }
        if let msfSc = chronotype.msfScMinutes {
            detailRow(
                value: String(localized: "sleep.chronotype.msfScValue \(SleepDurationFormat.clockTime(minutesOfDay: msfSc))"),
                caption: "sleep.chronotype.msfScCaption"
            )
        }
        Text("sleep.chronotype.dayTypeNote")
            .font(.hlCaption2)
            .foregroundStyle(HLText.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detailRow(value: String, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(value)
                .font(.hlFootnote)
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
            Text(caption)
                .font(.hlCaption2)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, HLSpace.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
