import CryptoKit
import Foundation
@testable import HealthLog
import Testing

/// **The questionnaire text is the server's, byte for byte (L10N-MH).**
///
/// `scripts/l10n/sync-questionnaire-wording.py --server-ref v1.46.6` copies the
/// PHQ-9, GAD-7, WHO-5 and SCI wording from the server modules into one file
/// per ``AppLanguage``. The hashes below pin those files: a hand edit, a
/// formatter pass or a half-run generator fails here. After a deliberate new
/// server tag, run the script and paste the hashes it prints.
@Suite("Questionnaire wording lockstep (server v1.46.6)")
struct QuestionnaireWordingLockstepTests {
    /// SHA-256 of `HealthLog/Resources/Questionnaires/questionnaire-wording.<lang>.json`.
    static let pinnedSHA256: [AppLanguage: String] = [
        .de: "1900e03bf14d7a890c23bdc06c70f41cecccf4694a553d55099f9e38fa81828d",
        .en: "42bac75d75fcb57ed0276666a27740e1dcaa471f640654586765807bfef405c2",
        .nl: "06bf378da96d1b1cd442e55a05e3aad70edf60ae42415c243c9e3ed26051e5c6",
        .ko: "90f7ecaa8553ea1b3d2fc547174df1c330505c6546c078dbca3b5b2ecd980ae3"
    ]

    @Test("Every interface language has a pinned file, and the file is what the generator wrote", arguments: AppLanguage.allCases)
    func fileMatchesPinnedHash(language: AppLanguage) throws {
        let pinned = try #require(Self.pinnedSHA256[language], "no pinned hash for \(language)")
        let data = try Data(contentsOf: Self.repoFile(language))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == pinned, "questionnaire-wording.\(language.rawValue).json differs from the generated file")
    }

    @Test("The app bundle carries the same file for every interface language", arguments: AppLanguage.allCases)
    func bundleCarriesTheFile(language: AppLanguage) throws {
        let bundled = try #require(
            Bundle.main.url(forResource: QuestionnaireWordingCatalog.resourceName(for: language), withExtension: "json"),
            "questionnaire-wording.\(language.rawValue).json is not in the app bundle"
        )
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: Self.repoFile(language)))
        let file = try #require(QuestionnaireWordingCatalog.load(language, bundle: .main))
        #expect(file.language == language.rawValue)
        #expect(file.serverRef == QuestionnaireWordingCatalog.serverRef)
        #expect(file.serverCommit.count == 40)
    }

    @Test(
        "Each instrument's text has the shape the scoring expects",
        arguments: AppLanguage.allCases,
        MentalHealthInstrument.allCases
    )
    func shapeMatchesInstrument(language: AppLanguage, instrument: MentalHealthInstrument) throws {
        let wording = try #require(QuestionnaireWordingCatalog.wording(for: instrument, language: language))
        #expect(wording.items.count == instrument.itemCount)
        #expect(wording.items.allSatisfy { !$0.isEmpty })
        for index in 0 ..< instrument.itemCount {
            #expect(wording.stem(instrument.stemIDs[index]) != nil, "\(instrument) item \(index) has no stem")
            for value in instrument.optionOrder {
                let label = wording.anchor(group: instrument.anchorGroup(forItem: index), value: value)
                #expect(label?.isEmpty == false, "\(instrument) item \(index) has no label for \(value)")
            }
        }
        if instrument.showsFunctionalFollowUp {
            let functional = try #require(wording.functional)
            #expect(!functional.title.isEmpty)
            #expect((0 ... 3).allSatisfy { functional.anchor($0)?.isEmpty == false })
        } else {
            #expect(wording.functional == nil)
        }
        #expect(wording.validated == (wording.source != nil))
    }

    /// Server v1.46.6: every instrument has a validated text in German, English
    /// and Dutch except the SCI, whose only validated text is the English
    /// original.
    @Test("Validated where the server says so, and nowhere else", arguments: AppLanguage.allCases)
    func validationFlags(language: AppLanguage) throws {
        for instrument in MentalHealthInstrument.allCases {
            let wording = try #require(QuestionnaireWordingCatalog.wording(for: instrument, language: language))
            let expected = instrument != .sci || language == .en
            #expect(wording.validated == expected, "\(instrument) in \(language)")
        }
    }

    /// Acceptance (a): the safety item in all three languages, word for word.
    @Test("PHQ-9 item 9 is the server text in every language")
    func safetyItemWording() throws {
        let expected: [AppLanguage: String] = [
            .de: "Gedanken, dass Sie lieber tot wären oder sich Leid zufügen möchten",
            .en: "Thoughts that you would be better off dead, or of hurting yourself in some way",
            .nl: "De gedachte dat u beter dood zou kunnen zijn of de gedachte uzelf op een bepaalde manier pijn te doen"
        ]
        for (language, text) in expected {
            let wording = try #require(QuestionnaireWordingCatalog.wording(for: .phq9, language: language))
            #expect(wording.item(8) == text, "\(language)")
        }
    }

    /// R2 3.4: the printed em dash before "of" reads as a comma; the gate gets
    /// no exception. The generator records the change in the file.
    @Test("PHQ-9 item 6 in Dutch carries the comma from the punctuation table")
    func dutchItemSixPunctuation() throws {
        let wording = try #require(QuestionnaireWordingCatalog.wording(for: .phq9, language: .nl))
        let item = try #require(wording.item(5))
        #expect(item.contains("uzelf, of het gevoel"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repoFile(.nl))) as? [String: Any]
        let changes = try #require(raw?["punctuation"] as? [[String: String]])
        #expect(changes.contains { $0["instrument"] == "PHQ9" && $0["field"] == "items[5]" && $0["shown"] == "uzelf, of het" })
    }

    @Test("No visible text carries a character the punctuation gate forbids", arguments: AppLanguage.allCases)
    func noForbiddenPunctuation(language: AppLanguage) throws {
        let forbidden: Set<Character> = ["\u{00B7}", "\u{2014}", "\u{2013}", "\u{2192}", "\u{2022}"]
        for instrument in MentalHealthInstrument.allCases {
            let wording = try #require(QuestionnaireWordingCatalog.wording(for: instrument, language: language))
            var texts = wording.items + Array(wording.stems.values)
            texts += wording.anchors.values.flatMap(\.values)
            if let functional = wording.functional {
                texts += [functional.title] + Array(functional.anchors.values)
            }
            for text in texts {
                #expect(!text.contains { forbidden.contains($0) }, "\(instrument)/\(language): \(text)")
            }
        }
    }

    // MARK: - Helpers

    static func repoFile(_ language: AppLanguage, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // MentalHealth
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .appendingPathComponent("HealthLog/Resources/Questionnaires")
            .appendingPathComponent("\(QuestionnaireWordingCatalog.resourceName(for: language)).json")
    }
}
