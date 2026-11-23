import Foundation
@testable import HealthLog
import Testing

/// The same number reads the same way wherever it appears: the usual-range
/// sentence names the unit of the reading it quotes, the sleep tile speaks the
/// app's language, and an error banner with its own retry button does not say
/// "try again" a second time.
@Suite("Value consistency across surfaces")
struct ValueConsistencyTests {
    private static let imperial = UnitPreferences(weight: .lb, glucose: .mgdL, system: .imperial)

    private static func strip(_ baseline: String) throws -> CoachReadStrip {
        let json = #"{"data":{"baseline":\#(baseline),"learning":false,"driver":null},"error":null}"#
        return try JSONDecoder.hlDefault.decode(Envelope.self, from: Data(json.utf8)).data
    }

    private struct Envelope: Decodable {
        let data: CoachReadStrip
    }

    @Test("The usual-range sentence quotes the latest reading with its unit")
    func latestReadingCarriesUnit() throws {
        let weight = try Self.strip(
            #"{"low":78.4,"high":80.2,"latest":79.6,"latestDate":"2026-11-03","latestIsToday":false,"placement":"within","sampleDays":60}"#
        )
        let line = try #require(ChartCoachReadLine.text(weight, kind: .weight, units: Self.imperial))
        let latest = MetricValueFormatter.formatScalar(79.6, kind: .weight, units: Self.imperial)
        let unit = MetricValueFormatter.unitSuffix(for: .weight, units: Self.imperial)
        #expect(line.contains("\(latest) \(unit)"))
        // Converted once: 79.6 kg is about 175.5 lb, neither the kilogram
        // value nor a second conversion of the pound value.
        #expect(abs((Double(latest.replacingOccurrences(of: ",", with: ".")) ?? 0) - 175.5) < 0.2)
    }

    @Test("The sleep tile's hours and minutes are translated, not left in English")
    func sleepDurationIsLocalized() throws {
        let expected = ["de": "7 Std. 12 Min.", "nl": "7 u 12 min", "en": "7h 12m"]
        for (language, text) in expected {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let format = bundle.localizedString(forKey: "%lldh %lldm", value: nil, table: "Localizable")
            #expect(String(format: format, 7, 12) == text, "\(language)")
        }
    }

    @Test("A banner with a retry button does not ask to try again in its text")
    func retryBannerSaysItOnce() {
        let decoding = HLError.decoding("keyNotFound")
        #expect(decoding.retryBannerDescription == String(localized: "error.banner.decoding"))
        #expect(decoding.retryBannerDescription != decoding.userFacingDescription)
        #expect(HLError.network(.timeout).retryBannerDescription == String(localized: "error.banner.timeout"))
        #expect(HLError.unknown("x").retryBannerDescription == String(localized: "error.banner.unknown"))
        // Everything else keeps its sentence.
        let server = HLError.server(status: 500, code: nil, message: "boom")
        #expect(server.retryBannerDescription == server.userFacingDescription)
    }
}
