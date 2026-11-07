import Foundation

// 1.5.0 (L10N-MH) — the questionnaire text, copied from the server.
//
// The PHQ-9, GAD-7, WHO-5 and SCI items, stems, answer labels and the PHQ-9
// follow-up question are validated instruments: a changed word changes what
// they measure. The server keeps them in code
// (`src/lib/mental-health/wording/<instrument>/<language>.ts`), each saying
// whether it reproduces a published validated translation (with its `source`)
// or is a translation written for HealthLog. The app bundles exactly that
// text in `Resources/Questionnaires/questionnaire-wording.<language>.json`,
// written by `scripts/l10n/sync-questionnaire-wording.py --server-ref <tag>`
// and pinned by `QuestionnaireWordingLockstepTests`. Nothing here is a
// catalogue string: a translator working through `Localizable.xcstrings`
// never sees an item (`scripts/check-strings.sh` fails if one comes back).

/// One instrument's text in one language.
public struct QuestionnaireWording: Decodable, Sendable, Equatable {
    /// `true` when the text reproduces a published validated translation (the
    /// original for English); `false` for HealthLog's own translation, which
    /// the form labels and offers to switch to the English original.
    public let validated: Bool
    /// The published version reproduced (validated texts only).
    public let source: String?
    /// Stem texts by stem id (``MentalHealthInstrument/stemIDs``).
    public let stems: [String: String]
    /// The scored items in presentation order.
    public let items: [String]
    /// Answer labels per anchor group (`all`, or the SCI's groups), keyed by
    /// the score as text.
    public let anchors: [String: [String: String]]
    /// The PHQ-9's unscored follow-up question.
    public let functional: Functional?

    public struct Functional: Decodable, Sendable, Equatable {
        public let title: String
        public let anchors: [String: String]

        public func anchor(_ value: Int) -> String? {
            anchors[String(value)]
        }
    }

    public func stem(_ id: String?) -> String? {
        id.flatMap { stems[$0] }
    }

    public func item(_ index: Int) -> String? {
        items.indices.contains(index) ? items[index] : nil
    }

    public func anchor(group: String, value: Int) -> String? {
        anchors[group]?[String(value)]
    }
}

/// One bundled file: every instrument in one language, with the server tag it
/// was copied from.
struct QuestionnaireWordingFile: Decodable, Sendable {
    let language: String
    let serverRef: String
    let serverCommit: String
    let instruments: [String: QuestionnaireWording]
}

/// The bundled questionnaire text, read once per launch.
public enum QuestionnaireWordingCatalog {
    /// The server tag the bundled files were copied from.
    static let serverRef = "v1.46.6"

    static func resourceName(for language: AppLanguage) -> String {
        "questionnaire-wording.\(language.rawValue)"
    }

    private static let files: [AppLanguage: QuestionnaireWordingFile] = loadAll(bundle: .main)

    static func loadAll(bundle: Bundle) -> [AppLanguage: QuestionnaireWordingFile] {
        var out: [AppLanguage: QuestionnaireWordingFile] = [:]
        for language in AppLanguage.allCases {
            out[language] = load(language, bundle: bundle)
        }
        return out
    }

    static func load(_ language: AppLanguage, bundle: Bundle) -> QuestionnaireWordingFile? {
        let name = resourceName(for: language)
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Questionnaires"),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(QuestionnaireWordingFile.self, from: data),
            file.language == language.rawValue else { return nil }
        return file
    }

    /// The text of `instrument` in `language`, exactly as the server keeps it.
    /// `nil` only when the bundle lacks the file, which the lockstep tests
    /// rule out for every ``AppLanguage``.
    public static func wording(for instrument: MentalHealthInstrument, language: AppLanguage) -> QuestionnaireWording? {
        files[language]?.instruments[instrument.rawValue]
    }
}
