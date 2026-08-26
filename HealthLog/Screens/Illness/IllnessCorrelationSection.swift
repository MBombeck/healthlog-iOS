import SwiftUI

/// Renders the server-computed `Derived<T>` correlation for one episode
/// (v1.18.1 §B). Pattern-matches `status`: `ok` → render the findings; anything
/// else (`insufficient`, `nil`, not-deployed) → a calm "still learning" state.
///
/// **iOS computes NO baseline.** Deviations are the server's signed robust-SD
/// findings; this view just labels + lays them out (neutral). Red flags get an
/// ESCALATING section ("seek care if this recurs") — never reassuring.
struct IllnessCorrelationSection: View {
    let correlation: IllnessCorrelationDTO?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text("illness.correlation.title")
                .font(.hlFootnote.weight(.semibold))
                .foregroundStyle(HLText.secondary)

            if isLoading, correlation == nil {
                HLCard(style: .ghost) {
                    HStack(spacing: HLSpace.sm) {
                        ProgressView().controlSize(.small)
                        Text("illness.correlation.loading")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            } else if let correlation, correlation.status == .ok, let value = correlation.value {
                okContent(value: value)
            } else {
                insufficientContent(correlation: correlation)
            }

            // UI-Standard R15 (U1) — die pauschale Fußzeile
            // `illness.correlation.retrospectiveDisclaimer` ist ersatzlos
            // entfallen. Die Aussage „blickt zurück, sagt nichts voraus" trägt
            // jetzt genau einmal der Bullet auf dem Opt-in-Screen (R3), an dem
            // der Nutzer über das Modul entscheidet. Die Red-Flags-Karte
            // („suche ärztliche Hilfe", Klasse 4) ist davon unberührt.
        }
    }

    // MARK: - OK content

    @ViewBuilder
    private func okContent(value: IllnessCorrelationValue) -> some View {
        if IllnessPresentation.isSettled(value) {
            HLCard(style: .ghost) {
                Text("illness.correlation.settled")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if let gap = value.recoveryGapDays {
                recoveryGapCard(
                    gap: gap,
                    feltBetterDay: value.feltBetterDay,
                    gapDriverType: value.gapDriverType,
                    sleepContext: value.sleepContext
                )
            }
            if !value.redFlags.isEmpty {
                redFlagsCard(value.redFlags)
            }
            if !value.preOnset.isEmpty {
                deviationsCard(titleKey: "illness.correlation.preOnset", deviations: value.preOnset)
            }
            if !value.nadir.isEmpty {
                deviationsCard(titleKey: "illness.correlation.nadir", deviations: value.nadir)
            }
            if !value.returns.isEmpty {
                returnsCard(value.returns)
            }
        }
    }

    private func recoveryGapCard(
        gap: Double,
        feltBetterDay: String?,
        gapDriverType: String?,
        sleepContext: IllnessSleepContext?
    ) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("illness.correlation.recoveryGap.title")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                Text(recoveryGapText(gap))
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                // v1.21.0: name the metric whose physiological return dominated
                // the gap (server's `gapDriverType`). Render-only — no recompute.
                if let driver = gapDriverText(gapDriverType) {
                    Text(driver)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let day = feltBetterDay, !day.isEmpty {
                    let template = String(localized: "illness.correlation.feltBetter")
                    Text(String(format: template, IllnessDateFormat.mediumDate(day)))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                // v1.21.0: a neutral sleep observation surfaced ALONGSIDE the gap
                // — never part of it. Withheld by the server on thin data.
                if let sleep = sleepContextText(sleepContext) {
                    Text(sleep)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func redFlagsCard(_ flags: [IllnessRedFlag]) -> some View {
        // Escalating section. The badge tone is `.warning` (attention) — the
        // copy itself escalates ("seek care if this recurs"). Not reassuring.
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(HLColor.statusWarn)
                        .accessibilityHidden(true)
                    Text("illness.correlation.redFlags.title")
                        .font(.hlFootnote.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                }
                ForEach(flags) { flag in
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(flag.localizedHeadline)
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(redFlagDetail(flag))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
                Text("illness.correlation.redFlags.seekCare")
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLColor.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviationsCard(titleKey: LocalizedStringKey, deviations: [IllnessVitalDeviation]) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(titleKey)
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                ForEach(deviations) { dev in
                    HStack {
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            Text(IllnessVitalLabel.label(for: dev.type))
                                .font(.hlSubhead)
                                .foregroundStyle(HLText.primary)
                            Text(IllnessDateFormat.mediumDate(dev.day))
                                .font(.hlCaption)
                                .foregroundStyle(HLText.tertiary)
                        }
                        Spacer()
                        Text(deviationText(dev))
                            .font(.hlSubhead.monospacedDigit())
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
    }

    private func returnsCard(_ returns: [IllnessVitalReturn]) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("illness.correlation.returns.title")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                ForEach(returns) { ret in
                    HStack {
                        Text(IllnessVitalLabel.label(for: ret.type))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                        Spacer()
                        Text(returnText(ret))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Insufficient content

    private func insufficientContent(correlation: IllnessCorrelationDTO?) -> some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: "hourglass")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.tertiary)
                        .accessibilityHidden(true)
                    Text("illness.correlation.insufficient.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.secondary)
                }
                Text(insufficientBody(correlation: correlation))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let coverage = correlation?.coverage, coverage.requiredInputs > 0 {
                    let template = String(localized: "illness.correlation.coverage")
                    Text(String(format: template, coverage.presentInputs, coverage.requiredInputs))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            }
        }
    }

    // MARK: - Copy builders

    private func recoveryGapText(_ gap: Double) -> String {
        let value = gap.formatted(.number.precision(.fractionLength(0 ... 1)))
        let template = String(localized: "illness.correlation.recoveryGap.value")
        return String(format: template, value)
    }

    /// "…before your resting heart rate settled." — names the server's
    /// `gapDriverType`. Returns `nil` (no caption) when the server withheld a
    /// driver. Render-only; the label is resolved via ``IllnessVitalLabel``.
    private func gapDriverText(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        // The symptom-burden track reads naturally on its own ("Your logged
        // symptoms were the last to ease") rather than slotted into the
        // vital template — mirrors the web's dedicated symptom phrasing.
        if type.uppercased() == "FUNCTIONAL_IMPACT" {
            return String(localized: "illness.correlation.recoveryGap.driver.symptom")
        }
        let template = String(localized: "illness.correlation.recoveryGap.driver")
        return String(format: template, IllnessVitalLabel.label(for: type))
    }

    /// A neutral sleep observation (more / less than usual). Returns `nil` when
    /// the server withheld it. The signed delta direction picks the phrasing;
    /// the magnitude is shown in whole hours (mirrors the web).
    private func sleepContextText(_ context: IllnessSleepContext?) -> String? {
        guard let context, context.deltaMinutes != 0 else { return nil }
        let hours = (abs(context.deltaMinutes) / 60).formatted(.number.precision(.fractionLength(0 ... 1)))
        let key = context.deltaMinutes > 0
            ? "illness.correlation.sleepContext.more"
            : "illness.correlation.sleepContext.less"
        let template = String(localized: String.LocalizationValue(key))
        return String(format: template, hours)
    }

    private func deviationText(_ dev: IllnessVitalDeviation) -> String {
        let sd = abs(dev.deviationSd).formatted(.number.precision(.fractionLength(0 ... 1)))
        let directionKey = dev.direction == .above
            ? "illness.correlation.direction.above"
            : "illness.correlation.direction.below"
        let direction = String(localized: String.LocalizationValue(directionKey))
        let template = String(localized: "illness.correlation.deviation.value")
        return String(format: template, sd, direction)
    }

    private func returnText(_ ret: IllnessVitalReturn) -> String {
        guard let day = ret.returnedDay, !day.isEmpty else {
            return String(localized: "illness.correlation.returns.notYet")
        }
        let dayLabel = IllnessDateFormat.mediumDate(day)
        guard let gap = ret.gapDays else {
            return dayLabel
        }
        let gapValue = gap.formatted(.number.precision(.fractionLength(0 ... 1)))
        let template = String(localized: "illness.correlation.returns.value")
        return String(format: template, dayLabel, gapValue)
    }

    private func redFlagDetail(_ flag: IllnessRedFlag) -> String {
        let value = flag.worstValue.formatted(.number.precision(.fractionLength(0 ... 1)))
        // L10N-3 — count-aware "day(s)" via xcstrings plural substitution (the
        // key carries `%@ %lld` so the days arg drives the one/other variation).
        return String(localized: "illness.correlation.redFlags.detail \(value) \(flag.days)")
    }

    private func insufficientBody(correlation: IllnessCorrelationDTO?) -> String {
        if let reason = correlation?.reason, !reason.isEmpty {
            return reason
        }
        return String(localized: "illness.correlation.insufficient.body")
    }
}
