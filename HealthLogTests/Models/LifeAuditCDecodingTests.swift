// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **AUDITC (1.5.0, #132)** — the `auditC` block of the read route, read
/// leniently, and the result shown exactly as the server scored it: the
/// verdict comes from `aboveCutoff` alone, a profile without a sex shows the
/// sum only, and an instrument this build cannot render as delivered is not
/// offered.
@Suite("LifeAuditCDecoding")
struct LifeAuditCDecodingTests {
    typealias Fx = LifeCircumstancesFixtures

    static func result(
        total: Int = 4,
        locale: String = "de",
        cutoff: String = Self.s3Female,
        above: String = "true"
    ) -> String {
        #"{"id":"a-1","takenAt":"2026-10-01T08:00:00.000Z","items":[2,1,1],"totalScore":\#(total),"locale":"\#(locale)","#
            + #""cutoff":\#(cutoff),"aboveCutoff":\#(above),"validatedLocale":true}"#
    }

    static let s3Female = #"{"value":4,"sex":"female","source":"S3_ALCOHOL_DE","#
        + #""sourceLabel":"S3-Leitlinie Screening, Diagnose und Behandlung alkoholbezogener Störungen (AWMF 076-001) (Deutschland)","#
        + #""sourceUrl":"https://alkoholleitlinie.de/diagnostik/test-audit-c/"}"#

    static func instrument(items: Int = 3, optionValue: Int = 4, stem: String = "Stem", locale: String = "de") -> String {
        let one = #"{"stem":"\#(stem)","options":[{"value":0,"label":"Never"},{"value":\#(optionValue),"label":"Daily"}]}"#
        let list = Array(repeating: one, count: items).joined(separator: ",")
        return #"{"items":[\#(list)],"locale":"\#(locale)","validatedLocale":true,"standardDrink":"One drink.","attribution":"WHO."}"#
    }

    static func block(latest: String = result(), history: String? = nil, instrument: String = instrument()) -> String {
        let rows = history ?? #"{"id":"a-1","takenAt":"2026-10-01T08:00:00.000Z","totalScore":4},"#
            + #"{"id":"a-0","takenAt":"2025-01-01T08:00:00.000Z","totalScore":9}"#
        return #"{"latest":\#(latest),"history":[\#(rows)],"offerDue":false,"instrument":\#(instrument)}"#
    }

    private func decode(_ block: String?) throws -> LifeCircumstances {
        try Fx.decode(Fx.payload(sections: [], auditC: block))
    }

    private func localized(_ key: String, _ language: String) -> String? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    // MARK: - Server with and without the block (rule 10)

    @Test("a server without auditC leaves it nil and the page still loads; with it, it decodes")
    func serverWithAndWithoutBlock() throws {
        let without = try decode(nil)
        #expect(without.auditC == nil)
        #expect(without.derived.packYears?.value == 10.5, "the rest of the page is unaffected")

        let with = try #require(try decode(Self.block()).auditC)
        #expect(with.offerDue == false)
        #expect(with.history.map(\.id) == ["a-1", "a-0"])
        #expect(with.history.map(\.totalScore) == [4, 9])
        let instrument = try #require(with.instrument)
        #expect(instrument.items.count == 3)
        #expect(instrument.locale == "de")
        #expect(instrument.standardDrink == "One drink.")
        #expect(instrument.attribution == "WHO.")
    }

    // MARK: - Acceptance of #132

    @Test("German, a woman, sum 4: 'at or above the screening cut-off' with the S3 source")
    func germanWomanSumFour() throws {
        let latest = try #require(try decode(Self.block()).auditC?.latest)
        #expect(latest.totalScore == 4)
        guard case let .known(cutoff) = latest.cutoff else {
            Issue.record("the S3 cut-off did not decode")
            return
        }
        #expect(cutoff.value == 4)
        #expect(cutoff.source == "S3_ALCOHOL_DE")
        #expect(cutoff.sourceLabel.hasPrefix("S3-Leitlinie"))
        #expect(cutoff.sourceURL?.absoluteString == "https://alkoholleitlinie.de/diagnostik/test-audit-c/")
        #expect(AuditCResultBlock.verdict(latest) == String(localized: "life.auditC.result.above \(4)"))
        #expect(
            localized("life.auditC.result.above %lld", "de") == "Am oder über dem Screening-Grenzwert von %lld.",
            "the German verdict is the server's records.life.auditC.above"
        )
        #expect(localized("life.auditC.result.score %lld", "de") == "%lld von 12 Punkten")
    }

    @Test("no sex in the profile: cutoff null shows the sum and the server's 'sum only' sentence, no source")
    func noSexSumOnly() throws {
        let latest = try #require(try decode(Self.block(latest: Self.result(cutoff: "null", above: "null"))).auditC?.latest)
        #expect(latest.cutoff == .noSex)
        #expect(latest.aboveCutoff == nil)
        #expect(AuditCResultBlock.verdict(latest) == String(localized: "life.auditC.result.noCutoff"))
        #expect(localized("life.auditC.result.noCutoff", "de") == "Ohne Angabe zum Geschlecht im Profil zeigen wir nur die Summe.")
    }

    // MARK: - Nothing computed on the device

    /// POLISH-C (C8) — on iOS 26.5 the combined label lost the source line
    /// (MATRIX M4). The label is spelled out now and names the source.
    @Test("the VoiceOver label carries every line, the source included; no source without a cut-off")
    func accessibilityLabelNamesTheSource() throws {
        let latest = try #require(try decode(Self.block()).auditC?.latest)
        guard case let .known(cutoff) = latest.cutoff else {
            Issue.record("the S3 cut-off did not decode")
            return
        }
        let label = AuditCResultBlock.accessibilityText(latest)
        #expect(label.contains(String(localized: "life.auditC.result.score \(4)")))
        #expect(try label.contains(#require(AuditCResultBlock.verdict(latest))))
        #expect(label.hasSuffix(String(localized: "life.source \(cutoff.sourceLabel)")))

        let sumOnly = try #require(try decode(Self.block(latest: Self.result(cutoff: "null", above: "null"))).auditC?.latest)
        #expect(!AuditCResultBlock.accessibilityText(sumOnly).contains(String(localized: "life.source \(cutoff.sourceLabel)")))
    }

    @Test("the verdict is the server's aboveCutoff, never a comparison of the sum with the cut-off")
    func verdictIsTheServers() throws {
        // A sum of 4 against a cut-off of 4 would be "above"; the server says
        // below, so the app says below.
        let below = try #require(try decode(Self.block(latest: Self.result(above: "false"))).auditC?.latest)
        #expect(AuditCResultBlock.verdict(below) == String(localized: "life.auditC.result.below \(4)"))

        // A cut-off without a verdict says nothing about it.
        let silent = try #require(try decode(Self.block(latest: Self.result(above: "null"))).auditC?.latest)
        #expect(AuditCResultBlock.verdict(silent) == nil)

        // A cut-off this build cannot read: sum only, and no claim about a sex.
        let odd = try #require(try decode(Self.block(latest: Self.result(cutoff: #"{"value":"four"}"#))).auditC?.latest)
        #expect(odd.cutoff == .unreadable)
        #expect(AuditCResultBlock.verdict(odd) == nil)
    }

    // MARK: - Lenient reading

    @Test("an instrument that is not three items with answers 0 to 4 is not offered; the rest stays")
    func unusableInstrumentRefused() throws {
        for broken in [Self.instrument(items: 2), Self.instrument(optionValue: 5), Self.instrument(stem: ""), "null"] {
            let auditC = try #require(try decode(Self.block(instrument: broken)).auditC)
            #expect(auditC.instrument == nil, "\(broken)")
            #expect(auditC.latest?.totalScore == 4)
            #expect(auditC.history.count == 2)
        }
    }

    @Test("a broken history row is skipped, an unreadable latest is absent, never a zero")
    func brokenRowsSkipped() throws {
        let rows = #"{"id":"a-1","takenAt":"2026-10-01T08:00:00.000Z","totalScore":4},{"id":"broken"},"#
            + #"{"id":"a-2","takenAt":"2024-01-01T08:00:00.000Z","totalScore":0}"#
        let auditC = try #require(try decode(Self.block(latest: #"{"id":"x"}"#, history: rows)).auditC)
        #expect(auditC.history.map(\.id) == ["a-1", "a-2"])
        #expect(auditC.latest == nil)
    }

    @Test("the request body carries the offered locale, source IOS, the retry identity and a UTC takenAt")
    func requestBody() throws {
        let taken = Date(timeIntervalSince1970: 1_793_000_000)
        let body = AuditCBody(AuditCSubmission(
            items: [1, 2, 0], takenAt: taken, timeZone: "Europe/Berlin", locale: "en", externalId: "ext-1"
        ))
        let data = try JSONEncoder.hlDefault.encode(body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["items"] as? [Int] == [1, 2, 0])
        #expect(json["locale"] as? String == "en")
        #expect(json["source"] as? String == "IOS")
        #expect(json["externalId"] as? String == "ext-1")
        #expect(json["tz"] as? String == "Europe/Berlin")
        let stamp = try #require(json["takenAt"] as? String)
        #expect(stamp.hasSuffix("Z"))
        #expect(ISO8601DateFormatter.fractional.date(from: stamp) == taken)
    }
}
