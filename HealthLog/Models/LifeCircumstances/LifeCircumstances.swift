import Foundation

/// **LIFE (1.5.0, #132, Server #614)** — `GET /api/anamnesis/life-circumstances`
/// (server v1.43, only when `features.lifeCircumstances` is `true`).
///
/// Six dated sections, each released to the AI on its own, plus what the
/// server derives from the answers. Every number here (pack-years, minutes a
/// week, the WHO verdict, the screening hints) is resolved on the server and
/// shown as delivered; the app never recomputes one.
///
/// `auditC` (the alcohol section, AUDITC) is read into ``LifeAuditC``; a
/// server without it, or with one this build cannot read, leaves it `nil`.
/// Not read here on purpose: `takeOver` (moving free-text conditions and
/// allergies into their own records) is a flow the web carries, so the app
/// leaves it to the web.
public struct LifeCircumstances: Decodable, Sendable, Equatable {
    /// The sections this build knows, in the server's order.
    public let sections: [LifeSection]
    /// `extraAiSections.SHIFT_SCHEDULE`: shift work has its own AI switch.
    public let shiftScheduleAIIncluded: Bool?
    public let derived: LifeDerived
    /// AUDIT-C, the content of the alcohol section.
    public let auditC: LifeAuditC?

    public init(
        sections: [LifeSection],
        shiftScheduleAIIncluded: Bool?,
        derived: LifeDerived,
        auditC: LifeAuditC? = nil
    ) {
        self.sections = sections
        self.shiftScheduleAIIncluded = shiftScheduleAIIncluded
        self.derived = derived
        self.auditC = auditC
    }

    private enum CodingKeys: String, CodingKey {
        case sections, extraAiSections, derived, auditC
    }

    private struct ExtraSections: Decodable {
        let shiftSchedule: Bool?
        private enum CodingKeys: String, CodingKey {
            case shiftSchedule = "SHIFT_SCHEDULE"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var list = try c.nestedUnkeyedContainer(forKey: .sections)
        var sections: [LifeSection] = []
        while !list.isAtEnd {
            if let section = try? list.decode(LifeSection.self) {
                sections.append(section)
            } else {
                // A section key from a newer server: skipped, never guessed.
                _ = try? list.decode(LifeSkippedElement.self)
            }
        }
        self.sections = sections
        shiftScheduleAIIncluded = (try? c.decodeIfPresent(ExtraSections.self, forKey: .extraAiSections))?.shiftSchedule
        derived = (try? c.decodeIfPresent(LifeDerived.self, forKey: .derived)) ?? .none
        auditC = try? c.decodeIfPresent(LifeAuditC.self, forKey: .auditC)
    }

    public func section(_ key: LifeSectionKey) -> LifeSection? {
        sections.first { $0.key == key }
    }
}

/// The six section keys, in the server's fixed order.
public enum LifeSectionKey: String, Codable, Sendable, Hashable, CaseIterable {
    case tobacco, alcohol, activity, work, habits, goals

    /// The kinds a section writes, in the order it writes them (the web's
    /// `SECTION_KINDS`). Alcohol holds no fact: it is AUDIT-C.
    public var kinds: [LifeFactKind] {
        switch self {
        case .tobacco: [.smokingStatus, .tobaccoDetail]
        case .alcohol: []
        case .activity: [.activityHabit]
        case .work: [.shiftSchedule, .workContext, .freeWeekdays]
        case .habits: [.habits]
        case .goals: [.healthGoals]
        }
    }
}

/// One section of the read route.
public struct LifeSection: Decodable, Sendable, Equatable, Identifiable {
    public let key: LifeSectionKey
    /// The AI switch name this section is released under (`SMOKING_STATUS`,
    /// `ALCOHOL_PATTERN`, `ACTIVITY`, `WORK`, `HABITS`, `GOALS`): the key of
    /// `PATCH …/ai-sections`. Kept as delivered.
    public let aiSection: String
    public let aiIncluded: Bool
    public let lastConfirmedAt: Date?
    /// The newest answer or confirmation is a year old: ask "still true?".
    public let reviewDue: Bool
    /// The current answers this build can name; unknown kinds are skipped.
    public let facts: [LifeFact]

    public var id: LifeSectionKey {
        key
    }

    public init(
        key: LifeSectionKey,
        aiSection: String,
        aiIncluded: Bool,
        lastConfirmedAt: Date?,
        reviewDue: Bool,
        facts: [LifeFact]
    ) {
        self.key = key
        self.aiSection = aiSection
        self.aiIncluded = aiIncluded
        self.lastConfirmedAt = lastConfirmedAt
        self.reviewDue = reviewDue
        self.facts = facts
    }

    private enum CodingKeys: String, CodingKey {
        case key, aiSection, aiIncluded, lastConfirmedAt, reviewDue, facts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(LifeSectionKey.self, forKey: .key)
        aiSection = try c.decode(String.self, forKey: .aiSection)
        aiIncluded = try c.decode(Bool.self, forKey: .aiIncluded)
        lastConfirmedAt = try? c.decodeIfPresent(Date.self, forKey: .lastConfirmedAt)
        reviewDue = (try? c.decodeIfPresent(Bool.self, forKey: .reviewDue)) ?? false
        var list = try c.nestedUnkeyedContainer(forKey: .facts)
        var facts: [LifeFact] = []
        while !list.isAtEnd {
            if let fact = try? list.decode(LifeFact.self) {
                facts.append(fact)
            } else {
                _ = try? list.decode(LifeSkippedElement.self)
            }
        }
        self.facts = facts
    }

    public func fact(_ kind: LifeFactKind) -> LifeFact? {
        facts.first { $0.kind == kind }
    }

    /// The newest `validFrom` among the readable answers: "valid since".
    public var validSince: Date? {
        facts.filter(\.isReadable).map(\.validFrom).max()
    }
}

// MARK: - Derived values

/// Everything the server computes from the answers, read leniently: a part
/// that does not decode is absent, never a zero.
public struct LifeDerived: Decodable, Sendable, Equatable {
    public let packYears: PackYears?
    public let activityMinutesPerWeek: ActivityMinutes?
    public let freeWeekdays: FreeWeekdays?
    public let screeningHints: [ScreeningHint]

    public static let none = LifeDerived(
        packYears: nil, activityMinutesPerWeek: nil, freeWeekdays: nil, screeningHints: []
    )

    public init(
        packYears: PackYears?,
        activityMinutesPerWeek: ActivityMinutes?,
        freeWeekdays: FreeWeekdays?,
        screeningHints: [ScreeningHint]
    ) {
        self.packYears = packYears
        self.activityMinutesPerWeek = activityMinutesPerWeek
        self.freeWeekdays = freeWeekdays
        self.screeningHints = screeningHints
    }

    private enum CodingKeys: String, CodingKey {
        case packYears, activityMinutesPerWeek, freeWeekdays, screeningHints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packYears = try? c.decodeIfPresent(PackYears.self, forKey: .packYears)
        activityMinutesPerWeek = try? c.decodeIfPresent(ActivityMinutes.self, forKey: .activityMinutesPerWeek)
        freeWeekdays = try? c.decodeIfPresent(FreeWeekdays.self, forKey: .freeWeekdays)
        var hints: [ScreeningHint] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .screeningHints) {
            while !list.isAtEnd {
                if let hint = try? list.decode(ScreeningHint.self) {
                    hints.append(hint)
                } else {
                    _ = try? list.decode(LifeSkippedElement.self)
                }
            }
        }
        screeningHints = hints
    }

    public struct PackYears: Decodable, Sendable, Equatable {
        public enum Status: String, Decodable, Sendable {
            case computed
            case notApplicable = "not_applicable"
            case missingInputs = "missing_inputs"
        }

        public let value: Double?
        public let status: Status

        public init(value: Double?, status: Status) {
            self.value = value
            self.status = status
        }
    }

    public struct ActivityMinutes: Decodable, Sendable, Equatable {
        public let value: Int?
        /// The WHO verdict exactly as the server gave it; `nil` says nothing.
        public let meetsWho150: Bool?
        public let measuredStepsAvailable: Bool

        public init(value: Int?, meetsWho150: Bool?, measuredStepsAvailable: Bool) {
            self.value = value
            self.meetsWho150 = meetsWho150
            self.measuredStepsAvailable = measuredStepsAvailable
        }

        private enum CodingKeys: String, CodingKey {
            case value, meetsWho150, measuredStepsAvailable
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try c.decodeIfPresent(Int.self, forKey: .value)
            meetsWho150 = try c.decodeIfPresent(Bool.self, forKey: .meetsWho150)
            measuredStepsAvailable = (try? c.decodeIfPresent(Bool.self, forKey: .measuredStepsAvailable)) ?? false
        }
    }

    public struct FreeWeekdays: Decodable, Sendable, Equatable {
        public let days: [Int]
        /// `fact` or `default_weekend`.
        public let source: String

        public var isDefault: Bool {
            source == "default_weekend"
        }
    }

    public struct ScreeningHint: Decodable, Sendable, Equatable, Identifiable {
        public enum HintID: String, Decodable, Sendable {
            case lungLowDoseCT = "lung_ldct"
            case aaaUltrasound = "aaa_ultrasound"
        }

        public enum Status: String, Decodable, Sendable {
            case suggested
            case notEligible = "not_eligible"
            case unknown
        }

        public let id: HintID
        public let status: Status
        /// Raw reason keys; the screen names only the ones it has the
        /// server's wording for and leaves the rest out.
        public let reasonKeys: [String]
        public let region: String
        public let sourceLabel: String
        public let sourceUrl: String

        public init(
            id: HintID,
            status: Status,
            reasonKeys: [String],
            region: String,
            sourceLabel: String,
            sourceUrl: String
        ) {
            self.id = id
            self.status = status
            self.reasonKeys = reasonKeys
            self.region = region
            self.sourceLabel = sourceLabel
            self.sourceUrl = sourceUrl
        }

        /// Only an `https` link is opened.
        public var sourceURL: URL? {
            guard let url = URL(string: sourceUrl), url.scheme == "https" else { return nil }
            return url
        }
    }
}
