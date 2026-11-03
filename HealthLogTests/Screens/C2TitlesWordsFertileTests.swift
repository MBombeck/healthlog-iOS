import Foundation
@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// 1.4 C2 — three decisions after the screenshot review: English titles in
/// sentence case, "Serie" and "Ausgangswert" in German, and a fertile window
/// that stays visible on the light card.
@Suite("C2 — sentence-case titles, German words, fertile mark in light")
struct C2TitlesWordsFertileTests {
    // MARK: - 1. English titles

    /// The titles that read in Title Case before C2, with their English now.
    static let sentenceCaseTitles: [(key: String, en: String)] = [
        ("settings.hkdiag.title", "Sync diagnostics"),
        ("settings.hkdiag.nav_row", "Open sync diagnostics"),
        ("settings.applehealth_import.title", "Apple Health import"),
        ("health.permissions.title", "Apple Health access"),
        ("health.permissions.read_title", "Read access"),
        ("health.permissions.write_title", "Write access"),
        ("health.permissions.control_title", "You stay in control"),
        ("documents.optIn.title", "Enable documents"),
        ("labs.optIn.title", "Enable lab results"),
        ("Edit Profile", "Edit profile"),
        ("Privacy & Security", "Privacy & security"),
        ("appstore.disclaimer.card_title", "Not a medical device"),
        ("med.edit.critical_alarm", "Critical alarm"),
        ("dashboard.metric.title.bloodPressure", "Blood pressure"),
        ("dashboard.metric.title.bodyFat", "Body fat"),
        ("dashboard.metric.title.boneMass", "Bone mass"),
        ("dashboard.metric.title.glucose", "Blood glucose"),
        ("dashboard.metric.title.oxygenSaturation", "Oxygen saturation"),
        ("dashboard.metric.title.totalBodyWater", "Total body water"),
        ("dashboard.widget.vo2Max.title", "VO₂ max")
    ]

    @Test("English titles read in sentence case, proper names keep their capitals")
    func englishTitlesSentenceCase() throws {
        let catalog = try ParityCatalog.load()
        for sample in Self.sentenceCaseTitles {
            let entry = try #require(catalog.strings[sample.key], "missing key \(sample.key)")
            #expect(ParityCatalog.value(entry, language: "en") == sample.en, "\(sample.key)")
        }
    }

    // MARK: - 2. German words

    @Test("No German value says Streak or Baseline")
    func germanSaysSerieAndAusgangswert() throws {
        let catalog = try ParityCatalog.load()
        var offenders: [String] = []
        for (key, entry) in catalog.strings {
            guard let german = ParityCatalog.value(entry, language: "de") else { continue }
            if german.range(of: "streak", options: .caseInsensitive) != nil
                || german.range(of: "baseline", options: .caseInsensitive) != nil
            {
                offenders.append(key)
            }
        }
        #expect(offenders.isEmpty, "German still says Streak or Baseline: \(offenders.sorted())")
    }

    @Test("The new German words read in their sentences")
    func germanSentences() throws {
        let catalog = try ParityCatalog.load()
        let expected: [(String, String)] = [
            ("Best values, streaks, milestones", "Bestwerte, Serien, Meilensteine"),
            ("records.streaks.header", "Serien"),
            ("records.milestone.weekStreak", "Wochen-Serie"),
            ("records.milestone.monthStreak", "Monats-Serie"),
            ("illness.correlation.returns.title", "Zurück auf dem Ausgangswert"),
            ("illness.correlation.returns.notYet", "Noch nicht wieder auf dem Ausgangswert"),
            ("Deviation from baseline", "Abweichung vom Ausgangswert")
        ]
        for (key, german) in expected {
            let entry = try #require(catalog.strings[key], "missing key \(key)")
            #expect(ParityCatalog.value(entry, language: "de") == german, "\(key)")
        }
        // The deviation line is assembled from a template and a direction that
        // carries the article: "1,2 SD über dem Ausgangswert".
        let template = try #require(catalog.strings["illness.correlation.deviation.value"])
            .localizations?["de"]?.stringUnit?.value
        for (direction, word) in [("above", "über dem"), ("below", "unter dem"), ("unknown", "abseits vom")] {
            let entry = try #require(catalog.strings["illness.correlation.direction.\(direction)"])
            #expect(ParityCatalog.value(entry, language: "de") == word)
            let line = try String(format: #require(template), "1,2", word)
            #expect(line == "1,2 SD \(word) Ausgangswert")
        }
        // English is untouched.
        let streaks = try #require(catalog.strings["records.streaks.header"])
        #expect(ParityCatalog.value(streaks, language: "en") == "Streaks")
    }

    @Test("The streak heading comes from the catalog, not a literal")
    func streakHeadingIsCatalogKey() {
        #expect(PersonalRecordsScreen.Layout.streaksHeader == "records.streaks.header")
    }

    // MARK: - 3. Fertile mark in light

    @MainActor
    @Test("The fertile edge clears 3:1 on the light card")
    func fertileEdgeContrastLight() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let edge = UIColor(CyclePhasePalette.fertileEdgeLight).resolvedColor(with: light)
        let card = UIColor(HLSurface.secondary).resolvedColor(with: light)
        let ratio = HLContrastClamp.contrastRatio(foreground: edge, background: card)
        #expect(ratio >= HLContrastClamp.wcagAAUIRatio, "fertile edge \(ratio):1 on the light card")
    }

    @Test("Dark keeps the plain fertile wash, light adds the edge")
    func fertileMarkSource() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("HealthLog/Screens/Cycle/CycleCalendarGrid.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        #expect(src.contains("if scheme == .dark {\n                Circle().fill(fertile(scheme).opacity(0.24))"))
        #expect(src.contains("Circle().stroke(CyclePhasePalette.fertileEdgeLight, lineWidth: 1.2)"))
    }
}
