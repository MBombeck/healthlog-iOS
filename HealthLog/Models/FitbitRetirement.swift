import Foundation

/// KONTO (#149, server 1.43.11) — the end of the legacy Fitbit Web API.
///
/// Google turned it off on 2026-10-30. The Fitbit entry of
/// `GET /api/integrations/status` carries `retirement` (the per-provider
/// `/api/fitbit/status` does not), and from the turndown on connect, sync and
/// test answer `410 provider_retired`. The connection row and everything it
/// imported stay; the successor is Google Health, which reads the same devices
/// but needs a fresh consent.
///
/// Every field is optional on purpose (rule 10): a server without `retirement`
/// keeps the Fitbit row exactly as before, and a 410 alone is enough to show
/// the notice without a date.
public struct FitbitRetirement: Decodable, Sendable, Equatable {
    /// The turndown day as the server publishes it, `YYYY-MM-DD`.
    public let endsOn: String?
    /// The day has come: the connection no longer syncs.
    public let ended: Bool
    /// The integration that reads the same devices (`google-health`).
    public let successor: String?
    /// `false` once ended for an account that never had Fitbit: the row is not
    /// offered at all. `nil` (older server) counts as offered.
    public let offered: Bool?

    public init(endsOn: String?, ended: Bool, successor: String? = nil, offered: Bool? = nil) {
        self.endsOn = endsOn
        self.ended = ended
        self.successor = successor
        self.offered = offered
    }

    private enum CodingKeys: String, CodingKey {
        case endsOn, ended, successor, offered
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endsOn = try? c.decodeIfPresent(String.self, forKey: .endsOn)
        ended = (try? c.decodeIfPresent(Bool.self, forKey: .ended)) ?? false
        successor = try? c.decodeIfPresent(String.self, forKey: .successor)
        offered = try? c.decodeIfPresent(Bool.self, forKey: .offered)
    }

    /// The state a `410 provider_retired` implies when the status read did not
    /// say more: ended, no date, successor unknown.
    public static let retiredByRefusal = FitbitRetirement(endsOn: nil, ended: true)

    /// `meta.errorCode` of a refused connect, sync or test after the turndown.
    public static let providerRetiredCode = "provider_retired"

    /// The successor the app can point at.
    public static let googleHealthSuccessor = "google-health"

    /// The public guide for moving to Google Health (the web links the same).
    public static let googleHealthGuideURL = URL(string: "https://docs.healthlog.dev/guides/connect-google-health/")

    /// The turndown day as a calendar date, read in UTC so it never shifts by
    /// a day in a western time zone.
    public var endDate: Date? {
        guard let endsOn else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = endsOn.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// The sentence for the Fitbit screen: shut down (with the day when known),
    /// or about to be.
    public var notice: String {
        let day = endDate.map {
            $0.formatted(
                Date.FormatStyle(
                    date: .long,
                    time: .omitted,
                    locale: AppLanguage.current.formattingLocale,
                    timeZone: TimeZone(identifier: "UTC") ?? .gmt
                )
            )
        }
        switch (ended, day) {
        case let (true, day?): return String(localized: "integration.fitbit.retired.ended \(day)")
        case (true, nil): return String(localized: "integration.fitbit.retired.endedNoDate")
        case let (false, day?): return String(localized: "integration.fitbit.retired.ending \(day)")
        case (false, nil): return String(localized: "integration.fitbit.retired.endingNoDate")
        }
    }

    /// Whether the move to Google Health can be explained with its guide.
    public var pointsToGoogleHealth: Bool {
        successor == nil || successor == Self.googleHealthSuccessor
    }

    /// Whether a refusal is the turndown's `410 provider_retired`.
    public static func isRetiredRefusal(_ error: Error) -> Bool {
        guard case let .server(status, code, _) = error as? HLError else { return false }
        return code == providerRetiredCode || (status == 410 && code == nil)
    }
}

/// The slice of `GET /api/integrations/status` this build reads: the Fitbit
/// entry's `retirement`. Everything else in the envelope is ignored, and an
/// entry that does not decode is skipped rather than failing the read.
struct IntegrationsRetirementPayload: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let integration: String?
        let retirement: FitbitRetirement?

        private enum CodingKeys: String, CodingKey {
            case integration, retirement
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            integration = try? c.decodeIfPresent(String.self, forKey: .integration)
            retirement = try? c.decodeIfPresent(FitbitRetirement.self, forKey: .retirement)
        }
    }

    let integrations: [Entry]

    private enum CodingKeys: String, CodingKey {
        case integrations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        integrations = (try? c.decodeIfPresent([Entry].self, forKey: .integrations)) ?? []
    }

    var fitbit: FitbitRetirement? {
        integrations.first { $0.integration == "fitbit" }?.retirement
    }
}
