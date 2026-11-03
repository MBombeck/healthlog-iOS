import SwiftUI

/// Sleep debt · chronotype · average-per-night — the three peer cards from
/// `GET /api/sleep/rhythm` (parity Build 4 · item 4.7).
///
/// The web page renders these three side by side off ONE shared cache entry
/// (`insights/sleep/page.tsx`); iOS stacks them, because at 393 pt a three-up
/// grid would shrink each headline below the point where it reads as a
/// headline. Same data, same order, same calm empty states.
///
/// **1.4 B2 — calm by default.** Only ready cards show. While nothing is ready
/// the section is one card with one line ("Dein Schlaf wird noch erfasst …")
/// instead of three cards saying it three times. The citation sits once, in
/// the first ready card that makes a claim (debt, else chronotype); what the
/// figures mean and how they are worked out is in the page's info sheet
/// (`InsightsMetricInfo`).
///
/// **Every card is server-rendered.** The balance, the band and the mean all
/// arrive computed — iOS chooses layout and copy only. The debt figure in
/// particular must never be recomputed here: the server owns the age-resolved
/// need table and the sub-linear recovery curve, and a second local estimate
/// would contradict the dashboard for the same night.
struct SleepRhythmSection: View {
    let rhythm: SleepRhythmDTO

    private var readyDebt: SleepDebtDTO? {
        rhythm.sleepDebt.flatMap { $0.state == .ready ? $0 : nil }
    }

    private var readyAverage: AverageSleepDTO? {
        rhythm.averagePerNight.flatMap { $0.state == .ready ? $0 : nil }
    }

    private var readyChronotype: ChronotypeDTO? {
        rhythm.chronotype.flatMap { $0.state == .ready ? $0 : nil }
    }

    /// The one "still learning" line while no card is ready, most telling
    /// first: the debt balance, then the average, then the chronotype.
    private var learningLine: LocalizedStringKey? {
        if let debt = rhythm.sleepDebt, debt.state == .partial {
            return "sleep.debt.learning \(debt.nightsCounted) \(debt.nightsUntilReady)"
        }
        if let average = rhythm.averagePerNight, average.state == .partial {
            return "sleep.average.learning \(average.nightsCounted) \(average.nightsUntilReady)"
        }
        if let chronotype = rhythm.chronotype, chronotype.state == .learning {
            let total = chronotype.freeNightsCounted + chronotype.freeNightsUntilReady
            return "sleep.chronotype.learning \(chronotype.freeNightsCounted) \(total)"
        }
        return nil
    }

    var body: some View {
        let anyReady = readyDebt != nil || readyAverage != nil || readyChronotype != nil
        if anyReady || learningLine != nil {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("sleep.rhythm.section")
                VStack(spacing: HLSpace.md) {
                    if anyReady {
                        if let debt = readyDebt {
                            SleepDebtCard(debt: debt)
                        }
                        if let average = readyAverage {
                            AverageSleepCard(average: average)
                        }
                        if let chronotype = readyChronotype {
                            ChronotypeCard(chronotype: chronotype, citesSources: readyDebt == nil)
                        }
                    } else if let learningLine {
                        HLCard {
                            Text(learningLine)
                                .font(.hlFootnote)
                                .foregroundStyle(HLText.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("sleep.rhythm.learning")
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
                // Below the night floor the section shows its one learning
                // line instead: a balance off two thin nights would be a
                // confident-looking guess.
                Text(headline)
                    .font(.hlMetric(.title2))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                Text(caption)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 1.0.3 (App Review 1.4.1) — the sleep-need and social-jetlag
                // literature behind the balance. That the figure is HealthLog's
                // own estimate (`sleep.debt.computedInfo`) is the first section
                // of the page's info sheet, directly above these references.
                HLSourcesLink(topic: .sleepRhythm)
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
                Text(SleepDurationFormat.hoursMinutes(average.averageMinutes))
                    .font(.hlMetric(.title2))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                Text("sleep.average.caption \(average.nightsCounted)")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    /// The section cites once: here only when no debt card above does.
    let citesSources: Bool

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("sleep.chronotype.title")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                readyBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        // 1.4 B2 — the values stay, their explanations (social jetlag, the
        // weekend correction, weekends as free days) are in the info sheet.
        if let jetlag = chronotype.socialJetlagMinutes {
            detailRow(String(localized: "sleep.chronotype.socialJetlagValue \(SleepDurationFormat.hoursMinutes(jetlag))"))
        }
        if let msfSc = chronotype.msfScMinutes {
            detailRow(String(localized: "sleep.chronotype.msfScValue \(SleepDurationFormat.clockTime(minutesOfDay: msfSc))"))
        }
        // 1.0.3 (App Review 1.4.1) — MCTQ / social-jetlag / SRI literature
        // behind the band and the midpoint, once per section.
        if citesSources {
            HLSourcesLink(topic: .sleepRhythm)
        }
    }

    private func detailRow(_ value: String) -> some View {
        Text(value)
            .font(.hlFootnote)
            .foregroundStyle(HLText.primary)
            .monospacedDigit()
            .padding(.top, HLSpace.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
