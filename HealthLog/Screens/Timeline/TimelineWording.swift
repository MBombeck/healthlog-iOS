import SwiftUI

/// Names, numbers and colours of the timeline's rows.
///
/// A value line is named and formatted the way the rest of the app names and
/// formats its metric (the descriptor's title, the account's unit), blood
/// pressure as two lines of its own, a lab marker by its own name and a
/// symptom by the name the person gave it.
struct TimelineWording: Sendable {
    let read: TimelineRead?
    let units: UnitPreferences

    // MARK: - Measurement types

    /// Server measurement name to the app's kind: the inverse of the
    /// availability key table, diastolic pressure read as blood pressure.
    nonisolated static let kindByServerName: [String: MetricKind] = {
        var out: [String: MetricKind] = ["BLOOD_PRESSURE_DIA": .bloodPressure]
        for kind in MetricKind.allCases {
            guard let name = kind.availabilitySummaryKey, out[name] == nil else { continue }
            out[name] = kind
        }
        return out
    }()

    nonisolated static func kind(forServerName name: String) -> MetricKind? {
        kindByServerName[name]
    }

    // MARK: - Names

    func title(forValue key: String) -> String {
        switch key {
        case "BLOOD_PRESSURE_SYS": return String(localized: "timeline.values.bloodPressureSys")
        case "BLOOD_PRESSURE_DIA": return String(localized: "timeline.values.bloodPressureDia")
        case "MOOD": return String(localized: "timeline.values.mood")
        default: break
        }
        if key.hasPrefix("lab:") {
            let name = read?.labSeries.first { $0.key == key }?.name ?? read?.availableLabs.first { $0.key == key }?.name
            return name ?? String(localized: "timeline.values.labUnnamed")
        }
        if key.hasPrefix("symptom:") {
            let label = read?.symptomSeries.first { $0.key == key }?.label
                ?? read?.availableSymptoms.first { $0.key == key }?.label
            return label ?? String(localized: "timeline.symptoms.unnamed")
        }
        if let kind = Self.kind(forServerName: key) {
            return String(localized: MetricKindDescriptor.descriptor(for: kind).title)
        }
        return key.split(separator: "_").map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    func title(forLane key: TimelineLaneKey) -> String {
        switch key {
        case .life: String(localized: "timeline.lanes.life")
        case .illness: String(localized: "timeline.lanes.illness")
        case .seizures: String(localized: "timeline.lanes.seizures")
        case .allergies: String(localized: "timeline.lanes.allergies")
        case .medications: String(localized: "timeline.lanes.medications")
        case .vaccinations: String(localized: "timeline.lanes.vaccinations")
        case .visits: String(localized: "timeline.lanes.visits")
        case .labs: String(localized: "timeline.lanes.labs")
        case .documents: String(localized: "timeline.lanes.documents")
        case .cycle: String(localized: "timeline.lanes.cycle")
        }
    }

    nonisolated static func symbol(forLane key: TimelineLaneKey) -> String {
        switch key {
        case .life: "star"
        case .illness: "thermometer.medium"
        case .seizures: SeizureSymbols.module
        case .allergies: "allergens"
        case .medications: "pills"
        case .vaccinations: "syringe"
        case .visits: "stethoscope"
        case .labs: "testtube.2"
        case .documents: "doc.text"
        case .cycle: "circle.dotted"
        }
    }

    /// How an item reads on its bar or in the summary: codes worded, never raw.
    func words(_ item: TimelineItem) -> String {
        switch item.kind {
        case .travel: String(localized: "timeline.item.travel")
        case .cycle: String(localized: "timeline.item.cycle")
        case .seizureDay: Self.seizureDayWords(label: item.label, sub: item.sub)
        case .labDay:
            item.sub.flatMap(Int.init).map { String(localized: "timeline.item.labDay \($0)") }
                ?? String(localized: "timeline.lanes.labs")
        case .medication, .doseChange, .course:
            [item.label, item.sub].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        default:
            item.label
        }
    }

    /// A seizure day: its types by the person's own names and the count
    /// the server sent (a logged run of several counts as several).
    nonisolated static func seizureDayWords(label: String, sub: String?) -> String {
        let names = label.trimmingCharacters(in: .whitespaces)
        guard let count = sub.flatMap(Int.init) else {
            return names.isEmpty ? String(localized: "timeline.lanes.seizures") : names
        }
        return names.isEmpty
            ? String(localized: "timeline.item.seizureDay \(count)")
            : String(localized: "timeline.item.seizureDay.typed \(names) \(count)")
    }

    // MARK: - Numbers

    /// A value of `key` in the unit the app shows it in, with its unit.
    func value(_ value: Double, key: String) -> String {
        if key.hasPrefix("lab:") {
            let unit = read?.labSeries.first { $0.key == key }?.unit ?? ""
            let number = HLNumberFormat.decimal(value, maximumFractionDigits: 2)
            return unit.isEmpty ? number : "\(number) \(unit)"
        }
        if key.hasPrefix("symptom:") {
            let number = HLNumberFormat.decimal(value, maximumFractionDigits: 1)
            return String(localized: "timeline.symptoms.value \(number)")
        }
        if key == "MOOD" {
            return HLNumberFormat.decimal(value, maximumFractionDigits: 1)
        }
        guard let kind = Self.kind(forServerName: key) else {
            let unit = read?.series.first { $0.key == key }?.unit ?? ""
            let number = HLNumberFormat.decimal(value, maximumFractionDigits: 1)
            return unit.isEmpty ? number : "\(number) \(unit)"
        }
        let descriptor = MetricKindDescriptor.descriptor(for: kind)
        if descriptor.formatStyle == .durationHM {
            let unit = read?.series.first { $0.key == key }?.unit?.lowercased() ?? "min"
            let hours = unit.hasPrefix("h") ? value : value / 60
            return MetricValueFormatter.styled(hours, style: .durationHM)
        }
        let number = MetricValueFormatter.account(value, kind: kind, units: units) {
            MetricValueFormatter.styled($0, style: kind == .bloodPressure ? .integer : descriptor.formatStyle)
        }
        let suffix = MetricValueFormatter.unitSuffix(for: kind, units: units)
        return suffix.isEmpty ? number : "\(number) \(suffix)"
    }

    func trend(_ trend: TimelineTrend) -> String? {
        switch trend {
        case .rising: String(localized: "timeline.trend.rising")
        case .falling: String(localized: "timeline.trend.falling")
        case .steady: String(localized: "timeline.trend.steady")
        case .unknown: nil
        }
    }
}

/// The colours of the timeline: the app's own warm category tones, the
/// hues of the wellness tiles for the measured values (clay rose for blood
/// pressure, systolic and diastolic told apart by circle and diamond, honey
/// for pulse and heart rhythm, violet for the body, steel blue for sleep,
/// leaf green for activity and sugar, teal for breath and vitals), one
/// colour per kind of value. Illness and the
/// person's own symptoms are events and stand in the app's graphite ink, so
/// red never means both a blood pressure and an illness.
/// Muted rather than the system colours at full strength, so the chart reads
/// as part of the app. Every row also carries its name, so colour is never
/// the only signal.
enum TimelinePalette {
    static func color(forLane key: TimelineLaneKey) -> Color {
        switch key {
        case .illness, .seizures: HLColor.inkGraphite
        case .medications: HLColor.wellnessCardioHue
        case .allergies: HLColor.wellnessRecoveryHue
        case .vaccinations: HLColor.wellnessTagesformHue
        case .visits, .labs: HLColor.wellnessHrvBalanceHue
        case .cycle: HLColor.wellnessVascularHue
        case .life, .documents: HLText.secondary
        }
    }

    static func color(forValue key: String) -> Color {
        if key.hasPrefix("lab:") { return HLColor.wellnessBelastungHue }
        if key.hasPrefix("symptom:") { return HLColor.inkGraphite }
        if key == "MOOD" { return HLColor.wellnessCardioHue }
        guard let kind = TimelineWording.kind(forServerName: key) else { return HLChartTints.series }
        return color(for: kind)
    }

    private static func color(for kind: MetricKind) -> Color {
        switch kind {
        case .bloodPressure:
            HLColor.wellnessStressHue
        case .pulse, .restingHeartRate, .hrv, .hrvRMSSD, .walkingHeartRate, .averageHeartRate, .maxHeartRate,
             .cardioRecovery, .vo2Max:
            HLColor.wellnessRecoveryHue
        case .weight, .bmi, .bodyFat, .fatMass, .leanBodyMass, .muscleMass, .waistCircumference, .bodyWater:
            HLColor.wellnessVascularHue
        case .sleep, .sleepScore, .sleepPerformance, .sleepEfficiency, .sleepNeed, .sleepConsistency:
            HLColor.wellnessHrvBalanceHue
        case .steps, .activeEnergy, .dayStrain, .strainScore, .flightsClimbed, .distanceWalkingRunning:
            HLColor.wellnessTagesformHue
        case .spo2, .respiratoryRate, .bodyTemperature, .wristTemperature, .skinTemperature:
            HLColor.wellnessCardioHue
        case .glucose:
            HLColor.wellnessTagesformHue
        default:
            HLChartTints.series
        }
    }
}
