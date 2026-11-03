import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **1.4 B2-c — Settings, labs and records follow the info pattern.**
///
/// The explanations that stood under or between cards moved behind one (i)
/// per screen; these pin that the sheets carry them (catalogued, not keys
/// echoing themselves) and the two small rules that replaced a hint line: the
/// share-link expiry range and the web-only overview sections.
@MainActor
@Suite("1.4 B2-c · Einstellungen, Labore und Akte erklären sich über das eine (i)")
struct B2cSettingsInfoPatternTests {
    private static func isCatalogued(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return !text.hasPrefix("settings.") && !text.hasPrefix("anamnesis.")
    }

    @Test("Die Sync-Diagnose bündelt ihr Glossar im Info-Sheet")
    func syncDiagnosticsGlossary() {
        let info = SettingsHKSyncDiagnosticsScreen().info
        #expect(!info.isEmpty)
        #expect(Self.isCatalogued(info.about))
        // Sources, terms, server view, day totals, held/refused, background limits.
        #expect(info.sections.count == 6)
        for section in info.sections {
            #expect(Self.isCatalogued(section.title), "uncatalogued section title \(section.title)")
            #expect(!section.paragraphs.isEmpty)
            #expect(section.paragraphs.allSatisfy { Self.isCatalogued($0) })
        }
        // A glossary of app terms is not medical: no references, no footer.
        #expect(!info.isMedical)
    }

    @Test("Anamnese, Siri und API-Tokens haben ein (i) mit Inhalt")
    func smallScreensCarryTheirInfo() {
        for info in [SettingsAnamnesisScreen.info, SettingsSiriShortcutsScreen.info, SettingsApiTokensScreen.info] {
            #expect(!info.isEmpty, "\(info.identifier) would render no (i)")
            #expect(Self.isCatalogued(info.about), "\(info.identifier) about is a raw key")
        }
        #expect(SettingsAnamnesisScreen.info.sections.count == 1)
    }

    @Test("Das Ablaufdatum eines Links reicht von morgen bis 90 Tage")
    func shareLinkExpiryRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = Date(timeIntervalSince1970: 1_792_137_600)
        let range = UnifiedSharingScreen.expiryRange(now: now, calendar: calendar)
        #expect(range.lowerBound == calendar.date(byAdding: .day, value: 1, to: now))
        #expect(range.upperBound == calendar.date(byAdding: .day, value: UnifiedSharingStore.maxExpiryDays, to: now))
    }

    @Test("Web-only Abschnitte behalten beim Umsortieren ihren Platz")
    func webOnlySectionsKeepTheirSlots() {
        let all = ["vitals", InsightsLayoutSectionId.ecg, "trends", InsightsLayoutSectionId.periodReview, "signals"]
        // The phone shows vitals, trends, signals; the user moved signals first.
        let merged = InsightsOverviewSectionsList.merge(shown: ["signals", "vitals", "trends"], into: all)
        #expect(merged == ["signals", InsightsLayoutSectionId.ecg, "vitals", InsightsLayoutSectionId.periodReview, "trends"])
        #expect(Set(merged) == Set(all))
    }

    @Test("Einstellungs-Zeilen kappen ihren Untertitel nicht mehr")
    func settingsRowSubtitleWraps() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("HealthLog/DesignSystem/HLSettingsRow.swift"),
            encoding: .utf8
        )
        #expect(!source.contains(".lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)"))
    }
}
