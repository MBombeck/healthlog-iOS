import Foundation
@testable import HealthLog
import Testing
#if canImport(UIKit)
    import UIKit
#endif

/// **1.4 B4-b — quiet surfaces: Today, Settings, Coach.**
///
/// The polish step removes and unifies. These pin the rules it settled so the
/// next change cannot quietly bring the noise back: one empty-state form, one
/// heading per single-row card, a section that is empty says it once, guides
/// in the reader's language, integration screens that read like the server
/// and sheet titles that fit beside their buttons.
@MainActor
@Suite("1.4 B4-b · ruhige Flächen: Heute, Einstellungen, Coach")
struct B4bCalmSurfacesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Screens
        .deletingLastPathComponent() // HealthLogTests
        .deletingLastPathComponent() // repo root

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func catalogValue(_ key: String, _ language: String) throws -> String? {
        let data = try Data(contentsOf: root.appendingPathComponent("HealthLog/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = strings[key] as? [String: Any]
        let locs = entry?["localizations"] as? [String: [String: [String: String]]]
        return locs?[language]?["stringUnit"]?["value"]
    }

    // MARK: - One empty-state form

    @Test("Today's empty and failed states sit on the page with one .secondary action")
    func todayStatesAreNotCards() throws {
        for path in [
            "HealthLog/Screens/Dashboard/DashboardNoDataEmptyState.swift",
            "HealthLog/Screens/Dashboard/DashboardMetricsErrorState.swift",
            "HealthLog/DesignSystem/Reorder/TileGridEmptyState.swift"
        ] {
            let code = try Self.source(path)
            #expect(!code.contains("HLCard {"), "\(path) wraps its empty state in a card")
            #expect(code.contains("variant: .secondary"), "\(path) action is not .secondary")
            #expect(!code.contains("variant: .restrained"))
            #expect(!code.contains("variant: .primary"))
        }
        let tiles = try Self.source("HealthLog/DesignSystem/Reorder/TileGridEmptyState.swift")
        #expect(!tiles.contains("message:"), "the hidden-tiles state repeated its title and button")
    }

    @Test("The empty labs screen offers one action; the scan stays in the toolbar")
    func emptyLabsHasOneAction() throws {
        let code = try Self.source("HealthLog/Screens/Labs/LabsScreen.swift")
        let start = try #require(code.range(of: "title: \"labs.empty.title\""))
        let block = code[start.lowerBound...].prefix(700)
        #expect(block.components(separatedBy: "HLButton(").count - 1 == 1)
        #expect(code.contains("showScanSheet = true"), "the scan must stay reachable from the toolbar menu")
    }

    // MARK: - Today, one card heading

    @Test("Today's cards share the tile header; the hero's section is an HLSectionLabel")
    func todayHasOneCardHeading() throws {
        for path in [
            "HealthLog/Screens/Dashboard/DashboardScreen+Sections.swift",
            "HealthLog/Screens/Dashboard/Tiles/RhythmEventsTile.swift",
            "HealthLog/Screens/Dashboard/ComplianceRingCard.swift"
        ] {
            #expect(try Self.source(path).contains("HLTileHeaderRow("), "\(path) has its own heading")
        }
        let hero = try Self.source("HealthLog/Screens/Dashboard/TodayHeroCard.swift")
        #expect(hero.contains("HLSectionLabel(verbatim: TodayHeroCopy.worthALook)"))
        #expect(!hero.contains(".textCase(.uppercase)"))
    }

    // MARK: - One heading per single-row card

    @Test("The coach settings no longer title a card with its only row's name")
    func coachSettingsCardsHaveOneHeading() throws {
        let code = try Self.source("HealthLog/Screens/Settings/Sub/SettingsCoachScreen.swift")
        #expect(!code.contains("title: \"Cadence suggestions\"\n"), "card title repeated the switch")
        // Only the kill-switch card keeps "Coach" as its title: it holds a
        // sentence, not a switch named "Coach aktivieren".
        #expect(code.components(separatedBy: "title: \"Coach\"\n").count - 1 == 1, "card title repeated \"Coach aktivieren\"")
        #expect(!code.contains("\"Open coach memory\""))
        #expect(!code.contains("\"Open past conversations\""))
        let window = try Self.source("HealthLog/Screens/Settings/Sub/CoachWindowCard.swift")
        #expect(window.contains("HLSettingsCard {"))
        #expect(!window.contains("settings.coach.window.pickerLabel"))
    }

    @Test("Account cards are their rows: no \"Open profile\", \"Manage sessions\" under a title")
    func accountCardsHaveOneHeading() throws {
        let code = try Self.source("HealthLog/Screens/Settings/Sub/SettingsAccountScreen.swift")
        for gone in ["\"Open profile\"", "\"settings.security.open\"", "\"sessions.card.manage\"", "\"resetData.card.action\""] {
            #expect(!code.contains(gone), "\(gone) is back")
        }
        #expect(code.components(separatedBy: "HLSettingsCard {").count - 1 == 6)
    }

    // MARK: - Sync diagnostics say an empty section once

    @Test("Nothing sent from this iPhone is one sentence for the card")
    func statsCardSaysNothingSentOnce() throws {
        #expect(SettingsHKSyncDiagnosticsScreen.nothingSent(nil))
        var log = HealthKitStatsUploadLog()
        #expect(SettingsHKSyncDiagnosticsScreen.nothingSent(log))
        let steps = try #require(SettingsHKSyncDiagnosticsScreen.statsUploadIdentifiers.first)
        log.uploads[steps] = HealthKitStatsUploadLog.Entry(at: Date(), trigger: "background", count: 1)
        #expect(!SettingsHKSyncDiagnosticsScreen.nothingSent(log))
        #expect(try Self.catalogValue("settings.hkdiag.stats.none_sent_all", "de")?.isEmpty == false)
        #expect(try Self.catalogValue("settings.hkdiag.stats.none_sent_all", "en")?.isEmpty == false)
    }

    @Test("A kind with nothing since the launch is a quiet row; any activity is not")
    func quietKindRows() {
        let idle = KindRow(kind: .weight, stats: HKSyncDiagnostics.KindStats(identifier: "weight"))
        #expect(idle.isQuiet)
        var read = HKSyncDiagnostics.KindStats(identifier: "weight")
        read.samplesReadTotal = 3
        #expect(!KindRow(kind: .weight, stats: read).isQuiet)
        let held = KindRow(kind: .weight, stats: HKSyncDiagnostics.KindStats(identifier: "weight"), registeredSkipCount: 2)
        #expect(!held.isQuiet)
    }

    @Test("Heart-rate gates read as words; the identifiers live in the report")
    func gateIdentifiersOnlyInTheReport() {
        for gate in HRBucketGate.allCases {
            let words = HKSyncDiagnosticsVocabulary.heartRateBucketGate(gate)
            #expect(!words.contains("(\(gate.rawValue))"), "\(gate) shows its identifier on screen")
            #expect(!words.isEmpty)
        }
        var ledger = HRBucketSyncLedger()
        ledger.lastEvent = HRBucketSyncLedger.Event(gate: .cutoverPending, at: Date(timeIntervalSince1970: 1_792_137_600), count: 0)
        let lines = SyncDiagnosticsReport.heartRateBucketLines(HRBucketDiagnosticsSnapshot(cutover: nil, ledger: ledger))
        #expect(lines.contains { $0.contains("cutoverPending") })
        #expect(lines.first?.hasPrefix("heart rate buckets:") == true)
    }

    // MARK: - Guides in the reader's language

    @Test("Every learn guide has a German and an English title, and a German edition")
    func learnGuidesAreLocalized() throws {
        #expect(HLLearnLinks.guides.count == 19)
        for guide in HLLearnLinks.guides {
            #expect(HLLearnLinks.localizedTitle(forSlug: guide.slug) != nil, "\(guide.slug) has no title key")
            let german = try Self.catalogValue("learn.guide.\(guide.slug)", "de")
            #expect(german?.isEmpty == false, "\(guide.slug) has no German title")
            #expect(try Self.catalogValue("learn.guide.\(guide.slug)", "en")?.isEmpty == false)
            #expect(HLLearnLinks.url(forSlug: guide.slug, languageCode: "de")?.absoluteString
                == "https://healthlog.dev/de/learn/\(guide.slug)")
            #expect(HLLearnLinks.url(forSlug: guide.slug, languageCode: "en") == guide.url)
        }
        #expect(HLLearnLinks.url(forSlug: "no-such-guide", languageCode: "de") == nil)
    }

    // MARK: - Integrations read like the server

    #if DEBUG
        @Test("The hermetic fixture answers both status routes with a decodable status")
        func integrationStatusFixturesDecode() throws {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let withings = HermeticFixtures.response(forPath: "/api/withings/status", method: "GET")
            #expect(withings.status == 200)
            #expect(try decoder.decode(WithingsStatus.self, from: withings.body).connected == false)
            let whoop = HermeticFixtures.response(forPath: "/api/whoop/status", method: "GET")
            #expect(whoop.status == 200)
            let whoopStatus = try decoder.decode(WhoopStatus.self, from: whoop.body)
            #expect(whoopStatus.connected == false)
            #expect(whoopStatus.configured == false)
        }
    #endif

    @Test("A failed status read shows a sentence for people, never the decoder's text")
    func integrationErrorsAreSentences() throws {
        let decoding = HLError.decoding("DecodingError.keyNotFound(CodingKeys(stringValue: \"connected\"))")
        #expect(!decoding.userFacingDescription.contains("DecodingError"))
        let withings = try Self.source("HealthLog/Screens/Settings/WithingsIntegrationScreen.swift")
        #expect(withings.contains("Text(error.userFacingDescription)"))
        #expect(!withings.contains("error.localizedDescription"))
        let whoop = try Self.source("HealthLog/Screens/Settings/WhoopIntegrationScreen.swift")
        #expect(!whoop.contains("return error.localizedDescription"))
    }

    // MARK: - Sheet titles fit beside their buttons

    #if canImport(UIKit)
        /// The German titles of this area's Cancel-and-Save sheets, measured in
        /// the inline bar's font against the room "Abbrechen" and "Speichern"
        /// leave on an iPhone 17 Pro (about 112 pt; 132 pt beside "Sichern").
        @Test("German sheet titles fit between Abbrechen and Speichern")
        func germanSheetTitlesFit() throws {
            let font = UIFont.systemFont(ofSize: 17, weight: .semibold)
            let budgets: [(key: String, width: CGFloat)] = [
                ("labs.add.sheetTitle", 112), ("labs.edit.title", 112), ("labs.scan.reviewTitle", 112),
                ("biomarker.add.sheetTitle", 112), ("biomarker.edit.title", 112),
                ("allergies.add.sheetTitle", 132), ("allergies.edit.title", 132),
                ("familyHistory.add.sheetTitle", 132), ("familyHistory.edit.title", 132),
                ("customMetric.edit.title", 132), ("customMetric.entry.edit.title", 132),
                ("documents.detail.conditionsSheetTitle", 132), ("New connector token", 123),
                ("settings.dashboard.heroItems.sheetTitle", 146),
                ("settings.security.twoFactor.enable.sheetTitle", 236),
                ("settings.security.twoFactor.disable.sheetTitle", 236),
                ("settings.security.twoFactor.recovery.sheetTitle", 236)
            ]
            for budget in budgets {
                let title = try #require(try Self.catalogValue(budget.key, "de"), "\(budget.key) has no German value")
                let width = (title as NSString).size(withAttributes: [.font: font]).width
                #expect(width <= budget.width, "\(budget.key) „\(title)“ is \(Int(width)) pt, room \(Int(budget.width)) pt")
            }
        }
    #endif

    // MARK: - Info symbols that did nothing

    @Test("Onboarding and the AI source picker carry no decorative info symbol")
    func noDecorativeInfoSymbols() throws {
        for path in ["HealthLog/Screens/Onboarding/AISourceStep.swift", "HealthLog/DesignSystem/AISourceChoicePicker.swift"] {
            #expect(try !(Self.source(path)).contains("\"info.circle\""), "\(path) shows an (i) that opens nothing")
        }
    }
}
