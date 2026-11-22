import SwiftUI

/// Renders the server-computed `Derived<T>` correlation for one episode
/// (v1.18.1 §B). Pattern-matches `status`: `ok` renders the findings; anything
/// else (`insufficient`, `nil`, not-deployed) renders no section.
///
/// **iOS computes NO baseline.** Deviations are the server's signed robust-SD
/// findings; this view just labels + lays them out (neutral). Red flags get an
/// ESCALATING section ("seek care if this recurs") — never reassuring.
struct IllnessCorrelationSection: View {
    /// A sustained-fever red flag's worst reading, in the account's unit.
    @Environment(\.unitPreferences) private var units
    let correlation: IllnessCorrelationDTO?
    let isLoading: Bool

    /// The section shows while the correlation loads and when it has
    /// a finding; "still learning" with an input count is no card any more.
    private var okValue: IllnessCorrelationValue? {
        guard let correlation, correlation.status == .ok else { return nil }
        return correlation.value
    }

    var body: some View {
        let isLoadingFirst = isLoading && correlation == nil
        if isLoadingFirst || okValue != nil {
            Group {
                // The method behind the recovery gap and the red flags, cited
                // once for the whole section in its header.
                HLSectionHeader("illness.correlation.title", rank: .area) {
                    HLSourcesLink(topic: .illnessRecovery)
                }

                if let value = okValue {
                    okContent(value: value)
                } else {
                    HLCard(style: .outline) {
                        HStack(spacing: HLSpace.sm) {
                            ProgressView().controlSize(.small)
                            Text("illness.correlation.loading")
                                .hlText(.emptyMessage)
                        }
                    }
                }

                // UI-Standard R15 — die pauschale Fußzeile
                // `illness.correlation.retrospectiveDisclaimer` ist ersatzlos
                // entfallen. Die Aussage „blickt zurück, sagt nichts voraus"
                // trägt genau einmal der Bullet auf dem Opt-in-Screen. Die
                // Red-Flags-Karte (Klasse 4) ist davon unberührt.
            }
        }
    }

    // MARK: - OK content

    @ViewBuilder
    private func okContent(value: IllnessCorrelationValue) -> some View {
        if IllnessPresentation.isSettled(value) {
            HLCard(style: .outline) {
                HLEmptyNote("illness.correlation.settled")
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
                HLCardLabel("illness.correlation.recoveryGap.title")
                Text(recoveryGapText(gap))
                    .hlText(.prose)
                    .fixedSize(horizontal: false, vertical: true)
                // One caption line instead of three paragraphs: the
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
                        .hlText(.rowSubtitle)
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
                HLCardLabel("illness.correlation.redFlags.title")
                ForEach(flags) { flag in
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(flag.localizedHeadline)
                            .hlText(.rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(redFlagDetail(flag))
                            .hlText(.rowSubtitle)
                    }
                }
                // The warning stays in the status line, so the card keeps its
                // tone without a coloured head of its own.
                HLBadge(
                    String(localized: "illness.correlation.redFlags.seekCare"),
                    icon: "exclamationmark.triangle",
                    tone: .warning,
                    form: .text
                )
            }
        }
    }

    private func deviationsCard(titleKey: LocalizedStringKey, deviations: [IllnessVitalDeviation]) -> some View {
        HLCard(titleKey, layout: .rows) {
            ForEach(deviations) { dev in
                // The short figure on the right, the day and what it
                // measures in the detail line; a sentence as a value was cut.
                HLRow(
                    title: Text(verbatim: IllnessVitalLabel.label(for: dev.type)),
                    detail: HLRowDetail.text([
                        IllnessDateFormat.mediumDate(dev.day),
                        String(localized: "illness.correlation.deviation.unit")
                    ]),
                    value: Text(verbatim: Self.deviationValue(dev))
                )
            }
        }
    }

    private func returnsCard(_ returns: [IllnessVitalReturn]) -> some View {
        HLCard("illness.correlation.returns.title", layout: .rows) {
            ForEach(returns) { ret in
                HLRow(
                    title: Text(verbatim: IllnessVitalLabel.label(for: ret.type)),
                    detail: Text(verbatim: Self.returnDetail(ret)),
                    value: Self.returnDay(ret).map { Text(verbatim: $0) }
                )
            }
        }
    }

    // MARK: - Copy builders

    private func recoveryGapText(_ gap: Double) -> String {
        let value = HLValueFormat.number(gap, fractionDigits: 0 ... 1)
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
        let hours = HLValueFormat.number(abs(context.deltaMinutes) / 60, fractionDigits: 0 ... 1)
        let key = context.deltaMinutes > 0
            ? "illness.correlation.sleepContext.more"
            : "illness.correlation.sleepContext.less"
        let template = String(localized: String.LocalizationValue(key))
        return String(format: template, hours)
    }

    /// The deviation as a signed figure: above the baseline "+2,2", below
    /// "−2,2", without a direction unsigned.
    nonisolated static func deviationValue(_ dev: IllnessVitalDeviation) -> String {
        let magnitude = HLValueFormat.number(abs(dev.deviationSd), fractionDigits: 0 ... 1)
        return switch dev.direction {
        case .above: "+\(magnitude)"
        case .below: "−\(magnitude)"
        case .unknown: magnitude
        }
    }

    /// The day the vital was back, as the row's value; `nil` while it is not.
    nonisolated static func returnDay(_ ret: IllnessVitalReturn) -> String? {
        guard let day = ret.returnedDay, !day.isEmpty else { return nil }
        return IllnessDateFormat.mediumDate(day)
    }

    /// How long after feeling better it took, or that it is not back yet.
    nonisolated static func returnDetail(_ ret: IllnessVitalReturn) -> String {
        guard let day = ret.returnedDay, !day.isEmpty else {
            return String(localized: "illness.correlation.returns.notYet")
        }
        guard let gap = ret.gapDays else { return "" }
        let template = String(localized: "illness.correlation.returns.after")
        return String(format: template, HLValueFormat.number(gap, fractionDigits: 0 ... 1))
    }

    private func redFlagDetail(_ flag: IllnessRedFlag) -> String {
        // The server's worst value is canonical (°C for a fever run);
        // an imperial account reads it in °F like every other temperature.
        let kind: MetricKind? = flag.type.uppercased().contains("TEMPERATURE") || flag.reason == "sustained_fever"
            ? .bodyTemperature : nil
        let worst = kind.map { units.displayValue(flag.worstValue, kind: $0) } ?? flag.worstValue
        let value = HLValueFormat.number(worst, fractionDigits: 0 ... 1)
        // Count-aware "day(s)" via xcstrings plural substitution (the
        // key carries `%@ %lld` so the days arg drives the one/other variation).
        return String(localized: "illness.correlation.redFlags.detail \(value) \(flag.days)")
    }
}
