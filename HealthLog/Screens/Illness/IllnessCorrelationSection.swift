import SwiftUI

/// Renders the server-computed `Derived<T>` correlation for one episode
/// (v1.18.1 §B). Pattern-matches `status`: `ok` renders the findings; anything
/// else (`insufficient`, `nil`, not-deployed) renders no section (1.4 B2).
///
/// **iOS computes NO baseline.** Deviations are the server's signed robust-SD
/// findings; this view just labels + lays them out (neutral). Red flags get an
/// ESCALATING section ("seek care if this recurs") — never reassuring.
struct IllnessCorrelationSection: View {
    /// #115 P2 — a sustained-fever red flag's worst reading, in the account's unit.
    @Environment(\.unitPreferences) private var units
    let correlation: IllnessCorrelationDTO?
    let isLoading: Bool

    /// 1.4 B2 — the section shows while the correlation loads and when it has
    /// a finding; "still learning" with an input count is no card any more.
    private var okValue: IllnessCorrelationValue? {
        guard let correlation, correlation.status == .ok else { return nil }
        return correlation.value
    }

    var body: some View {
        let isLoadingFirst = isLoading && correlation == nil
        if isLoadingFirst || okValue != nil {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // 1.0.3 (1.4.1) — the method behind the recovery gap and the
                // red flags, cited once for the whole section. 1.4 B2: in the
                // section's title row instead of loose under the last card.
                HStack(alignment: .firstTextBaseline) {
                    HLSectionLabel("illness.correlation.title")
                    Spacer(minLength: HLSpace.sm)
                    HLSourcesLink(topic: .illnessRecovery)
                }

                if let value = okValue {
                    okContent(value: value)
                } else {
                    HLCard(style: .ghost) {
                        HStack(spacing: HLSpace.sm) {
                            ProgressView().controlSize(.small)
                            Text("illness.correlation.loading")
                                .font(.hlSubhead)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                }

                // UI-Standard R15 (U1) — die pauschale Fußzeile
                // `illness.correlation.retrospectiveDisclaimer` ist ersatzlos
                // entfallen. Die Aussage „blickt zurück, sagt nichts voraus"
                // trägt genau einmal der Bullet auf dem Opt-in-Screen (R3). Die
                // Red-Flags-Karte (Klasse 4) ist davon unberührt.
            }
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
                HLSectionLabel("illness.correlation.recoveryGap.title")
                Text(recoveryGapText(gap))
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                // 1.4 B2 — one caption line instead of three paragraphs: the
                // metric that settled last (v1.21.0 `gapDriverType`), the day
                // the person felt better, and the neutral sleep observation the
                // server sends alongside the gap (never part of it, withheld on
                // thin data). Render-only, nothing recomputed.
                let details = [
                    gapDriverText(gapDriverType),
                    feltBetterDay.flatMap { day in
                        day.isEmpty ? nil : String(
                            format: String(localized: "illness.correlation.feltBetter"),
                            IllnessDateFormat.mediumDate(day)
                        )
                    },
                    sleepContextText(sleepContext)
                ].compactMap(\.self)
                if !details.isEmpty {
                    Text(details.joined(separator: " "))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func redFlagsCard(_ flags: [IllnessRedFlag]) -> some View {
        // Attention section, `.warning` tone.
        //
        // 1.0.3 (App Review 1.4.1, audit row 14 / ruling R12) — the footer used
        // to read "If this pattern recurs, seek medical care." under headlines
        // like "Sustained fever". That is a triage instruction, and the app
        // cannot support one: the trigger is `!value.redFlags.isEmpty` and
        // nothing more, the flags arrive decoded straight off the wire with no
        // threshold the client can name, and the underlying entries can be
        // free text the user typed. The line now says what it honestly is — a
        // pattern in the user's own recorded values — and points at a
        // conversation with their doctor rather than at care-seeking. The
        // section keeps its warning tone: softening the claim is not the same
        // as making the card reassuring.
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
                HLSectionLabel(titleKey)
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
                HLSectionLabel("illness.correlation.returns.title")
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
        let directionKey = switch dev.direction {
        case .above: "illness.correlation.direction.above"
        case .below: "illness.correlation.direction.below"
        case .unknown: "illness.correlation.direction.unknown"
        }
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
        // #115 P2 — the server's worst value is canonical (°C for a fever run);
        // an imperial account reads it in °F like every other temperature.
        let kind: MetricKind? = flag.type.uppercased().contains("TEMPERATURE") || flag.reason == "sustained_fever"
            ? .bodyTemperature : nil
        let worst = kind.map { units.displayValue(flag.worstValue, kind: $0) } ?? flag.worstValue
        let value = worst.formatted(.number.precision(.fractionLength(0 ... 1)))
        // L10N-3 — count-aware "day(s)" via xcstrings plural substitution (the
        // key carries `%@ %lld` so the days arg drives the one/other variation).
        return String(localized: "illness.correlation.redFlags.detail \(value) \(flag.days)")
    }
}
