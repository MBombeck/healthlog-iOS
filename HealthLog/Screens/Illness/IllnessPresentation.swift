import SwiftUI

// Presentation helpers for the illness surface: localized labels for the
// type / lifecycle enums, a small NEUTRAL badge, vital-type labels for the
// correlation section, and date formatting. Kept separate so the screens stay
// thin and the labels are testable.

struct IllnessEpisodeGroup: Equatable, Identifiable {
    let parent: IllnessEpisodeDTO
    let children: [IllnessEpisodeDTO]

    var id: String {
        parent.id
    }
}

enum IllnessPresentation {
    /// Preserves server order while nesting a child only when its parent exists
    /// and has the same active/resolved status. Orphans and cross-status links
    /// remain top-level rows instead of disappearing.
    static func groupEpisodes(_ episodes: [IllnessEpisodeDTO]) -> [IllnessEpisodeGroup] {
        let byID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
        var childrenByParent: [String: [IllnessEpisodeDTO]] = [:]
        var parents: [IllnessEpisodeDTO] = []

        for episode in episodes {
            let parent = episode.parentConditionId.flatMap { byID[$0] }
            if let parent, parent.isActive == episode.isActive {
                childrenByParent[parent.id, default: []].append(episode)
            } else {
                parents.append(episode)
            }
        }

        return parents.map {
            IllnessEpisodeGroup(parent: $0, children: childrenByParent[$0.id] ?? [])
        }
    }

    static func impactLabel(for level: Int) -> String? {
        // Literal keys — a runtime-interpolated `String.LocalizationValue`
        // (`"illness.daylog.impact.\(level)"`) treats `\(level)` as a FORMAT
        // ARGUMENT, so the lookup key becomes `illness.daylog.impact.%lld`
        // (absent from the catalog) and the string never resolves.
        switch level {
        case 0: String(localized: "illness.daylog.impact.0")
        case 1: String(localized: "illness.daylog.impact.1")
        case 2: String(localized: "illness.daylog.impact.2")
        case 3: String(localized: "illness.daylog.impact.3")
        default: nil
        }
    }

    /// An `ok` correlation is settled only when none of the blocks iOS renders
    /// has content. Returns count as findings just like gap, flags and deviations.
    static func isSettled(_ value: IllnessCorrelationValue) -> Bool {
        value.recoveryGapDays == nil &&
            value.redFlags.isEmpty &&
            value.preOnset.isEmpty &&
            value.nadir.isEmpty &&
            value.returns.isEmpty
    }
}

/// What one journal row says, in the app's two-line row: the name, one
/// line of side facts (type, span, flares, note), the course as a status
/// under nothing else. Pure, so the row's wording is testable.
struct IllnessEpisodeRowContent: Equatable {
    let title: String
    let detail: String?
    let status: String
    let symbol: String
    /// What VoiceOver reads for the whole row, as before the two-line form.
    let spoken: String

    init(episode: IllnessEpisodeDTO, childCount: Int = 0) {
        let span = Self.span(of: episode)
        let flares = childCount > 0
            ? String(format: String(localized: "illness.journal.children.count"), childCount)
            : nil
        let note = episode.note?.isEmpty == false ? String(localized: "Note") : nil
        title = episode.label
        detail = HLRowDetail.joined([episode.type.localizedLabel, span, flares, note])
        status = episode.lifecycle.localizedLabel
        symbol = episode.type.icon
        spoken = String(
            format: String(localized: "illness.row.a11y"),
            episode.label,
            episode.type.localizedLabel,
            span
        )
    }

    /// "Seit 3. Nov. 2026" while it runs, "3. Nov. 2026 bis 9. Nov. 2026"
    /// once it ended.
    static func span(of episode: IllnessEpisodeDTO) -> String {
        if let resolvedAt = episode.resolvedAt, !resolvedAt.isEmpty {
            return String(
                format: String(localized: "illness.journal.onsetResolved"),
                IllnessDateFormat.mediumDate(episode.onsetAt),
                IllnessDateFormat.mediumDate(resolvedAt)
            )
        }
        return String(
            format: String(localized: "illness.journal.onsetActive"),
            IllnessDateFormat.mediumDate(episode.onsetAt)
        )
    }
}

/// What one logged day says as a history row: the date as title, the
/// symptoms and the note on the one side line, the day's impact as status.
/// The fever is the row's value and needs the account's unit, so the view
/// sets it.
struct IllnessDayLogRowContent: Equatable {
    let title: String
    let detail: String?
    let impact: String?

    init(log: IllnessDayLogDTO) {
        title = IllnessDateFormat.mediumDate(log.date)
        let symptoms: [String?] = log.symptoms.map(Self.symptomLabel)
        detail = HLRowDetail.joined(symptoms + [log.note])
        impact = log.functionalImpact.map { IllnessPresentation.impactLabel(for: $0) ?? String($0) }
    }

    /// The catalogue name of a symptom, with its grade where one was set.
    static func symptomLabel(_ symptom: IllnessSymptom) -> String {
        let base: String = if let entry = IllnessSymptomCatalog.entry(for: symptom.key) {
            String(localized: String.LocalizationValue(entry.labelKey))
        } else {
            symptom.key.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let severity = symptom.severity {
            return "\(base) (\(severity))"
        }
        return base
    }
}

struct IllnessDeleteConfirmation: Equatable {
    private(set) var candidate: IllnessEpisodeDTO?

    mutating func request(_ episode: IllnessEpisodeDTO) {
        candidate = episode
    }

    mutating func cancel() {
        candidate = nil
    }

    mutating func confirm() -> IllnessEpisodeDTO? {
        defer { candidate = nil }
        return candidate
    }
}

extension IllnessType {
    /// Localized display label (`illness.type.*`).
    var localizedLabel: String {
        switch self {
        case .infection: String(localized: "illness.type.infection")
        case .allergy: String(localized: "illness.type.allergy")
        case .injury: String(localized: "illness.type.injury")
        case .mentalHealth: String(localized: "illness.type.mentalHealth")
        case .autoimmune: String(localized: "illness.type.autoimmune")
        case .chronic: String(localized: "illness.type.chronic")
        case .other: String(localized: "illness.type.other")
        }
    }

    var icon: String {
        switch self {
        case .infection: "allergens"
        case .allergy: "wind"
        case .injury: "bandage"
        case .mentalHealth: "brain.head.profile"
        case .autoimmune: "shield.lefthalf.filled"
        case .chronic: "calendar.badge.clock"
        case .other: "cross.case"
        }
    }
}

extension IllnessLifecycle {
    /// Localized display label (`illness.lifecycle.*`).
    var localizedLabel: String {
        switch self {
        case .acute: String(localized: "illness.lifecycle.acute")
        case .chronicOngoing: String(localized: "illness.lifecycle.chronicOngoing")
        case .recurring: String(localized: "illness.lifecycle.recurring")
        case .flare: String(localized: "illness.lifecycle.flare")
        case .unknown: String(localized: "illness.lifecycle.unknown")
        }
    }

    var allowsParent: Bool {
        self == .flare || self == .recurring
    }

    /// The `parentConditionId` an episode edit sends. The PATCH always carries
    /// the key (a `null` unlinks), so a course that takes no parent sends `nil`.
    /// A course this build does not know keeps the stored link untouched: the
    /// app cannot tell whether the server allows a parent there, and unlinking
    /// would change a record the person never edited.
    func parentForPatch(chosen: String?, stored: String?) -> String? {
        if allowsParent { return chosen }
        return self == .unknown ? stored : nil
    }
}

enum IllnessVitalLabel {
    /// Maps a server vital-type string to a localized label. Unknown types fall
    /// back to a title-cased rendering of the raw string (forward-compat).
    static func label(for type: String) -> String {
        if let key = keys[type.uppercased()] { return String(localized: key) }
        return type
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// Server vital type to catalog key. v1.21.0: the user-logged
    /// symptom-burden track (`FUNCTIONAL_IMPACT`) can win `gapDriverType`, named
    /// "your symptoms" as on the web. 1.5: the rest of the server's correlation
    /// set (`src/lib/illness/correlation.ts`), which printed as raw English.
    private static let keys: [String: String.LocalizationValue] = [
        "RESTING_HEART_RATE": "illness.vital.restingHeartRate", "RHR": "illness.vital.restingHeartRate",
        "RESPIRATORY_RATE": "illness.vital.respiratoryRate",
        "BODY_TEMPERATURE": "illness.vital.temperature", "TEMPERATURE": "illness.vital.temperature",
        "HEART_RATE_VARIABILITY": "illness.vital.hrv", "HRV": "illness.vital.hrv",
        "OXYGEN_SATURATION": "illness.vital.spo2", "SPO2": "illness.vital.spo2",
        "FUNCTIONAL_IMPACT": "illness.vital.functionalImpact",
        "HRV_RMSSD": "illness.vital.hrvRmssd",
        "RECOVERY_SCORE": "illness.vital.recovery",
        "BLOOD_PRESSURE_SYS": "illness.vital.bloodPressureSys",
        "BLOOD_PRESSURE_DIA": "illness.vital.bloodPressureDia",
        "PULSE": "illness.vital.pulse",
        "WEIGHT": "illness.vital.weight"
    ]
}

extension IllnessRedFlag {
    /// Localized escalating copy for a red flag. **Always escalates ("seek care
    /// if this recurs"), never reassures.**
    var localizedHeadline: String {
        switch reason {
        case "sustained_low_spo2": String(localized: "illness.redflag.sustainedLowSpo2")
        case "sustained_fever": String(localized: "illness.redflag.sustainedFever")
        default: String(localized: "illness.redflag.generic")
        }
    }
}

/// A small NEUTRAL badge for the episode type + lifecycle. Always `.neutral` /
/// `.info` — NEVER `.critical`/red (an illness label is informative, not an
/// alarm; red flags get their own escalating section).
struct IllnessNeutralBadge: View {
    let title: String
    var icon: String?
    var tone: HLBadge.Tone = .neutral

    var body: some View {
        HLBadge(title, icon: icon, tone: tone)
    }
}

enum IllnessDateFormat {
    /// Parse an ISO-8601 instant (with or without fractional seconds) OR a
    /// `YYYY-MM-DD` day key. Reuses the app's shared formatter pair
    /// (`ISO8601DateFormatter.fractional` / `.plain`, declared in `APIClient`)
    /// so there's no per-file non-Sendable static formatter.
    private static func parse(_ raw: String) -> Date? {
        if let d = ISO8601DateFormatter.fractional.date(from: raw) { return d }
        if let d = ISO8601DateFormatter.plain.date(from: raw) { return d }
        // `YYYY-MM-DD` day key — parse via DateComponents (no shared formatter).
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    /// Medium date (e.g. "Jun 10, 2026") from an ISO-8601 instant or a
    /// `YYYY-MM-DD` day key. Falls back to the raw string if unparseable. Routes
    /// through ``HLDateFormat`` so the field order honours the user's
    /// server-backed date-format preference.
    static func mediumDate(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return HLDateFormat.date(date, style: .abbreviated)
    }

    /// Medium date + short time from an ISO-8601 instant. Routes the date
    /// through ``HLDateFormat`` (preference-aware field order).
    static func mediumDateTime(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return HLDateFormat.dateTime(date, style: .abbreviated)
    }
}
