import Foundation
import Testing

/// **1.0.3 — App Review 1.4.1, ruling R12.** Locks the copy and the citation
/// placements that answer audit rows 3, 10, 14 and 17.
///
/// These are deliberately *source- and catalog-level* assertions rather than
/// rendered-view ones. What Apple rejected is the sentence, not the layout: a
/// verdict about the user's own drug, a triage instruction the app cannot
/// support, a diagnostic category with its qualifier hidden one tap away. A
/// test that only checks "a card renders" would go green again the day someone
/// restores the old wording, which is exactly the regression worth catching.
///
/// The catalog is read as JSON on purpose. `String(localized:)` resolves
/// against whatever locale the runner happens to be in, so it can lock at most
/// one language; the ruling fixes BOTH, and a German-only softening with the
/// English verdict left standing is the failure mode that reaches a reviewer.
@Suite("App Review 1.4.1 — medical copy and citation placement")
struct AppReview141MedicalCopyTests {
    // MARK: - Audit row 3 — BP × medication reads as association, never effect

    @Test("the two drug-effect verdicts are gone from the catalog and the panel")
    func drugEffectVerdictsAreRetired() throws {
        let keys = try Self.catalogKeys()
        let panel = try Self.source("HealthLog/Screens/Insights/CorrelationsPanel.swift")
        for retired in [
            "Weak hint that intake days lower blood pressure.",
            "Data show no clear BP effect of your intake rate."
        ] {
            #expect(!keys.contains(retired), "R12: '\(retired)' must not survive anywhere in the catalog.")
            #expect(!panel.contains(retired), "R12: the panel must not reference '\(retired)'.")
        }
    }

    @Test("both replacement lines say it is a within-user comparison, in EN and DE")
    func associationOnlyWordingIsLocked() throws {
        let catalog = try Self.catalog()
        let weakBranch = try #require(catalog["correlations.bpMedication.lowerOnIntakeDays"])
        #expect(weakBranch.en == """
        On days you logged an intake, your blood pressure readings were slightly lower. \
        This compares your own days with each other and cannot show whether the medicine caused it.
        """)
        #expect(weakBranch.de == """
        An Tagen mit erfasster Einnahme waren deine Blutdruckwerte etwas niedriger. \
        Das vergleicht deine eigenen Tage miteinander und kann nicht zeigen, \
        ob das Medikament die Ursache ist.
        """)

        let flat = try #require(catalog["correlations.bpMedication.noDifference"])
        #expect(flat.en == """
        Your readings on intake days and other days look about the same. \
        That is a comparison of your own days, not a statement about the medicine.
        """)
        #expect(flat.de == """
        Deine Werte an Einnahme- und anderen Tagen sehen etwa gleich aus. \
        Das ist ein Vergleich deiner eigenen Tage, keine Aussage über das Medikament.
        """)
    }

    @Test("the reading instruction and its Sources link are no longer gated off")
    func correlationDisclaimerIsUngated() throws {
        // Comments are stripped first: the code that removed the flag explains
        // itself by naming it, and a check that cannot tell an explanation from
        // a declaration would forbid documenting the fix.
        let panel = try Self.code(of: "HealthLog/Screens/Insights/CorrelationsPanel.swift")
        // Every one of the three call sites used to pass `showsDisclaimer:
        // false`, so neither the note nor the citation ever reached a screen.
        // The flag is removed rather than flipped — a gate that can be closed
        // again is the defect, not the value it currently holds.
        #expect(!panel.contains("showsDisclaimer"), "The disclaimer must not sit behind a per-call-site flag.")
        #expect(panel.contains("Text(\"correlations.disclaimer\")"))
        #expect(panel.contains("HLSourcesLink(topic: .correlations)"))
        for site in [
            "HealthLog/Screens/Insights/InsightsMetricScreen+Sections.swift",
            "HealthLog/Screens/Insights/Sub/InsightsMedicationsPage.swift",
            "HealthLog/Screens/Insights/Sub/InsightsMoodPage.swift"
        ] {
            let callSite = try Self.code(of: site)
            #expect(!callSite.contains("showsDisclaimer"), "\(site) must not re-introduce the gate.")
        }
    }

    // MARK: - Audit row 14 — the red-flags footer is a pattern, not triage

    @Test("the red-flags footer no longer instructs the user to seek medical care")
    func redFlagFooterIsAPatternNotAFinding() throws {
        let catalog = try Self.catalog()
        let footer = try #require(catalog["illness.correlation.redFlags.seekCare"])
        #expect(footer.en == """
        This is a pattern in your own recorded values, not a clinical finding. \
        If it keeps happening, it is worth mentioning to your doctor.
        """)
        #expect(footer.de == """
        Das ist ein Muster in deinen eigenen Werten, kein klinischer Befund. \
        Wenn es sich wiederholt, lohnt es sich, das ärztlich anzusprechen.
        """)
        #expect(!footer.en.contains("seek medical care"))
        #expect(!footer.de.contains("ärztliche Hilfe"))

        // The heading moved with it: "Worth a closer look" over "Sustained
        // fever" reads as a clinical flag; "Worth mentioning" reads as a note
        // to take to an appointment, which is all the data supports.
        let title = try #require(catalog["illness.correlation.redFlags.title"])
        #expect(title.en == "Worth mentioning")
        #expect(title.de == "Erwähnenswert")
    }

    // MARK: - Audit row 17 — the remaining directly-reachable surfaces cite

    @Test("the sleep and illness surfaces a reviewer reaches directly carry a Sources link")
    func remainingSurfacesCarryTheirCitation() throws {
        let expected: [(path: String, topic: String)] = [
            ("HealthLog/Screens/Insights/Sub/SleepStageCompositionCard.swift", ".sleepRhythm"),
            ("HealthLog/Screens/Insights/Sub/SleepHypnogramScreen.swift", ".sleepRhythm"),
            ("HealthLog/Screens/Illness/IllnessInsightsScreen.swift", ".illnessRecovery"),
            // The sleep-debt claim is already cited in the block's own
            // rhythm section, directly under `sleep.debt.computedInfo`. Asserted
            // here so a later refactor of that section cannot quietly drop it.
            ("HealthLog/Screens/Insights/Sub/SleepRhythmSection.swift", ".sleepRhythm")
        ]
        for (path, topic) in expected {
            let src = try Self.source(path)
            #expect(src.contains("HLSourcesLink(topic: \(topic))"), "\(path) must cite \(topic).")
        }
        // The sleep-debt claim itself — `sleep.debt.computedInfo`, the figure
        // audit row 17 names — must still be the thing being cited, not merely
        // a link somewhere in the same file.
        let rhythm = try Self.source("HealthLog/Screens/Insights/Sub/SleepRhythmSection.swift")
        #expect(rhythm.contains("Text(\"sleep.debt.computedInfo\")"))
        #expect(
            rhythm.contains("computedNote"),
            "The debt card renders its computed-figure note, which the citation sits under."
        )
    }

    // MARK: - Helpers

    private struct Entry {
        let en: String
        let de: String
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Compliance/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // repo root
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// A file's source with whole-line comments dropped — the same trick
    /// `InsightsMetricStatusCardTests.codeBody(of:)` uses, so an "X must not
    /// appear" assertion reads declarations rather than the prose explaining
    /// why X was removed.
    private static func code(of relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
            }
            .joined(separator: "\n")
    }

    /// The app catalog, flattened to `key → (en, de)`. Entries missing either
    /// locale are dropped — `check-strings.sh` owns that completeness check;
    /// this suite only asserts the wording of the keys it names.
    private static func catalog() throws -> [String: Entry] {
        let url = repoRoot.appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = root?["strings"] as? [String: Any] ?? [:]
        var out: [String: Entry] = [:]
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any],
                  let locales = entry["localizations"] as? [String: Any],
                  let en = value(in: locales, locale: "en"),
                  let de = value(in: locales, locale: "de") else { continue }
            out[key] = Entry(en: en, de: de)
        }
        return out
    }

    /// Every key in the catalog, including entries this suite's `catalog()`
    /// drops for want of a locale — "this string is gone" has to mean gone.
    private static func catalogKeys() throws -> Set<String> {
        let url = repoRoot.appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return Set((root?["strings"] as? [String: Any] ?? [:]).keys)
    }

    private static func value(in locales: [String: Any], locale: String) -> String? {
        guard let branch = locales[locale] as? [String: Any],
              let unit = branch["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }
}
