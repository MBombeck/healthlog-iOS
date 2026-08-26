import Foundation
import Testing

/// Build-8 (b239) coherence guard — enforces the checked-in parity glossary
/// (`HealthLogTests/Resources/ParityGlossary.json`) against the German catalog.
///
/// The glossary is the reviewed record of HealthLog's canonical German
/// terminology (Compliance→Therapietreue, Start→Dashboard, Arztbericht→
/// Gesundheitsbericht, …). This guard iterates every German `stringUnit` value
/// and fails when a **forbidden legacy term** appears — with per-term key
/// exceptions (e.g. `documents.kind.doctorReport` legitimately keeps
/// "Arztbericht" as the inbound document type). It reads the glossary JSON so
/// the convention can evolve without touching test code.
///
/// Only deterministic, catalog-wide sweeps are hard-enforced (see the JSON's
/// `forbiddenTerms`). Partial / per-hit drifts (Rekorde, Ovulation) live in the
/// advisory `canonicalTerms` record and are not scanned, to avoid false
/// positives on legitimately-retained wording.
@Suite("Glossary-Guard — verbotene Alt-Termini nicht in DE-Werten (mit Ausnahmen)")
struct GlossaryGuardTests {
    // MARK: - Glossary model

    struct Glossary: Decodable {
        let forbiddenTerms: [ForbiddenTerm]
        let canonicalTerms: [CanonicalTerm]
    }

    struct ForbiddenTerm: Decodable {
        let term: String
        let caseSensitive: Bool
        let canonical: String
        let exceptKeys: [String]
        let rationale: String
    }

    struct CanonicalTerm: Decodable {
        let forbidden: String
        let canonical: String
        let note: String
    }

    // MARK: - Loading

    private nonisolated static func loadGlossary(file: String = #filePath) throws -> Glossary {
        // <repo>/HealthLogTests/i18n/GlossaryGuardTests.swift
        //   → <repo>/HealthLogTests/Resources/ParityGlossary.json
        let glossaryURL = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // → HealthLogTests/i18n
            .deletingLastPathComponent() // → HealthLogTests
            .appendingPathComponent("Resources")
            .appendingPathComponent("ParityGlossary.json")
        let data = try Data(contentsOf: glossaryURL)
        return try JSONDecoder().decode(Glossary.self, from: data)
    }

    private nonisolated static func contains(_ haystack: String, _ needle: String, caseSensitive: Bool) -> Bool {
        caseSensitive
            ? haystack.contains(needle)
            : haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    // MARK: - Tests

    @Test("Glossary-Fixture ist wohlgeformt (forbiddenTerms + canonicalTerms vorhanden)")
    func glossaryFixtureLoads() throws {
        let glossary = try Self.loadGlossary()
        #expect(!glossary.forbiddenTerms.isEmpty, "forbiddenTerms leer — Fixture kaputt?")
        #expect(!glossary.canonicalTerms.isEmpty, "canonicalTerms leer — Fixture kaputt?")
        // The two headline conventions the plan names explicitly must be present.
        let canonicalForbidden = Set(glossary.canonicalTerms.map(\.forbidden))
        #expect(canonicalForbidden.contains("Compliance"))
        #expect(canonicalForbidden.contains("Start (Tab)"))
    }

    @Test("Kein verbotener Alt-Terminus in deutschen Katalog-Werten (Ausnahme-Keys respektiert)")
    func noForbiddenTermsInGermanValues() throws {
        let glossary = try Self.loadGlossary()
        let catalog = try ParityCatalog.load()
        var offenders: [String] = []
        for term in glossary.forbiddenTerms {
            let exceptions = Set(term.exceptKeys)
            for (key, entry) in catalog.strings where !exceptions.contains(key) {
                guard let value = ParityCatalog.value(entry, language: "de") else { continue }
                if Self.contains(value, term.term, caseSensitive: term.caseSensitive) {
                    offenders.append("'\(term.term)'→'\(term.canonical)' in \(key) :: \(value.prefix(64))")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            "Verbotene Alt-Termini in DE-Werten (\(offenders.count)): \(offenders.sorted().prefix(20))"
        )
    }

    @Test("Ausnahme-Keys existieren wirklich im Katalog (Ausnahmeliste nicht verrottet)")
    func exceptionKeysStillExist() throws {
        let glossary = try Self.loadGlossary()
        let catalog = try ParityCatalog.load()
        var stale: [String] = []
        for term in glossary.forbiddenTerms {
            for key in term.exceptKeys where catalog.strings[key] == nil {
                stale.append("\(term.term): \(key)")
            }
        }
        #expect(stale.isEmpty, "Ausnahme-Keys zeigen auf entfernte Katalog-Keys: \(stale)")
    }
}
