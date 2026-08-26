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
        }
    }

    var allowsParent: Bool {
        self == .flare || self == .recurring
    }
}

enum IllnessVitalLabel {
    /// Maps a server vital-type string to a localized label. Unknown types fall
    /// back to a title-cased rendering of the raw string (forward-compat).
    static func label(for type: String) -> String {
        switch type.uppercased() {
        case "RESTING_HEART_RATE", "RHR": String(localized: "illness.vital.restingHeartRate")
        case "RESPIRATORY_RATE": String(localized: "illness.vital.respiratoryRate")
        case "BODY_TEMPERATURE", "TEMPERATURE": String(localized: "illness.vital.temperature")
        case "HEART_RATE_VARIABILITY", "HRV": String(localized: "illness.vital.hrv")
        case "OXYGEN_SATURATION", "SPO2": String(localized: "illness.vital.spo2")
        // v1.21.0: the user-logged symptom-burden track (`FUNCTIONAL_IMPACT`)
        // can win `gapDriverType` — name it "your symptoms" (mirrors the web).
        case "FUNCTIONAL_IMPACT": String(localized: "illness.vital.functionalImpact")
        default:
            type
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }
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
    /// server-backed date-format preference (A360-1 H1).
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
