import Foundation

/// **AUDITC (1.5.0, #132, Server #614)** — the alcohol section of the life
/// circumstances: AUDIT-C, as `GET /api/anamnesis/life-circumstances` delivers
/// it in `auditC` (server v1.43).
///
/// Three items of the WHO AUDIT. The wording of the items comes from the
/// server only (`instrument`), verbatim in the account language when a
/// validated translation exists, otherwise the WHO English original with
/// `validatedLocale: false`. This build carries no copy of it, and the
/// catalog never holds it (the rule of the questionnaires, L10N-MH).
///
/// The sum, the cut-off and the verdict are the server's: the app never adds
/// the answers up and never compares the sum with the cut-off. A screening
/// result, not a diagnosis.
///
/// Read leniently: a part that does not decode is absent, never a zero. An
/// instrument that is not exactly three items with answers is not offered.
public struct LifeAuditC: Decodable, Sendable, Equatable {
    /// The newest entry whose answers the server can open; `nil` when none.
    public let latest: AuditCResult?
    /// Every entry by its sum, newest first, at most 20; also the ones whose
    /// answers the server can no longer open, so they can be removed.
    public let history: [AuditCHistoryEntry]
    /// No readable entry, or the newest one is a year old.
    public let offerDue: Bool
    /// The questionnaire to render, `nil` when the server sent none this
    /// build can show as delivered.
    public let instrument: AuditCInstrument?

    public init(latest: AuditCResult?, history: [AuditCHistoryEntry], offerDue: Bool, instrument: AuditCInstrument?) {
        self.latest = latest
        self.history = history
        self.offerDue = offerDue
        self.instrument = instrument
    }

    private enum CodingKeys: String, CodingKey {
        case latest, history, offerDue, instrument
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        latest = try? c.decodeIfPresent(AuditCResult.self, forKey: .latest)
        var entries: [AuditCHistoryEntry] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .history) {
            while !list.isAtEnd {
                if let entry = try? list.decode(AuditCHistoryEntry.self) {
                    entries.append(entry)
                } else {
                    _ = try? list.decode(LifeSkippedElement.self)
                }
            }
        }
        history = entries
        offerDue = (try? c.decodeIfPresent(Bool.self, forKey: .offerDue)) ?? false
        instrument = try? c.decodeIfPresent(AuditCInstrument.self, forKey: .instrument)
    }
}

/// `auditC.instrument`: the three items exactly as the server renders them.
public struct AuditCInstrument: Decodable, Sendable, Equatable {
    public struct Item: Decodable, Sendable, Equatable {
        public let stem: String
        public let options: [Option]

        public init(stem: String, options: [Option]) {
            self.stem = stem
            self.options = options
        }
    }

    public struct Option: Decodable, Sendable, Equatable, Identifiable {
        /// The points of this answer, as the server numbers it (0 to 4).
        public let value: Int
        public let label: String

        public var id: Int {
            value
        }

        public init(value: Int, label: String) {
            self.value = value
            self.label = label
        }
    }

    public let items: [Item]
    /// The language of the wording shown. Sent back unchanged with the
    /// answers: the cut-off belongs to the wording that was answered.
    public let locale: String
    /// `false`: no validated translation for the account language, the
    /// items are the WHO English original.
    public let validatedLocale: Bool
    /// What one drink means, as help text in the account language.
    public let standardDrink: String
    /// The WHO note that has to stand beside the items.
    public let attribution: String

    /// The points the request accepts per item.
    public static let pointRange = 0 ... 4

    public init(items: [Item], locale: String, validatedLocale: Bool, standardDrink: String, attribution: String) {
        self.items = items
        self.locale = locale
        self.validatedLocale = validatedLocale
        self.standardDrink = standardDrink
        self.attribution = attribution
    }

    private enum CodingKeys: String, CodingKey {
        case items, locale, validatedLocale, standardDrink, attribution
    }

    /// Refuses anything but three items, each with answers inside 0 to 4 and
    /// a stem: a form this build cannot render exactly as delivered is not
    /// offered at all.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items = try c.decode([Item].self, forKey: .items)
        let usable = items.count == 3 && items.allSatisfy { item in
            !item.stem.isEmpty && !item.options.isEmpty
                && item.options.allSatisfy { Self.pointRange.contains($0.value) && !$0.label.isEmpty }
        }
        let locale = try c.decode(String.self, forKey: .locale)
        guard usable, !locale.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "not a three-item AUDIT-C")
        }
        self.items = items
        self.locale = locale
        validatedLocale = try c.decode(Bool.self, forKey: .validatedLocale)
        standardDrink = (try? c.decodeIfPresent(String.self, forKey: .standardDrink)) ?? ""
        attribution = (try? c.decodeIfPresent(String.self, forKey: .attribution)) ?? ""
    }
}

/// One AUDIT-C entry, scored on the server (`AuditCResult`).
public struct AuditCResult: Decodable, Sendable, Equatable, Identifiable {
    /// What the server said about the screening cut-off of this entry.
    public enum Cutoff: Sendable, Equatable {
        /// The cut-off for the entry's language and the profile's sex.
        case known(AuditCCutoff)
        /// `cutoff: null`: the profile states no sex, so only the sum shows.
        case noSex
        /// A cut-off this build cannot read: the sum only, and no sentence
        /// that would claim a reason.
        case unreadable
    }

    public let id: String
    public let takenAt: Date
    public let totalScore: Int
    public let locale: String
    public let cutoff: Cutoff
    /// The verdict exactly as the server gave it; `nil` says nothing.
    public let aboveCutoff: Bool?
    public let validatedLocale: Bool

    public init(
        id: String,
        takenAt: Date,
        totalScore: Int,
        locale: String,
        cutoff: Cutoff,
        aboveCutoff: Bool?,
        validatedLocale: Bool
    ) {
        self.id = id
        self.takenAt = takenAt
        self.totalScore = totalScore
        self.locale = locale
        self.cutoff = cutoff
        self.aboveCutoff = aboveCutoff
        self.validatedLocale = validatedLocale
    }

    private enum CodingKeys: String, CodingKey {
        case id, takenAt, totalScore, locale, cutoff, aboveCutoff, validatedLocale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        takenAt = try c.decode(Date.self, forKey: .takenAt)
        totalScore = try c.decode(Int.self, forKey: .totalScore)
        locale = (try? c.decodeIfPresent(String.self, forKey: .locale)) ?? ""
        if (try? c.decodeNil(forKey: .cutoff)) == true {
            cutoff = .noSex
        } else if let known = try? c.decode(AuditCCutoff.self, forKey: .cutoff) {
            cutoff = .known(known)
        } else {
            cutoff = .unreadable
        }
        aboveCutoff = try? c.decodeIfPresent(Bool.self, forKey: .aboveCutoff)
        validatedLocale = (try? c.decodeIfPresent(Bool.self, forKey: .validatedLocale)) ?? true
    }
}

/// The screening cut-off of an entry and the guideline it comes from.
public struct AuditCCutoff: Decodable, Sendable, Equatable {
    public let value: Int
    /// `male` or `female`, as delivered.
    public let sex: String
    /// `S3_ALCOHOL_DE`, `KNHANES_KR` or `BRADLEY_2007`, as delivered.
    public let source: String
    public let sourceLabel: String
    public let sourceUrl: String

    public init(value: Int, sex: String, source: String, sourceLabel: String, sourceUrl: String) {
        self.value = value
        self.sex = sex
        self.source = source
        self.sourceLabel = sourceLabel
        self.sourceUrl = sourceUrl
    }

    /// Only an `https` link is opened.
    public var sourceURL: URL? {
        guard let url = URL(string: sourceUrl), url.scheme == "https" else { return nil }
        return url
    }
}

/// One line of `auditC.history`: an entry by its sum.
public struct AuditCHistoryEntry: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let takenAt: Date
    public let totalScore: Int

    public init(id: String, takenAt: Date, totalScore: Int) {
        self.id = id
        self.takenAt = takenAt
        self.totalScore = totalScore
    }
}
