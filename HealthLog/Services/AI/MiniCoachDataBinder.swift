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

    init(locale: Locale = Locale(identifier: "de_DE")) {
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
        let language = locale.language.languageCode?.identifier ?? "de"
        if measurements.isEmpty, moods.isEmpty {
            return language == "en"
                ? "(no measurements or mood entries available in the window)"
                : "(keine Messungen oder Stimmungseinträge im Zeitfenster verfügbar)"
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
        language: String
    ) -> String {
        var lines: [String] = []
        let grouped = Dictionary(grouping: measurements, by: \.kind)
        for kind in MetricKind.allCases {
            guard let latest = grouped[kind]?.max(by: { $0.recordedAt < $1.recordedAt }) else { continue }
            lines.append(format(measurement: latest, language: language))
        }
        if let latestMood = moods.max(by: { $0.recordedAt < $1.recordedAt }) {
            let header = language == "en" ? "mood" : "Stimmung"
            lines.append("\(header): \(latestMood.score)/5")
        }
        let count = measurements.count
        let header = language == "en"
            ? "Latest reading per metric (\(count) total measurements):"
            : "Letzter Wert je Metrik (\(count) Messungen insgesamt):"
        return header + "\n" + lines.joined(separator: "\n")
    }

    /// period-summary → counts + min/max/avg per kind over the last 7 days.
    private func renderLastSevenDays(
        measurements: [Measurement],
        moods: [MoodEntry],
        now: Date,
        language: String
    ) -> String {
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let window = measurements.filter { $0.recordedAt >= cutoff }
        let moodWindow = moods.filter { $0.recordedAt >= cutoff }
        let header = language == "en"
            ? "Window: last 7 days (\(window.count) measurements, \(moodWindow.count) mood entries)"
            : "Zeitraum: letzte 7 Tage (\(window.count) Messungen, \(moodWindow.count) Stimmungseinträge)"
        var lines: [String] = [header]
        let grouped = Dictionary(grouping: window, by: \.kind)
        for kind in MetricKind.allCases {
            guard let group = grouped[kind], !group.isEmpty else { continue }
            lines.append(summarise(kind: kind, group: group, language: language))
        }
        if !moodWindow.isEmpty {
            let scores = moodWindow.map(\.score)
            if let minScore = scores.min(), let maxScore = scores.max() {
                let avg = Double(scores.reduce(0, +)) / Double(scores.count)
                let label = language == "en" ? "mood" : "Stimmung"
                lines.append(String(format: "%@: min %d, max %d, avg %.1f", label, minScore, maxScore, avg))
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
        language: String
    ) -> String {
        let sorted = measurements.sorted(by: { $0.recordedAt < $1.recordedAt })
        guard let first = sorted.first, let last = sorted.last else {
            return language == "en"
                ? "(no measurements in window)"
                : "(keine Messungen im Zeitfenster)"
        }
        let header = language == "en"
            ? "History window: \(sorted.count) measurements between earliest and latest entry"
            : "Verlaufsfenster: \(sorted.count) Messungen zwischen erstem und letztem Eintrag"
        var lines = [header]
        lines.append((language == "en" ? "earliest: " : "frühester Eintrag: ") + format(measurement: first, language: language))
        lines.append((language == "en" ? "latest: " : "letzter Eintrag: ") + format(measurement: last, language: language))
        if !moods.isEmpty {
            lines.append((language == "en" ? "mood entries in window: " : "Stimmungseinträge im Fenster: ") + String(moods.count))
        }
        return lines.joined(separator: "\n")
    }

    /// comparison → last 7 days vs. preceding 7 days, per kind.
    private func renderTwoWeekDiff(
        measurements: [Measurement],
        moods: [MoodEntry],
        now: Date,
        language: String
    ) -> String {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let twoWeeksAgo = now.addingTimeInterval(-14 * 24 * 3600)
        let recent = measurements.filter { $0.recordedAt >= weekAgo }
        let prior = measurements.filter { $0.recordedAt >= twoWeeksAgo && $0.recordedAt < weekAgo }
        let header = language == "en"
            ? "Comparison: last 7 days (recent, \(recent.count) measurements) vs. previous 7 days (prior, \(prior.count) measurements)"
            : "Vergleich: letzte 7 Tage (jetzt, \(recent.count) Messungen) vs. vorletzte 7 Tage (davor, \(prior.count) Messungen)"
        var lines: [String] = [header]
        let recentGrouped = Dictionary(grouping: recent, by: \.kind)
        let priorGrouped = Dictionary(grouping: prior, by: \.kind)
        for kind in MetricKind.allCases {
            let recentGroup = recentGrouped[kind] ?? []
            let priorGroup = priorGrouped[kind] ?? []
            guard !(recentGroup.isEmpty && priorGroup.isEmpty) else { continue }
            let label = displayName(for: kind, language: language)
            lines.append("\(label): jetzt \(recentGroup.count), davor \(priorGroup.count)")
        }
        if !moods.isEmpty {
            let recentMood = moods.filter { $0.recordedAt >= weekAgo }.count
            let priorMood = moods.filter { $0.recordedAt >= twoWeeksAgo && $0.recordedAt < weekAgo }.count
            let label = language == "en" ? "mood entries" : "Stimmungseinträge"
            lines.append("\(label): jetzt \(recentMood), davor \(priorMood)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting helpers

    private func format(measurement: Measurement, language: String) -> String {
        let label = displayName(for: measurement.kind, language: language)
        let unit = measurement.kind.unit
        let valueString = switch measurement.value {
        case let .scalar(v): "\(formatNumber(v)) \(unit)"
        case let .bloodPressure(s, d): "\(formatNumber(s))/\(formatNumber(d)) \(unit)"
        }
        let dateString = ISO8601DateFormatter().string(from: measurement.recordedAt)
        return "\(label): \(valueString) (\(dateString))"
    }

    private func summarise(kind: MetricKind, group: [Measurement], language: String) -> String {
        let label = displayName(for: kind, language: language)
        let scalars: [Double] = group.compactMap { m in
            if case let .scalar(v) = m.value { v } else { nil }
        }
        if !scalars.isEmpty, let minVal = scalars.min(), let maxVal = scalars.max() {
            let avg = scalars.reduce(0, +) / Double(scalars.count)
            return String(format: "%@: n=%d, min %.1f, max %.1f, avg %.1f %@", label, group.count, minVal, maxVal, avg, kind.unit)
        }
        // BP rows — fall through with count only; min/max math on
        // tuples would multiply prompt size for marginal model gain.
        return "\(label): n=\(group.count)"
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func displayName(for kind: MetricKind, language: String) -> String {
        if language == "en" {
            switch kind {
            case .weight: return "weight"
            case .bloodPressure: return "blood pressure"
            case .pulse: return "pulse"
            case .glucose: return "glucose"
            case .bodyFat: return "body fat"
            case .bodyTemperature: return "temperature"
            case .spo2: return "SpO2"
            case .bodyWater: return "body water"
            case .boneMass: return "bone mass"
            case .sleep: return "sleep"
            case .steps: return "steps"
            case .restingHeartRate: return "resting heart rate"
            case .hrv: return "HRV"
            case .vo2Max: return "VO2 max"
            case .walkingSpeed: return "walking speed"
            case .walkingAsymmetry: return "walking asymmetry"
            case .walkingStepLength: return "step length"
            case .walkingDoubleSupport: return "walking double support"
            case .walkingSteadiness: return "walking steadiness"
            case .respiratoryRate: return "respiratory rate"
            case .audioExposureEnvironment: return "environmental audio exposure"
            case .audioExposureHeadphone: return "headphone audio exposure"
            case .bmi: return "BMI"
            case .activeEnergy: return "active energy"
            case .flightsClimbed: return "flights climbed"
            case .distanceWalkingRunning: return "walking and running distance"
            case .timeInDaylight: return "time in daylight"
            // v0.11 W21 — web-parity body-composition + cardio additions.
            case .fatFreeMass: return "fat-free mass"
            case .leanBodyMass: return "lean body mass"
            case .muscleMass: return "muscle mass"
            case .skinTemperature: return "skin temperature"
            case .pulseWaveVelocity: return "pulse-wave velocity"
            case .vascularAge: return "vascular age"
            case .visceralFat: return "visceral fat"
            case .walkingHeartRate: return "walking heart rate"
            case .fatMass: return "fat mass"
            // v0.13.1 IC — v1.10.0 additive HealthKit signals.
            case .falls: return "falls"
            case .sixMinuteWalk: return "six-minute walk distance"
            case .stairAscentSpeed: return "stair ascent speed"
            case .stairDescentSpeed: return "stair descent speed"
            case .breathingDisturbances: return "breathing disturbances"
            case .cardioRecovery: return "cardio recovery"
            case .wristTemperature: return "wrist temperature"
            // v0.14.6 — v1.12.8 WHOOP-native types.
            case .averageHeartRate: return "average heart rate"
            case .maxHeartRate: return "max heart rate"
            case .sleepDisturbanceCount: return "sleep disturbances"
            // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
            case .ansCharge: return "autonomic charge"
            case .cardioLoad: return "cardio load"
            case .sleepScore: return "sleep score"
            case .bodyTemperatureDeviation: return "body temperature deviation"
            // v0158 — v1.25 clinical measurement types.
            case .painNRS: return "pain"
            case .gripStrength: return "grip strength"
            case .waistCircumference: return "waist circumference"
            case .waistToHeight: return "waist-to-height ratio"
            // Build 3 / item 3.3 — the 21 decoder catch-up types. These strings
            // are the EN prompt vocabulary the coach binder speaks, not UI copy.
            case .phq9Score: return "PHQ-9 score"
            case .gad7Score: return "GAD-7 score"
            case .who5Score: return "WHO-5 well-being score"
            case .sciScore: return "sleep condition indicator"
            case .recoveryScore: return "recovery score"
            case .stressScore: return "stress score"
            case .strainScore: return "strain score"
            case .hrvRMSSD: return "heart rate variability (RMSSD)"
            case .dayStrain: return "day strain"
            case .workoutStrain: return "workout strain"
            case .sleepPerformance: return "sleep performance"
            case .sleepEfficiency: return "sleep efficiency"
            case .sleepConsistency: return "sleep consistency"
            case .sleepNeed: return "sleep need"
            case .energyExpenditureKJ: return "energy expenditure"
            case .resilience: return "resilience"
            case .irregularRhythmNotification: return "irregular rhythm notification"
            case .highHeartRateEvent: return "high heart rate event"
            case .lowHeartRateEvent: return "low heart rate event"
            case .walkingSteadinessEvent: return "walking steadiness event"
            case .breathingDisturbanceEvent: return "breathing disturbance event"
            // Build 7 / item 7.3 — mood (EN prompt vocabulary).
            case .mood: return "mood"
            }
        }
        return kind.displayName
    }

    private func formatNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}
