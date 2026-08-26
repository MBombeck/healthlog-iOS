import Foundation
@testable import HealthLog
import Testing

/// **I1–I3 — the hub rows explain themselves, in one register.**
///
/// The operator did not read the mixture of explained and unexplained rows as
/// restraint; he read it as unfinished work („‚Konto' erklärt sich, ‚Geräte'
/// sagt nichts"). And he named the separator: middle dots „wirken KI-generiert".
///
/// R5-A1 (2026-08-23) writes both down and supersedes the U7 five-nil decision
/// by name. This suite is E12 — it holds the rule over the REAL row sets
/// (`HubRow.allCases` and `MoreScreen.Layout.renderedRows`) rather than over a
/// hand-kept list, so a row added later without a subtitle fails here instead of
/// quietly reintroducing the inconsistency.
///
/// Every clause resolves the copy through the catalogue in **both** languages.
/// Asserting on the key would check the English source literal and miss what a
/// German user actually reads, which is the entire subject of I2/I3.
@Suite("I1–I3 — jede Hub-Zeile trägt einen Untertitel, im selben Register")
struct SettingsSubtitleTests {
    private static let languages = ["de", "en"]

    private static func localized(_ key: String, _ language: String) -> String {
        String(
            localized: LocalizedStringResource(
                String.LocalizationValue(key),
                locale: Locale(identifier: language)
            )
        )
    }

    /// The register, as checks rather than as prose.
    ///
    /// - the middle dot is out (operator judgement: it reads machine-written);
    /// - `&` is out as an enumeration separator — R5-A1 names the comma as the
    ///   only one, and „A & B" is the same list wearing a different glyph;
    /// - no sentence-final period: these are labels, not sentences.
    private static func registerViolations(_ value: String, _ label: String) -> [String] {
        var out: [String] = []
        if value.contains("·") { out.append("\(label): contains a middle dot") }
        if value.contains(" & ") { out.append("\(label): uses & where the register is a comma") }
        if value.hasSuffix(".") { out.append("\(label): ends in a period") }
        return out
    }

    // MARK: - 1. Every hub row carries one

    @Test("Jede Zeile im Einstellungen-Hub hat einen katalogisierten Untertitel")
    func everyHubRowHasASubtitle() {
        var violations: [String] = []
        for row in HubRow.allCases {
            guard let key = row.subtitle else {
                violations.append("\(row.rawValue): no subtitle (the U7 nil)")
                continue
            }
            for language in Self.languages where Self.localized(key, language).isEmpty {
                violations.append("\(row.rawValue) [\(language)]: subtitle resolves empty")
            }
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: five rows still carry the U7 nil

            R5-A1 supersedes the U7 decision BY NAME: on a hub row the subtitle no longer \
            „falls when it only rephrases the title" — it gets rewritten until it carries \
            something. Offen: \(violations)
            """
        )
    }

    // MARK: - 2. One separator

    @Test("Komma ist das einzige Trennzeichen — kein Mittelpunkt, kein Schlusspunkt")
    func commaIsTheOnlySeparator() {
        var violations: [String] = []
        for row in HubRow.allCases {
            guard let key = row.subtitle else { continue }
            for language in Self.languages {
                violations += Self.registerViolations(
                    Self.localized(key, language),
                    "hub.\(row.rawValue) [\(language)]"
                )
            }
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: middle-dot and prose subtitles remain

            I3. The register is one short comma-separated clause. „Profil · Passkeys" is the \
            operator's own example of what reads machine-written. Offen: \(violations)
            """
        )
    }

    // MARK: - 3. The Mehr tab is the same surface

    @Test("Der Mehr-Tab folgt derselben Regel — alle Zeilen, dasselbe Register")
    func moreTabMatches() {
        var violations: [String] = []
        for row in MoreScreen.Layout.renderedRows {
            guard let key = row.subtitle else {
                violations.append("\(row.id): no subtitle")
                continue
            }
            for language in Self.languages {
                let value = Self.localized(key, language)
                if value.isEmpty {
                    violations.append("\(row.id) [\(language)]: subtitle resolves empty")
                }
                violations += Self.registerViolations(value, "more.\(row.id) [\(language)]")
            }
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the Mehr tab has the same inconsistency

            R5-A1 covers both hub surfaces, because they are one experience to the person \
            using them: the „Mehr" tab and the settings hub are the two places in the app \
            where a row's whole job is to say what is behind it. Offen: \(violations)
            """
        )
    }

    // MARK: - 4. Control — words only

    @Test("Kontrolle: Zeilen-Identität, Reihenfolge und Titel sind unangetastet")
    func rowIdentityIsUntouched() {
        #expect(
            HubRow.allCases.map(\.rawValue) == [
                "account", "notifications", "dashboard", "integrations", "devices",
                "siri", "mcp", "apiTokens", "sources", "ai", "serverSync", "export",
                "healthScore", "modules", "advanced", "about"
            ],
            "17-05 changes WORDS. A row that appeared, vanished or moved is a different change."
        )
        #expect(
            MoreScreen.Layout.renderedRows.map(\.id) == [
                "about_me", "vorsorge", "labs", "illness", "documents",
                "mental_wellbeing", "cycle", "cycle_settings", "nutrition",
                "environment", "personal_records", "achievements", "workouts",
                "measurements", "sign_out", "delete_account"
            ]
        )
        // Titles are not this plan's business either.
        #expect(HubRow.account.title == "Account")
        #expect(HubRow.devices.title == "Devices")
        #expect(MoreScreen.Layout.achievementsRow.title == "Achievements")
    }
}
