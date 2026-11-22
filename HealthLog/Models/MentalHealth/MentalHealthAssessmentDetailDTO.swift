import Foundation

/// `GET /api/mental-health/assessments/{id}` — one administration with its
/// per-item answers (server v1.48, #182 part B).
///
/// Since 1.48 a PHQ-9 or GAD-7 can come from Apple Health as a score alone.
/// Such a row has `source: "APPLE_HEALTH"`, `items: null` and
/// `itemsUnavailable: true`: the answers were never shared, nothing failed.
/// The same pair on any other row means the stored answers could not be read.
/// ``answers`` keeps the two apart, so the app never calls an Apple Health
/// score "unreadable".
///
/// **PHI.** The answers are read for display only: never cached, never
/// logged, never written anywhere (``MentalHealthRepository/assessment(id:)``).
public struct MentalHealthAssessmentDetailDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let instrument: MentalHealthInstrument
    public let totalScore: Int
    public let items: [Int]?
    public let itemsUnavailable: Bool
    /// `WEB`, `IOS` or `APPLE_HEALTH`, raw; `nil` on an older server.
    public let source: String?

    /// The answers as the detail can show them.
    public enum Answers: Equatable, Sendable {
        /// The per-item answers, in the instrument's order.
        case shown([Int])
        /// An Apple Health score sent without its answers.
        case notShared
        /// Stored answers that could not be read.
        case unreadable
    }

    public init(
        id: String,
        instrument: MentalHealthInstrument,
        totalScore: Int,
        items: [Int]?,
        itemsUnavailable: Bool,
        source: String?
    ) {
        self.id = id
        self.instrument = instrument
        self.totalScore = totalScore
        self.items = items
        self.itemsUnavailable = itemsUnavailable
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, instrument, totalScore, items, itemsUnavailable, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        instrument = try c.decodeIfPresent(MentalHealthInstrument.self, forKey: .instrument) ?? .phq9
        totalScore = (try? c.decodeIfPresent(Int.self, forKey: .totalScore)).flatMap { $0 } ?? 0
        items = (try? c.decodeIfPresent([Int].self, forKey: .items)).flatMap { $0 }
        itemsUnavailable = (try? c.decodeIfPresent(Bool.self, forKey: .itemsUnavailable)).flatMap { $0 } ?? false
        source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap { $0 }
    }

    /// `true` for a score that arrived from Apple Health.
    public var isFromAppleHealth: Bool {
        source == "APPLE_HEALTH"
    }

    public var answers: Answers {
        if !itemsUnavailable, let items, !items.isEmpty { return .shown(items) }
        return isFromAppleHealth ? .notShared : .unreadable
    }

    /// The one line a detail shows in place of answers it cannot show.
    /// `nil` while the answers are there.
    public var missingAnswersNote: String? {
        switch answers {
        case .shown: nil
        case .notShared: String(localized: "mentalHealth.answers.notShared")
        case .unreadable: String(localized: "mentalHealth.answers.unreadable")
        }
    }
}
