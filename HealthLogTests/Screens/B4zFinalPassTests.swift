import Foundation
@testable import HealthLog
import Testing
#if canImport(UIKit)
    import UIKit
#endif

/// **The last polish pass before the freeze.**
///
/// Pins what the pass settled, so a later change cannot quietly undo it: the
/// illness sheet titles fit beside their buttons, the cycle legend reads in
/// two calm columns, the cycle ring comes to rest like the score rings, the two coach
/// consent texts are short and still say everything, and the hermetic world
/// answers the sync handshake like a server.
@MainActor
@Suite("1.4 B4-z · Schlussdurchgang")
struct B4zFinalPassTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Screens
        .deletingLastPathComponent() // HealthLogTests
        .deletingLastPathComponent() // repo root

    private static func catalogValue(_ key: String, _ language: String) throws -> String? {
        let data = try Data(contentsOf: root.appendingPathComponent("HealthLog/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = strings[key] as? [String: Any]
        let locs = entry?["localizations"] as? [String: [String: [String: String]]]
        return locs?[language]?["stringUnit"]?["value"]
    }

    // MARK: - Sheet titles and the legend fit

    #if canImport(UIKit)
        /// "Neue Episode" and "Tag eintragen" sit between "Abbrechen" and
        /// "Speichern", which leave about 112 pt on an iPhone 17 Pro (the
        /// budget B4-b and B4-c measured). Both are close; the test keeps them
        /// from growing past it.
        @Test("The illness sheet titles fit between Abbrechen and Speichern")
        func illnessSheetTitlesFit() throws {
            let font = UIFont.systemFont(ofSize: 17, weight: .semibold)
            for key in ["illness.add.title", "illness.daylog.title"] {
                for language in ["de", "en"] {
                    let title = try #require(try Self.catalogValue(key, language))
                    let width = (title as NSString).size(withAttributes: [.font: font]).width
                    #expect(width <= 112, "\(key) [\(language)] „\(title)“ is \(Int(width)) pt")
                }
            }
        }

        /// Two columns leave each legend label about 145 pt beside its swatch
        /// on an iPhone 17 Pro; at the standard text size every label must
        /// take one line, so none breaks inside a word again.
        @Test("Every cycle legend label fits one line in two columns")
        func cycleLegendFitsTwoColumns() throws {
            #expect(CycleCalendarLegend.columnCount == 2)
            let font = UIFont.preferredFont(
                forTextStyle: .caption1,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            )
            let keys = [
                "cycle.legend.period", "cycle.legend.predictedPeriod", "cycle.legend.fertile",
                "cycle.legend.ovulation", "cycle.legend.symptoms", "cycle.legend.intercourse",
                "cycle.legend.otherEntries", "cycle.legend.today"
            ]
            for key in keys {
                for language in ["de", "en"] {
                    let label = try #require(try Self.catalogValue(key, language))
                    let width = (label as NSString).size(withAttributes: [.font: font]).width
                    #expect(width <= 140, "\(key) [\(language)] „\(label)“ is \(Int(width)) pt")
                }
            }
        }
    #endif

    // MARK: - Words seen in the final screenshot set

    @Test("A weekly summary's header names the week in the reader's language, the card names the dates")
    func weekHeaderIsLocalised() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        // Monday 5 October 2026, ISO week 41.
        let start = Date(timeIntervalSince1970: 1_791_201_600)
        let header = MeasurementBucketing.weekHeader(start: start, calendar: calendar)
        #expect(header == String(localized: "measurements.weekHeader \(41)"))
        #expect(!header.contains("("), "the header repeats the dates the card names")
        #expect(try Self.catalogValue("measurements.weekHeader %lld", "de") == "KW %lld")
        #expect(try Self.catalogValue("measurements.weekHeader %lld", "en") == "Week %lld")
    }

    @Test("No English proxy word or score name in the German score texts")
    func germanScoreTextsSayItInGerman() throws {
        let keys = [
            "A descriptive wellness proxy, not a training-grade or clinical recovery measure.",
            "A wellness proxy, not a recovery or clinical score.",
            "A descriptive activity-load proxy, not a clinical or training-grade load measure.",
            "sources.methodTitle.derivedScores"
        ]
        for key in keys {
            let german = try #require(try Self.catalogValue(key, "de"))
            #expect(!german.contains("Proxy"), "„\(german)“")
            #expect(!german.contains("Readiness"), "„\(german)“")
        }
    }

    @Test("The chart range picker's day is T in German and D in English")
    func dayRangeLabelIsLocalised() throws {
        #expect(try Self.catalogValue("range.label.day", "de") == "T")
        #expect(try Self.catalogValue("range.label.day", "en") == "D")
        #expect(ChartDetailStore.Range.day.label == String(localized: "range.label.day"))
    }

    @Test("A vital named mid-sentence in English starts in lower case")
    func illnessDriverMidSentence() {
        #expect(IllnessInsightsScreen.midSentence("Resting heart rate") == "resting heart rate")
        #expect(IllnessInsightsScreen.midSentence("Blood oxygen") == "blood oxygen")
        #expect(IllnessInsightsScreen.midSentence("").isEmpty)
    }

    @Test("A reference row names its year once")
    func referenceYearOnce() {
        #expect(HLSourceRow.visibleYear(name: "ESH 2023", year: 2023) == nil)
        #expect(HLSourceRow.visibleYear(name: "Kroenke 2001 (PHQ-9)", year: 2001) == nil)
        #expect(HLSourceRow.visibleYear(name: "American Lung Association", year: 2024) == 2024)
        #expect(HLSourceRow.visibleYear(name: "CDC NHANES", year: nil) == nil)
    }

    @Test("Personal records speak the reader's language and keep their labels whole")
    func personalRecordsReadInGerman() throws {
        #expect(PersonalRecordDTO.localizedUnit("steps") == String(localized: "dashboard.metric.unit.steps"))
        #expect(PersonalRecordDTO.localizedUnit("kg") == "kg")
        #expect(PersonalRecordDTO.localizedUnit("bpm") == "bpm")
        #expect(try Self.catalogValue("New record!", "de") == "Neuer Rekord!")
    }

    @Test("The Insights medication cards name a kind only when there is a real one")
    func insightsMedicationKindLine() {
        func medication(_ category: String?) -> Medication {
            Medication(
                id: "m", name: "Lisinopril", dose: "5 mg", category: category,
                schedule: MedicationSchedule(entries: [])
            )
        }
        #expect(InsightsMedicationsPage.categoryLine(medication(nil), isAsNeeded: false) == nil)
        #expect(InsightsMedicationsPage.categoryLine(medication("OTHER"), isAsNeeded: false) == nil)
        let asNeeded = InsightsMedicationsPage.categoryLine(medication(nil), isAsNeeded: true)
        #expect(asNeeded?.first?.isUppercase == true)
        #expect(InsightsMedicationsPage.categoryLine(medication("VITAMIN"), isAsNeeded: false) != nil)
    }

    @Test("The tile customization screen has a title that fits beside Bearbeiten and reset")
    func tileCustomizationTitleFits() throws {
        #expect(try Self.catalogValue("dashboard.customize.screenTitle", "de") == "Kacheln")
        #expect(try Self.catalogValue("dashboard.customize.screenTitle", "en") == "Tiles")
    }

    // MARK: - The cycle ring comes to rest

    @Test("The cycle ring moves in the score rings' window, then rests")
    func cycleRingMotionWindow() {
        #expect(HLCycleRing.motionActiveSeconds == WellnessTileMotion.activeSeconds)
        #expect(HLCycleRing.motionSettleSeconds == WellnessTileMotion.settleSeconds)
        #expect(HLCycleRing.movesNow(reduceMotion: false, lowPower: false, atRest: false))
        #expect(!HLCycleRing.movesNow(reduceMotion: false, lowPower: false, atRest: true))
        #expect(!HLCycleRing.movesNow(reduceMotion: true, lowPower: false, atRest: false))
        #expect(!HLCycleRing.movesNow(reduceMotion: false, lowPower: true, atRest: false))
    }

    // MARK: - Coach consent texts: short, and still complete

    private static func sentenceCount(_ text: String) -> Int {
        text.filter { ".!?".contains($0) }.count
    }

    @Test("Reading new documents: who, what, standing consent, off any time, in two sentences")
    func documentConsentIsShortAndComplete() throws {
        let german = try #require(try Self.catalogValue("settings.coach.docsAutoAi.description", "de"))
        for part in ["externe KI", "hochgeladene Dokument", "Laborwerte", "kurze Zusammenfassung", "dauerhafte Einwilligung", "jederzeit"] {
            #expect(german.contains(part), "DE is missing „\(part)“")
        }
        #expect(Self.sentenceCount(german) <= 2)
        let english = try #require(try Self.catalogValue("settings.coach.docsAutoAi.description", "en"))
        for part in ["external AI", "uploaded document", "lab values", "short summary", "standing consent", "anytime"] {
            #expect(english.contains(part), "EN is missing “\(part)”")
        }
        #expect(Self.sentenceCount(english) <= 2)
    }

    @Test("Data shared with the AI: what each level sends, in two sentences")
    func dataLevelIsShortAndComplete() throws {
        let german = try #require(try Self.catalogValue("settings.coach.insightsPrivacy.description", "de"))
        for part in ["„Aggregiert“", "zusammengefasste Trends", "„Volle Details“", "einzelne Werte", "KI"] {
            #expect(german.contains(part), "DE is missing „\(part)“")
        }
        #expect(Self.sentenceCount(german) <= 2)
        let english = try #require(try Self.catalogValue("settings.coach.insightsPrivacy.description", "en"))
        for part in ["Aggregated", "summarised trends", "Full detail", "individual values", "AI"] {
            #expect(english.contains(part), "EN is missing “\(part)”")
        }
        #expect(Self.sentenceCount(english) <= 2)
    }

    // MARK: - The hermetic world answers the sync handshake

    #if DEBUG
        @Test("The hermetic sync handshake decodes, so a walk's pull-to-refresh does not fail")
        func hermeticSyncStateDecodes() throws {
            let response = HermeticFixtures.response(forPath: "/api/sync/state", method: "GET")
            #expect(response.status == 200)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(ServerSyncStateDTO.self, from: response.body)
            #expect(state.userId == "hermetic-user")
            let workouts = HermeticFixtures.response(forPath: "/api/workouts", method: "GET")
            #expect(try decoder.decode(WorkoutListResponseDTO.self, from: workouts.body).workouts.isEmpty)
            for path in ["/api/mcp/connections", "/api/mcp/tokens", "/api/tokens"] {
                let list = HermeticFixtures.response(forPath: path, method: "GET")
                #expect(try decoder.decode([ApiTokenDTO].self, from: list.body).isEmpty, "\(path)")
            }
            let aboutMe = HermeticFixtures.response(forPath: "/api/coach/about-me", method: "GET")
            #expect(try decoder.decode(CoachAboutMeDTO.self, from: aboutMe.body).maxChars == 4000)
            // The sweep world names a server version (2FA and Server read it);
            // the shared world keeps answering none for the auth journeys.
            let version = try #require(SweepFixtures.response(forPath: "/api/version", method: "GET", query: []))
            let versionText = try #require(String(data: version.body, encoding: .utf8))
            #expect(versionText.contains("\"version\": \"1.43.10\""))
            let mfa = HermeticFixtures.response(forPath: "/api/auth/me/mfa", method: "GET")
            #expect(try decoder.decode(MfaStatus.self, from: mfa.body).totp.enabled == false)
        }
    #endif
}
