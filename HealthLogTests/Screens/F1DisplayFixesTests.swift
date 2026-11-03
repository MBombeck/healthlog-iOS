import Foundation
@testable import HealthLog
import SwiftUI
import Testing

// swiftlint:disable force_unwrapping

/// F1 (1.1.0) — four display defects the App-Store screenshots surfaced.
private enum F1Source {
    /// `<repo>/HealthLogTests/Screens/F1DisplayFixesTests.swift` → `<repo>`.
    /// Symlinks resolved on both sides (see `PercentFormatLintTests`).
    static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    static func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// Every `*.swift` under the given top-level directories.
    static func swiftFiles(under directories: [String]) -> [(relative: String, url: URL)] {
        let root = repoRoot()
        var result: [(String, URL)] = []
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(root.path) else { continue }
                result.append((String(path.dropFirst(root.path.count + 1)), url))
            }
        }
        return result
    }
}

// MARK: - 1. Rounding

@Suite("F1 · Prozent wird gerundet, nicht abgeschnitten")
struct F1PercentRoundingTests {
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")

    @Test("2 von 3 Einnahmen sind 67 %, nicht 66 %")
    func twoOfThreeIsSixtySeven() {
        let ratio = ComplianceSnapshot(scheduledToday: 3, takenToday: 2).ratio
        #expect(ComplianceRingCard.percentLabel(ratio, locale: de) == "67\u{202F}%")
        #expect(ComplianceRingCard.percentLabel(ratio, locale: en) == "67%")
    }

    @Test("Halbe Prozent runden kaufmännisch auf", arguments: [
        (1.0 / 3.0, 33), (2.0 / 3.0, 67), (0.005, 1), (0.125, 13), (0.994, 99), (0.995, 100), (0, 0), (1, 100)
    ])
    func roundsHalfAwayFromZero(fraction: Double, expected: Int) {
        #expect(HLNumberFormat.percentValue(ofFraction: fraction) == expected)
    }

    @Test("Ein nicht endlicher Bruch stürzt nicht ab")
    func nonFiniteFraction() {
        #expect(HLNumberFormat.percentValue(ofFraction: .nan) == 0)
        #expect(HLNumberFormat.percentValue(ofFraction: .infinity) == 0)
    }

    @Test("0 von 0 zeigt kein 0 %, sondern „nichts geplant“")
    func zeroOfZeroHasNoPercentage() {
        let empty = ComplianceSnapshot(scheduledToday: 0, takenToday: 0)
        #expect(!empty.hasSchedule, "the card keys its em-dash / „Nothing scheduled today“ copy off this")
    }

    /// Regression guard: no ratio → percent conversion in the shipped targets
    /// truncates with `Int(x * 100)` any more. Comment lines are skipped.
    @Test("Keine abschneidende Int(x * 100)-Umrechnung mehr in App, Widgets, Watch")
    func noTruncatingPercentConversion() throws {
        let truncating = #/Int\([^()\n]*\*\s*100(\.0)?\)/#
        let files = F1Source.swiftFiles(under: [
            "HealthLog", "HealthLogWidgets", "HealthLogWatch", "HealthLogWatchWidgets", "NotificationServiceExtension"
        ])
        #expect(files.count > 300, "only \(files.count) source files found — the path match is broken")
        var hits: [String] = []
        for (relative, url) in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), line.firstMatch(of: truncating) != nil else { continue }
                hits.append("\(relative):\(index + 1)")
            }
        }
        #expect(hits.isEmpty, "truncating percent conversions: \(hits)")
    }
}

// MARK: - 2. Locale-correct percent sign

@Suite("F1 · Prozentzeichen je Sprache")
struct F1PercentLocaleTests {
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")

    @Test("Deutsch: schmales geschütztes Leerzeichen vor %")
    func germanNarrowGap() {
        #expect(HLNumberFormat.percent(67, locale: de) == "67\u{202F}%")
        #expect(HLNumberFormat.percent(12.5, fractionDigits: 1, locale: de) == "12,5\u{202F}%")
        #expect(HLNumberFormat.percent(1234, locale: de) == "1.234\u{202F}%")
    }

    @Test("Englisch: kein Leerzeichen vor %")
    func englishNoGap() {
        #expect(HLNumberFormat.percent(67, locale: en) == "67%")
        #expect(HLNumberFormat.percent(12.5, fractionDigits: 1, locale: en) == "12.5%")
        #expect(HLNumberFormat.percent(fraction: 1, locale: en) == "100%")
    }

    @Test("Die Sprache setzt das Zeichen, auch vor die Zahl")
    func localePlacesTheSign() {
        #expect(HLNumberFormat.percent(67, locale: Locale(identifier: "tr_TR")) == "%67")
        #expect(HLNumberFormat.percent(67, locale: Locale(identifier: "fr_FR")) == "67\u{202F}%")
    }

    @Test("Arztbericht: Einnahmetreue in der Berichtssprache")
    func doctorReportAdherence() {
        let row = DoctorReportSpec.AdherenceBlock.Row(
            medicationId: "med-1",
            medicationName: "Levothyroxin",
            applicable: true,
            rate: 67,
            taken: 20,
            expected: 30
        )
        #expect(LocaleText.adherenceRow(row, windowDays: 30, locale: .en).contains("(67%)"))
        #expect(LocaleText.adherenceRow(row, windowDays: 30, locale: .de).contains("(67\u{202F}%)"))
    }
}

// MARK: - 3. Settings card subtitle

/// 1.4 B2-c — every settings-card subtitle wraps now, at every text size; the
/// F1 opt-in (`subtitleWraps`) and the one-line default it opted out of are
/// gone (HIG: wrap, never truncate).
@MainActor
@Suite("F1 · Erklärtext in Einstellungs-Karten wird nicht abgeschnitten")
struct F1SettingsCardSubtitleTests {
    private static let short: LocalizedStringKey = "Konto"
    private static let long: LocalizedStringKey =
        "Die Liste kommt von deinem Server. Angehakt heißt: Diese Daten sind enthalten."

    @Test("Der Untertitel bricht bei Standardgröße um")
    func wrapsAtStandardSize() throws {
        let shortHeight = try Self.height(of: Self.card(subtitle: Self.short))
        let longHeight = try Self.height(of: Self.card(subtitle: Self.long))
        #expect(longHeight > shortHeight + 1, "the long subtitle was cut to one line (\(longHeight)pt vs \(shortHeight)pt)")
    }

    @Test("Kein Untertitel kappt sich selbst auf eine Zeile")
    func noOneLineCapLeft() throws {
        let source = try F1Source.read("HealthLog/DesignSystem/HLSettingsCard.swift")
        #expect(!source.contains("subtitleWraps"))
        #expect(!source.contains(".lineLimit(wraps"))
    }

    private static func card(subtitle: LocalizedStringKey) -> some View {
        HLSettingsCard(icon: "checklist", title: "Was", subtitle: subtitle) {
            Text("Body").font(.hlBody)
        }
    }

    private static func height(of view: some View, width: CGFloat = 320) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(.large)
        )
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "card failed to render")
        return image.size.height
    }
}

// MARK: - 4. Insights empty state

@MainActor
@Suite("F1 · Insights-Leerzustand nur mit Grund", .serialized, .mockURLSession)
struct F1InsightsEmptyStateTests {
    private static func resolve(
        delivered: Bool = true,
        cardsEmpty: Bool = true,
        loading: Bool = false,
        error: Bool = false,
        data: Bool
    ) -> InsightsEmptyState? {
        InsightsEmptyState.resolve(
            hasServer: true,
            hasDeliveredCards: delivered,
            cardsEmpty: cardsEmpty,
            isLoading: loading,
            hasError: error,
            hasRecordedData: data
        )
    }

    /// 1.4 B2 — with data there is no empty card at all, whatever the AI
    /// layer's state: the "no AI summary right now" card is gone.
    @Test("Daten da: keine Leerkarte, auch ohne KI")
    func dataMeansNoCard() {
        #expect(Self.resolve(data: true) == nil)
    }

    @Test("Keine Daten: „erfasse mehr Messungen“ ist dann wahr")
    func noData() {
        #expect(Self.resolve(data: false) == .needsData)
    }

    @Test("Nur wenn der Server wirklich keine Karten geliefert hat")
    func onlyOnADeliveredEmptyList() {
        #expect(Self.resolve(delivered: false, data: false) == nil, "never loaded ≠ empty")
        #expect(Self.resolve(cardsEmpty: false, data: false) == nil)
        #expect(Self.resolve(loading: true, data: false) == nil)
        #expect(Self.resolve(error: true, data: false) == nil)
        #expect(InsightsEmptyState.resolve(
            hasServer: false, hasDeliveredCards: true, cardsEmpty: true, isLoading: false,
            hasError: false, hasRecordedData: false
        ) == nil)
    }

    @Test("Store: leere Kartenliste zählt erst, wenn insights/cards geantwortet hat")
    func storeMarksDeliveredCards() async {
        let api = AISurfaceHarness.makeAPI()
        MockURLProtocol.install { request in
            if request.targets("/api/insights/cards") { return AISurfaceHarness.ok(request, #"{"data":[]}"#) }
            return AISurfaceHarness.ok(
                request,
                #"{"data":{"summary":null,"recommendations":[],"citations":[],"warnings":[],"totalMeasurements":42}}"#
            )
        }
        let store = InsightsStore(repo: InsightsRepository(api: api))
        #expect(!store.hasDeliveredCards)
        await store.load()
        #expect(store.hasDeliveredCards)
        #expect(store.cards.isEmpty)
        #expect(store.comprehensive?.digest?.totalMeasurements == 42)
        store.clearOnLogout()
        #expect(!store.hasDeliveredCards)
    }

    @Test("Store: ein fehlgeschlagener Abruf ist keine leere Liste")
    func storeFailedCardsAreNotDelivered() async {
        let api = AISurfaceHarness.makeAPI()
        MockURLProtocol.install { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"boom"}"#.utf8))
        }
        let store = InsightsStore(repo: InsightsRepository(api: api))
        await store.load()
        #expect(!store.hasDeliveredCards)
        #expect(store.error != nil)
    }
}
