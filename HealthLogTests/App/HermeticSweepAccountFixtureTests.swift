import Foundation
@testable import HealthLog
import Testing

/// The answers the picture walk was missing, decoded the way the app decodes
/// them. Each one used to fall through to the shared `[]` or `{}` default,
/// which no DTO accepts, and the screen showed its read error instead of the
/// state a real account has.
@Suite("Hermetic sweep account fixtures")
struct HermeticSweepAccountFixtureTests {
    private static let trulicity = AreaMedsDetailFixtures.trulicityID

    @Test("A GLP-1 detail reads an empty side-effect logbook and supply list")
    func glp1JournalsDecode() throws {
        let effects = try #require(AreaMedsDetailFixtures.response(
            forPath: "/api/medications/\(Self.trulicity)/side-effects", method: "GET", query: []
        ))
        let logbook = try JSONDecoder.hlDefault.decode(APIEnvelope<MedicationSideEffectListDTO>.self, from: effects.body)
        #expect(logbook.data?.items.isEmpty == true)
        #expect(logbook.data?.meta.total == 0)

        let supply = try #require(AreaMedsDetailFixtures.response(
            forPath: "/api/medications/\(Self.trulicity)/inventory", method: "GET", query: []
        ))
        let inventory = try JSONDecoder.hlDefault.decode(APIEnvelope<MedicationInventoryListDTO>.self, from: supply.body)
        #expect(inventory.data?.items.isEmpty == true)
    }

    @Test("The shared account names its unit system, so an imperial run does not stick")
    func meCarriesMetric() throws {
        let me = HermeticFixtures.response(forPath: "/api/auth/me", method: "GET")
        let prefs = try JSONDecoder.hlDefault.decode(AuthMeServerPrefs.self, from: me.body)
        #expect(prefs.unitPreference == "metric")
    }

    @Test("The tile editor reads the layout a server resolves for an unchanged account")
    func widgetLayoutDecodes() throws {
        let answer = try #require(SweepFixtures.response(forPath: "/api/dashboard/widgets", method: "GET", query: []))
        let layout = try JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: answer.body)
        #expect(layout.widgets == DashboardWidgetLayout.default.widgets)
        #expect(layout.updatedAt != nil)
    }

    @Test("Resting pulse and HRV have readings behind the summary's values")
    func vitalsHaveSeries() throws {
        for (kind, latest) in [("restingHeartRate", 58.0), ("heartRateVariability", 46.0)] {
            let answer = try #require(SweepFixtures.response(
                forPath: "/api/measurements/series", method: "GET", query: [URLQueryItem(name: "kind", value: kind)]
            ))
            let series = try JSONDecoder.hlDefault.decode(MeasurementSeries.self, from: answer.body)
            #expect(series.points.count == 30)
            #expect(series.points.last?.value == latest)
        }
    }

    @Test("The usual range comes from the readings the page charts and holds today's")
    func usualRangeMatchesSeries() throws {
        let weight = try #require(SweepFixtures.usualRange(serverType: "WEIGHT"))
        #expect(weight.latest == 72.4)
        #expect(weight.low <= weight.latest && weight.latest <= weight.high)
        #expect(weight.low > 71 && weight.high < 74)
        let pressure = try #require(SweepFixtures.usualRange(serverType: "BLOOD_PRESSURE_SYS"))
        #expect(pressure.low >= 118 && pressure.high <= 126)
        #expect(SweepFixtures.usualRange(serverType: "STEPS") == nil)
    }
}
