import Foundation
@testable import HealthLog
import Testing

/// Decode-tolerance contract for the environmental-context overview DTOs
/// (Build 7 Item 7.7). Pure decode — no network. Proves the wire is consumed
/// TOLERANTLY (missing fields default, a bad travel row drops, an absent home is
/// `nil`) and that the **licence-mandated Open-Meteo attribution is always
/// present** even when the server omits it.
@Suite("EnvironmentContext DTO — tolerant decode + attribution invariant")
struct EnvironmentContextDTOTests {
    private static let decoder = JSONDecoder.hlDefault

    private func decodeOverview(_ json: String) throws -> EnvironmentOverviewDTO {
        try Self.decoder.decode(EnvironmentOverviewDTO.self, from: Data(json.utf8))
    }

    @Test("Full overview decodes every field")
    func fullDecode() throws {
        let json = """
        {
          "home": {"lat": 51.48, "lon": 7.22, "label": "Bochum, NRW, Germany",
                   "timezone": "Europe/Berlin", "since": "2026-01-01T00:00:00Z"},
          "travel": [
            {"id": "t1", "startDate": "2026-06-01", "endDate": "2026-06-08",
             "lat": 48.13, "lon": 11.58, "label": "Munich"}
          ],
          "context": {"days": 42, "latestDate": "2026-07-20",
                      "latestFetchedAt": "2026-07-21T03:00:00Z"},
          "attribution": "Weather data by Open-Meteo.com"
        }
        """
        let dto = try decodeOverview(json)
        #expect(dto.home?.label == "Bochum, NRW, Germany")
        #expect(dto.home?.lat == 51.48)
        #expect(dto.travel.count == 1)
        #expect(dto.travel.first?.label == "Munich")
        #expect(dto.context.days == 42)
        #expect(dto.context.latestDate == "2026-07-20")
        #expect(dto.attribution == "Weather data by Open-Meteo.com")
    }

    @Test("Missing home decodes to nil (user has not set a home)")
    func homeAbsent() throws {
        let dto = try decodeOverview("""
        {"home": null, "travel": [], "context": {"days": 0}, "attribution": "Weather data by Open-Meteo.com"}
        """)
        #expect(dto.home == nil)
        #expect(dto.travel.isEmpty)
        #expect(dto.context.days == 0)
        #expect(dto.context.latestDate == nil)
    }

    @Test("A partially-populated payload defaults the missing fields, never throws")
    func partialFieldsDefault() throws {
        // No `travel`, no `context`, a home with only a label, no attribution.
        let dto = try decodeOverview("""
        {"home": {"label": "Somewhere"}}
        """)
        #expect(dto.home?.label == "Somewhere")
        #expect(dto.home?.lat == nil)
        #expect(dto.travel.isEmpty)
        #expect(dto.context.days == 0)
        // LICENCE: the credit falls back to the canonical string.
        #expect(dto.attribution == EnvironmentOverviewDTO.defaultAttribution)
        #expect(!dto.attribution.isEmpty)
    }

    @Test("A missing attribution falls back to the canonical Open-Meteo credit (licence invariant)")
    func attributionFallbackWhenAbsent() throws {
        let dto = try decodeOverview("""
        {"home": null, "travel": [], "context": {"days": 3}}
        """)
        #expect(dto.attribution == "Weather data by Open-Meteo.com")
    }

    @Test("A blank attribution is replaced by the canonical credit (never empty)")
    func attributionFallbackWhenBlank() throws {
        let dto = try decodeOverview("""
        {"context": {"days": 1}, "attribution": ""}
        """)
        #expect(dto.attribution == EnvironmentOverviewDTO.defaultAttribution)
    }

    @Test("A custom (self-host) attribution string is honoured verbatim")
    func attributionHonoursServerValue() throws {
        let dto = try decodeOverview("""
        {"context": {"days": 1}, "attribution": "Wetterdaten von Open-Meteo.com"}
        """)
        #expect(dto.attribution == "Wetterdaten von Open-Meteo.com")
    }

    @Test("A malformed travel row drops out; the good rows survive (lossy list)")
    func lossyTravelList() throws {
        // Second row is not an object → it must drop without failing the overview.
        let dto = try decodeOverview("""
        {
          "travel": [
            {"id": "ok", "startDate": "2026-06-01", "endDate": "2026-06-02", "lat": 1, "lon": 2, "label": "A"},
            42,
            {"id": "ok2", "startDate": "2026-07-01", "endDate": "2026-07-02", "label": "B"}
          ],
          "context": {"days": 0}
        }
        """)
        #expect(dto.travel.count == 2)
        #expect(dto.travel.map(\.id) == ["ok", "ok2"])
        // The last row omitted lat/lon → tolerated as nil, label still there.
        #expect(dto.travel.last?.lat == nil)
        #expect(dto.travel.last?.label == "B")
    }

    @Test("The attribution URLs are the Open-Meteo source + the CC BY 4.0 deed")
    func attributionLinks() {
        #expect(EnvironmentOverviewDTO.attributionURL?.absoluteString == "https://open-meteo.com/")
        #expect(EnvironmentOverviewDTO.licenseURL?.absoluteString == "https://creativecommons.org/licenses/by/4.0/")
    }
}
