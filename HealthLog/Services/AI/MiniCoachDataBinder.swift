import Foundation

/// Pre-fetched data binder for the Mini-Coach (C1).
///
/// The Mini-Coach prompt **never** contains free-form notes — only
/// numeric features and counts. The binder takes whatever measurements
/// + mood entries the caller already has on hand and renders a compact,
/// model-friendly digest for the current question.
///
/// Why a separate file? Two reasons:
///   1. The digest format is the **only** PII surface in the prompt;
///      isolating it makes audit-by-eye trivial.
///   2. The classifier picks a category (data-lookup / period-summary /
///      historic-lookup / comparison) and the binder picks the matching
///      slice — keeping the two concerns separate prevents the prompt
///      builder from ballooning into a giant `switch`.
///
/// The binder is a value-type (`struct`) — no shared mutable state, no
/// actor isolation. Each call is independent. The locale is captured at
/// the call site so the digest header words match the prompt language.
struct MiniCoachDataBinder {
    let locale: Locale

    /// The default is the interface language, so a binder built without an
    /// explicit locale speaks the same language as the prompt around it.
    init(locale: Locale = AppLanguage.current.locale) {
        self.locale = locale
    }

    /// Build the bound-data string for a single turn. Returns a
    /// short, plain-text block the prompt builder can embed verbatim.
    ///
    /// - Parameters:
    ///   - category: classifier verdict — controls the slice strategy.
    ///   - measurements: caller-supplied measurements. The binder does
    ///     **not** fan out network requests; it works only on the
    ///     pre-fetched array. Empty is OK.
    ///   - moods: caller-supplied mood entries. Empty is OK.
    ///   - now: clock for "this week" / "last 7 days" windows. Injected
    ///     so tests can pin a date.
    func bind(
        category: MiniCoachPrompt.AllowedCategory,
        measurements: [Measurement],
        moods: [MoodEntry],
        now: Date = Date()
    ) -> String {
        let language = AppLanguage.resolve(locale)
        if measurements.isEmpty, moods.isEmpty {
            return language.pick(
                de: "(keine Messungen oder Stimmungseinträge im Zeitfenster verfügbar)",
                en: "(no measurements or mood entries available in the window)",
                nl: "(geen metingen of stemmingsregistraties beschikbaar in het tijdvenster)",
                ko: "(기간 안에 측정값이나 기분 기록이 없음)"
            )
        }

        switch category {
        case .dataLookup:
            return renderLatestPerKind(measurements: measurements, moods: moods, language: language)
        case .periodSummary:
            return renderLastSevenDays(measurements: measurements, moods: moods, now: now, language: language)
        case .historicLookup:
            return renderHistoricRange(measurements: measurements, moods: moods, now: now, language: language)
        case .comparison:
            return renderTwoWeekDiff(measurements: measurements, moods: moods, now: now, language: language)
        }
    }

    // MARK: - Slice strategies

    /// data-lookup → latest reading per metric kind + latest mood
    /// score.
    private func renderLatestPerKind(
        measurements: [Measurement],
        moods: [MoodEntry],
        language: AppLanguage
    ) -> String {
        var lines: [String] = []
        let grouped = Dictionary(grouping: measurements, by: \.kind)
        // Audit B-4 — `selectableCases`, not `allCases`: the coach must not be
        // handed a reading whose type this build cannot name. HK-NEW (1.5):
        // nor one the server keeps off every model (`isModelFenced`).
        for kind in MetricKind.coachCases {
            guard let latest = grouped[kind]?.max(by: { $0.recordedAt < $1.recordedAt }) else { continue }
            lines.append(format(measurement: latest, language: language))
        }
        // Audit B-4 — the line states a level out of five, so it reads the
        // latest NAMEABLE entry; the coach is handed no mood line at all when
        // this build can name none.
        if let latestMood = MoodEntry.scored(moods).max(by: { $0.entry.recordedAt < $1.entry.recordedAt }) {
            let header = moodLabel(language)
            lines.append("\(header): \(latestMood.score)/5")
        }
        let count = measurements.count
        let header = language.pick(
            de: "Letzter Wert je Metrik (\(count) Messungen insgesamt):",
            en: "Latest reading per metric (\(count) total measurements):",
            nl: "Laatste waarde per meting (\(count) metingen in totaal):",
            ko: "지표별 최근 값(전체 측정 \(count)건):"
        )
        return header + "\n" + lines.joined(separator: "\n")
    }

    /// period-summary → counts + min/max/avg per kind over the last 7 days.
    private func renderLastSevenDays(
        measurements: [Measurement],
        moods: [MoodEntry],
        now: Date,
        language: AppLanguage
    ) -> String {
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let window = measurements.filter { $0.recordedAt >= cutoff }
        let moodWindow = moods.filter { $0.recordedAt >= cutoff }
        let header = language.pick(
            de: "Zeitraum: letzte 7 Tage (\(window.count) Messungen, \(moodWindow.count) Stimmungseinträge)",
            en: "Window: last 7 days (\(window.count) measurements, \(moodWindow.count) mood entries)",
            nl: "Periode: laatste 7 dagen (\(window.count) metingen, \(moodWindow.count) stemmingsregistraties)",
            ko: "기간: 최근 7일(측정 \(window.count)건, 기분 기록 \(moodWindow.count)건)"
        )
        var lines: [String] = [header]
        let grouped = Dictionary(grouping: window, by: \.kind)
        // Audit B-4 — `selectableCases`, not `allCases`: the coach must not be
        // handed a reading whose type this build cannot name. HK-NEW (1.5):
        // nor one the server keeps off every model (`isModelFenced`).
        for kind in MetricKind.coachCases {
            guard let group = grouped[kind], !group.isEmpty else { continue }
            lines.append(summarise(kind: kind, group: group, language: language))
        }
        if !moodWindow.isEmpty {
            // Audit B-4 — min / max / avg over nameable levels only.
            let scores = MoodEntry.scored(moodWindow).map(\.score)
            if let minScore = scores.min(), let maxScore = scores.max() {
                let avg = Double(scores.reduce(0, +)) / Double(scores.count)
                let label = moodLabel(language)
                let row = language.pick(
                    de: "%@: min %d, max %d, avg %.1f",
                    en: "%@: min %d, max %d, avg %.1f",
                    nl: "%@: min %d, max %d, avg %.1f",
                    ko: "%@: 최소 %d, 최대 %d, 평균 %.1f"
                )
                lines.append(String(format: row, label, minScore, maxScore, avg))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// historic-lookup → first + last + count in the whole binder window.
    /// We don't try to parse the user's date phrase — the model gets the
    /// whole window and picks. The binder just bounds the digest size.
    private func renderHistoricRange(
        measurements: [Measurement],
        moods: [MoodEntry],
        now _: Date,
        language: AppLanguage
    ) -> String {
        let sorted = measurements.sorted(by: { $0.recordedAt < $1.recordedAt })
        guard let first = sorted.first, let last = sorted.last else {
            return language.pick(
                de: "(keine Messungen im Zeitfenster)",
                en: "(no measurements in window)",
                nl: "(geen metingen in het tijdvenster)",
                ko: "(기간 안에 측정값 없음)"
            )
        }
        let header = language.pick(
            de: "Verlaufsfenster: \(sorted.count) Messungen zwischen erstem und letztem Eintrag",
            en: "History window: \(sorted.count) measurements between earliest and latest entry",
            nl: "Verloopvenster: \(sorted.count) metingen tussen eerste en laatste registratie",
            ko: "기록 기간: 첫 기록과 마지막 기록 사이 측정 \(sorted.count)건"
        )
        var lines = [header]
        let earliest = language.pick(de: "frühester Eintrag: ", en: "earliest: ", nl: "eerste registratie: ", ko: "첫 기록: ")
        let latest = language.pick(de: "letzter Eintrag: ", en: "latest: ", nl: "laatste registratie: ", ko: "마지막 기록: ")
        lines.append(earliest + format(measurement: first, language: language))
        lines.append(latest + format(measurement: last, language: language))
        if !moods.isEmpty {
            let moodCount = language.pick(
                de: "Stimmungseinträge im Fenster: ",
                en: "mood entries in window: ",
                nl: "stemmingsregistraties in het tijdvenster: ",
                ko: "기간 안의 기분 기록 수: "
            )
            lines.append(moodCount + String(moods.count))
        }
        return lines.joined(separator: "\n")
    }

    /// comparison → last 7 days vs. preceding 7 days, per kind.
    private func renderTwoWeekDiff(
        measurements: [Measurement],
        moods: [MoodEntry],
        now: Date,
        language: AppLanguage
    ) -> String {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 3600)
        let recent = measurements.filter { $0.recordedAt >= weekAgo }
        let prior = measurements.filter { $0.recordedAt >= twoWeeksAgo && $0.recordedAt < weekAgo }
        let header = language.pick(
            de: "Vergleich: letzte 7 Tage (jetzt, \(recent.count) Messungen) vs. vorletzte 7 Tage (davor, \(prior.count) Messungen)",
            en: "Comparison: last 7 days (recent, \(recent.count) measurements) vs. previous 7 days (prior, \(prior.count) measurements)",
            nl: "Vergelijking: laatste 7 dagen (nu, \(recent.count) metingen) vs. de 7 dagen daarvoor (daarvoor, \(prior.count) metingen)",
            ko: "비교: 최근 7일(최근, 측정 \(recent.count)건)과 그 전 7일(이전, 측정 \(prior.count)건)"
        )
        // The row words echo the header's labels; the English rows used to
        // carry the German "jetzt" / "davor" under an English header.
        let nowWord = language.pick(de: "jetzt", en: "recent", nl: "nu", ko: "최근")
        let priorWord = language.pick(de: "davor", en: "prior", nl: "daarvoor", ko: "이전")
        // Korean counts with a counter word ("최근 1건, 이전 0건").
        let counter = language.pick(de: "", en: "", nl: "", ko: "건")
        var lines: [String] = [header]
        let recentGrouped = Dictionary(grouping: recent, by: \.kind)
        let priorGrouped = Dictionary(grouping: prior, by: \.kind)
        // Audit B-4 — `selectableCases`, not `allCases`: the coach must not be
        // handed a reading whose type this build cannot name. HK-NEW (1.5):
        // nor one the server keeps off every model (`isModelFenced`).
        for kind in MetricKind.coachCases {
            let recentGroup = recentGrouped[kind] ?? []
            let priorGroup = priorGrouped[kind] ?? []
            guard !(recentGroup.isEmpty && priorGroup.isEmpty) else { continue }
            let label = displayName(for: kind, language: language)
            lines.append("\(label): \(nowWord) \(recentGroup.count)\(counter), \(priorWord) \(priorGroup.count)\(counter)")
        }
        if !moods.isEmpty {
            let recentMood = moods.filter { $0.recordedAt >= weekAgo }.count
            let priorMood = moods.filter { $0.recordedAt >= twoWeeksAgo && $0.recordedAt < weekAgo }.count
            let label = language.pick(de: "Stimmungseinträge", en: "mood entries", nl: "stemmingsregistraties", ko: "기분 기록")
            lines.append("\(label): \(nowWord) \(recentMood)\(counter), \(priorWord) \(priorMood)\(counter)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting helpers

    /// The word for a mood line in the digest.
    private func moodLabel(_ language: AppLanguage) -> String {
        language.pick(de: "Stimmung", en: "mood", nl: "stemming", ko: "기분")
    }

    private func format(measurement: Measurement, language: AppLanguage) -> String {
        let label = displayName(for: measurement.kind, language: language)
        let kind = measurement.kind
        let valueString = switch measurement.value {
        case let .scalar(v): withUnit(formatNumber(v), kind: kind, language: language)
        case let .bloodPressure(s, d): withUnit("\(formatNumber(s))/\(formatNumber(d))", kind: kind, language: language)
        }
        let dateString = ISO8601DateFormatter().string(from: measurement.recordedAt)
        return "\(label): \(valueString) (\(dateString))"
    }

    private func summarise(kind: MetricKind, group: [Measurement], language: AppLanguage) -> String {
        let label = displayName(for: kind, language: language)
        let scalars: [Double] = group.compactMap { m in
            if case let .scalar(v) = m.value { v } else { nil }
        }
        if !scalars.isEmpty, let minVal = scalars.min(), let maxVal = scalars.max() {
            let avg = scalars.reduce(0, +) / Double(scalars.count)
            let avgText = withUnit(String(format: "%.1f", avg), kind: kind, language: language)
            let row = language.pick(
                de: "%@: n=%d, min %.1f, max %.1f, avg %@",
                en: "%@: n=%d, min %.1f, max %.1f, avg %@",
                nl: "%@: n=%d, min %.1f, max %.1f, avg %@",
                ko: "%@: %d건, 최소 %.1f, 최대 %.1f, 평균 %@"
            )
            return String(format: row, label, group.count, minVal, maxVal, avgText)
        }
        // BP rows — fall through with count only; min/max math on
        // tuples would multiply prompt size for marginal model gain.
        return language.pick(
            de: "\(label): n=\(group.count)",
            en: "\(label): n=\(group.count)",
            nl: "\(label): n=\(group.count)",
            ko: "\(label): \(group.count)건"
        )
    }

    /// A number with its unit. Korean attaches its word units to the number
    /// ("7.5시간", "8000걸음"), the way the Korean interface writes them;
    /// symbol units (kg, bpm, mmHg) keep the space every language uses.
    private func withUnit(_ number: String, kind: MetricKind, language: AppLanguage) -> String {
        let koreanWord = language.pick(de: nil, en: nil, nl: nil, ko: koreanUnitWord(for: kind))
        guard let koreanWord else { return "\(number) \(kind.unit)" }
        return number + koreanWord
    }

    /// The Korean word for a unit the catalogue spells as an abbreviation, or
    /// for a count the catalogue leaves bare. `nil` keeps the symbol unit.
    private func koreanUnitWord(for kind: MetricKind) -> String? {
        switch kind {
        case .steps: return "걸음"
        case .flightsClimbed: return "층"
        default: break
        }
        return switch kind.unit {
        case "h": "시간"
        case "min": "분"
        case "years": "세"
        case "br/min": "회/분"
        default: nil
        }
    }

    /// English prompts use the fixed vocabulary below; German, Dutch and
    /// Korean read the catalogue name, which is in the interface language.
    private func displayName(for kind: MetricKind, language: AppLanguage) -> String {
        switch language {
        case .en: englishName(for: kind)
        case .de, .nl, .ko: kind.displayName
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func englishName(for kind: MetricKind) -> String {
        switch kind {
        case .weight: "weight"
        case .bloodPressure: "blood pressure"
        case .pulse: "pulse"
        case .glucose: "glucose"
        case .bodyFat: "body fat"
        case .bodyTemperature: "temperature"
        case .spo2: "SpO2"
        case .bodyWater: "body water"
        case .boneMass: "bone mass"
        case .sleep: "sleep"
        case .steps: "steps"
        case .restingHeartRate: "resting heart rate"
        case .hrv: "HRV"
        case .vo2Max: "VO2 max"
        case .walkingSpeed: "walking speed"
        case .walkingAsymmetry: "walking asymmetry"
        case .walkingStepLength: "step length"
        case .walkingDoubleSupport: "walking double support"
        case .walkingSteadiness: "walking steadiness"
        case .respiratoryRate: "respiratory rate"
        case .audioExposureEnvironment: "environmental audio exposure"
        case .audioExposureHeadphone: "headphone audio exposure"
        case .bmi: "BMI"
        case .activeEnergy: "active energy"
        case .flightsClimbed: "flights climbed"
        case .distanceWalkingRunning: "walking and running distance"
        case .timeInDaylight: "time in daylight"
        // v0.11 W21 — web-parity body-composition + cardio additions.
        case .fatFreeMass: "fat-free mass"
        case .leanBodyMass: "lean body mass"
        case .muscleMass: "muscle mass"
        case .skinTemperature: "skin temperature"
        case .pulseWaveVelocity: "pulse-wave velocity"
        case .vascularAge: "vascular age"
        case .visceralFat: "visceral fat"
        case .walkingHeartRate: "walking heart rate"
        case .fatMass: "fat mass"
        // v0.13.1 IC — v1.10.0 additive HealthKit signals.
        case .falls: "falls"
        case .sixMinuteWalk: "six-minute walk distance"
        case .stairAscentSpeed: "stair ascent speed"
        case .stairDescentSpeed: "stair descent speed"
        case .breathingDisturbances: "breathing disturbances"
        case .cardioRecovery: "cardio recovery"
        case .wristTemperature: "wrist temperature"
        // v0.14.6 — v1.12.8 WHOOP-native types.
        case .averageHeartRate: "average heart rate"
        case .maxHeartRate: "max heart rate"
        case .sleepDisturbanceCount: "sleep disturbances"
        // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
        case .ansCharge: "autonomic charge"
        case .cardioLoad: "cardio load"
        case .sleepScore: "sleep score"
        case .bodyTemperatureDeviation: "body temperature deviation"
        // v0158 — v1.25 clinical measurement types.
        case .painNRS: "pain"
        case .gripStrength: "grip strength"
        case .waistCircumference: "waist circumference"
        case .waistToHeight: "waist-to-height ratio"
        // Build 3 / item 3.3 — the 21 decoder catch-up types. These strings
        // are the EN prompt vocabulary the coach binder speaks, not UI copy.
        case .phq9Score: "PHQ-9 score"
        case .gad7Score: "GAD-7 score"
        case .who5Score: "WHO-5 well-being score"
        case .sciScore: "sleep condition indicator"
        case .recoveryScore: "recovery score"
        case .stressScore: "stress score"
        case .strainScore: "strain score"
        case .hrvRMSSD: "heart rate variability (RMSSD)"
        case .dayStrain: "day strain"
        case .workoutStrain: "workout strain"
        case .sleepPerformance: "sleep performance"
        case .sleepEfficiency: "sleep efficiency"
        case .sleepConsistency: "sleep consistency"
        case .sleepNeed: "sleep need"
        case .energyExpenditureKJ: "energy expenditure"
        case .resilience: "resilience"
        case .irregularRhythmNotification: "irregular rhythm notification"
        case .highHeartRateEvent: "high heart rate event"
        case .lowHeartRateEvent: "low heart rate event"
        case .walkingSteadinessEvent: "walking steadiness event"
        case .breathingDisturbanceEvent: "breathing disturbance event"
        // Build 7 / item 7.3 — mood (EN prompt vocabulary).
        case .mood: "mood"
        // Audit B-4 — the audio-exposure event joins the EN prompt
        // vocabulary; `.unknown` names itself as unnamed, and never reaches
        // a digest anyway (the loops walk `selectableCases`).
        case .audioExposureEvent: "loud audio notification"
        case .unknown: "unknown metric"
        // #162 — Garmin types (EN prompt vocabulary).
        case .bodyBattery: "Body Battery"
        case .stressLevel: "stress level"
        case .trainingReadiness: "training readiness"
        case .acuteTrainingLoad: "acute training load"
        case .exerciseMinutes, .standMinutes, .standHours, .mindfulMinutes, .stateOfMindValence, .afibBurden: kind.server144PromptName
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}
