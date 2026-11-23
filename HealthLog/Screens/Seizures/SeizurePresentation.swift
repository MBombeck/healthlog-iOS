import Foundation

/// The symbol of the seizure diary, shared by the More row, the sidebar and
/// the timeline lane.
enum SeizureSymbols {
    static let module = "bolt.circle"
    static let timer = "timer"
    static let rescue = "cross.vial"
}

/// Pure wording of the diary, so the rules are tested without a view.
enum SeizurePresentation {
    /// The name of a seizure's type: the family's own, else the ILAE name of
    /// the event, else "No seizure type".
    static func typeName(of event: SeizureEventDTO, in diary: SeizureDiaryDTO?) -> String {
        if let type = diary?.type(id: event.typeProfileId) { return type.displayName }
        if let ilae = event.effectiveIlaeType ?? event.ilaeType, ilae != .unrecognized { return ilae.label }
        return String(localized: "seizures.untyped")
    }

    /// "4:07" for a duration, "No duration" without one.
    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return String(localized: "seizures.duration.none") }
        return SeizureDateFormat.clock(seconds)
    }

    /// When it began, worded by how sure the time is: with the time of day,
    /// or the date alone when the time is not known.
    static func onset(_ event: SeizureEventDTO) -> String {
        guard let date = event.onsetDate else { return event.onsetAt }
        return event.onsetPrecision == .unknownTime
            ? HLDateFormat.date(date, style: .abbreviated)
            : HLDateFormat.dateTime(date, style: .abbreviated)
    }

    /// The second line of a list row: when, how long, how many.
    static func detail(_ event: SeizureEventDTO) -> String? {
        HLRowDetail.joined([
            onset(event),
            event.durationSec.map(SeizureDateFormat.clock),
            event.count > 1 ? String(localized: "seizures.event.count \(event.count)") : nil
        ])
    }

    /// The quiet status beside a row: a suspected one says so, a cluster
    /// says so, a rescue dose says so; at most one, in that order.
    static func status(_ event: SeizureEventDTO, clustered: Bool) -> String? {
        if event.certainty == .suspected { return SeizureCertainty.suspected.label }
        if clustered { return String(localized: "seizures.list.cluster") }
        if !event.rescueDoses.isEmpty { return String(localized: "seizures.list.rescue") }
        return nil
    }

    /// Who logged it, or `nil` for the person's own entry.
    static func loggedBy(_ event: SeizureEventDTO) -> String? {
        if event.loggedByViewer, event.loggedBy == .delegate { return String(localized: "seizures.list.loggedByYou") }
        guard event.loggedBy == .delegate else { return nil }
        if let name = event.loggedByName, !name.isEmpty { return String(localized: "seizures.list.loggedByName \(name)") }
        return String(localized: "seizures.list.loggedByDelegate")
    }

    /// The panel text once the timer passes the type's threshold.
    static func thresholdLine(_ alert: SeizureAlertThreshold) -> String {
        let time = SeizureDateFormat.clock(alert.seconds)
        switch alert.source {
        case .t1: return String(localized: "seizures.quick.threshold.t1 \(time)")
        case .usualPlusTwo: return String(localized: "seizures.quick.threshold.usualPlusTwo \(time)")
        case .generic, .unrecognized: return String(localized: "seizures.quick.threshold.generic \(time)")
        }
    }

    /// Whether the plan panel stands: only while a timer runs and only once
    /// it has passed the threshold. Before it the panel says nothing at all.
    static func isOverThreshold(elapsed: Int, alert: SeizureAlertThreshold?, isRunning: Bool) -> Bool {
        isRunning && elapsed >= (alert ?? .generic).seconds
    }

    /// "2 or more in 24 h".
    static func ruleText(_ rule: SeizureClusterRule) -> String {
        String(localized: "seizures.report.ruleText \(rule.count) \(rule.windowHours)")
    }

    /// The rescue drug the plan names, for the quick-log button.
    static func rescueName(_ type: SeizureTypeDTO?) -> String? {
        guard let type, type.hasRescueMedication else { return nil }
        let name = type.rescueMedicationName?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }

    /// "10 mg buccal" for a rescue dose.
    static func doseLine(_ dose: SeizureRescueDoseDTO) -> String? {
        let amount = dose.doseAmount.map { HLNumberFormat.decimal($0, maximumFractionDigits: 2) }
        let withUnit = [amount, dose.doseUnit].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return HLRowDetail.joined([withUnit.isEmpty ? nil : withUnit, dose.route?.label])
    }

    /// The number for a medical emergency in the region the device is set to
    /// (`Locale.current.region`, not the language: a Spanish phone in Germany
    /// calls 112). `nil` for a region not in ``emergencyNumbers``; the page
    /// then names "the local emergency number" and offers no call button,
    /// because a wrong number is worse than none.
    static func emergencyNumber(locale: Locale = .current) -> String? {
        guard let region = locale.region?.identifier.uppercased() else { return nil }
        return emergencyNumbers[region]
    }

    /// Medical emergency numbers by ISO region, only where the number is
    /// established for an ambulance: 112 across the EU, the EEA and
    /// Switzerland; the national number elsewhere (Argentina 107 for the
    /// SAME ambulance service, Chile 131 SAMU, Peru 106 SAMU, Colombia 123).
    static let emergencyNumbers: [String: String] = {
        var table: [String: String] = [:]
        let europe112 = [
            "AT", "BE", "BG", "CH", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HR", "HU",
            "IE", "IS", "IT", "LI", "LT", "LU", "LV", "MT", "NL", "NO", "PL", "PT", "RO", "SE", "SI", "SK"
        ]
        for region in europe112 {
            table[region] = "112"
        }
        let northAmerica911 = ["US", "CA", "PR", "MX", "CR", "PA", "SV", "HN", "DO", "EC", "UY", "VE"]
        for region in northAmerica911 {
            table[region] = "911"
        }
        table["GB"] = "999"
        table["AR"] = "107"
        table["CL"] = "131"
        table["PE"] = "106"
        table["CO"] = "123"
        table["BR"] = "192"
        table["KR"] = "119"
        table["JP"] = "119"
        table["AU"] = "000"
        table["NZ"] = "111"
        return table
    }()

    /// `tel:` for the call button; digits only.
    static func callURL(_ number: String) -> URL? {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }

    /// The minutes and seconds fields of a duration.
    static func split(_ seconds: Int?) -> (minutes: String, seconds: String) {
        guard let seconds else { return ("", "") }
        return (String(seconds / 60), String(seconds % 60))
    }

    /// The duration typed into the two fields; `nil` while both are empty or
    /// either is not a whole number.
    static func seconds(minutes: String, seconds: String) -> Int? {
        let minuteText = minutes.trimmingCharacters(in: .whitespaces)
        let secondText = seconds.trimmingCharacters(in: .whitespaces)
        guard !(minuteText.isEmpty && secondText.isEmpty) else { return nil }
        guard let minuteValue = minuteText.isEmpty ? 0 : Int(minuteText),
              let secondValue = secondText.isEmpty ? 0 : Int(secondText),
              minuteValue >= 0, secondValue >= 0 else { return nil }
        let total = minuteValue * 60 + secondValue
        return total <= SeizureEventWrite.maxDurationSec ? total : nil
    }
}
