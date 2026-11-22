import Foundation

// #176 (server v1.48) — the language of each Today text, and the choice of
// the lead and the signal line by the interface language. Split out of
// `DailyDigest.swift` (file length).

public extension DailyDigest {
    /// #176 — the languages of the digest's texts. `response` is every text
    /// the server words itself on this request (the `Accept-Language` of a
    /// Bearer request when it names a shipped language, else the account's);
    /// `briefing` the stored briefing texts (`briefingLead`, `topSignal`,
    /// `signalLine`); `reaction` the reaction line. `nil` means unknown.
    struct TextLanguages: Codable, Sendable, Equatable {
        public let response: String?
        public let briefing: String?
        public let reaction: String?

        public init(response: String?, briefing: String?, reaction: String?) {
            self.response = response
            self.briefing = briefing
            self.reaction = reaction
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            response = try? c.decodeIfPresent(String.self, forKey: .response)
            briefing = try? c.decodeIfPresent(String.self, forKey: .briefing)
            reaction = try? c.decodeIfPresent(String.self, forKey: .reaction)
        }
    }
}

extension DailyDigest {
    func lead(for app: AppLanguage) -> String {
        if let resolved = admittedResolvedLead,
           Self.reads(resolved.language ?? languageOf(source: resolved.source), in: app)
        {
            return resolved.text
        }
        if showsBriefingText, let briefingLead, !briefingLead.isEmpty,
           Self.reads(languages?.briefing, in: app)
        {
            return briefingLead
        }
        // An empty line (a server with nothing deterministic to say) keeps
        // its old rendering only where the languages are unknown.
        if Self.reads(languages?.response, in: app), !line.isEmpty || languages == nil {
            return line
        }
        return Self.ownLeadFallback
    }

    /// The app's own lead, for a day whose every server sentence is in
    /// another language than the interface.
    static var ownLeadFallback: String {
        String(localized: "today.lead.ownFallback")
    }

    /// The language a resolved lead of this `source` is in, by the digest's
    /// `languages` (the server's own rule, `text-languages.ts`).
    private func languageOf(source: String) -> String? {
        switch source {
        case "reaction": languages?.reaction
        case "briefing": languages?.briefing
        default: languages?.response
        }
    }

    /// `true` when a text in `language` reads in the interface language, or
    /// when its language is not stated. Compares the primary subtag only:
    /// `de-AT` reads as `de`, `pt-BR` never as English.
    static func reads(_ language: String?, in app: AppLanguage) -> Bool {
        guard let language, !language.isEmpty else { return true }
        let primary = language
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        return primary == app.rawValue
    }

    func signalText(for app: AppLanguage) -> String? {
        guard showsBriefingText else { return nil }
        if deliversSignalLine {
            guard let signalLine,
                  Self.reads(signalLine.language ?? languages?.briefing, in: app) else { return nil }
            return Self.joinSignal(headline: signalLine.headline, delta: signalLine.delta)
        }
        guard let signal = visibleTopSignal, !signal.headline.isEmpty,
              Self.reads(languages?.briefing, in: app) else { return nil }
        return Self.joinSignal(headline: signal.headline, delta: signal.delta)
    }
}
