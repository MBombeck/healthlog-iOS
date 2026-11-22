import Foundation
@testable import HealthLog
import Testing

/// #191 (server 1.49.0) — a symptom's distance to the day's dose on the
/// episode's symptom list: `doseOffset` on each occurrence of
/// `GET /api/symptoms/events`, behind the `day.dose-offset` key of
/// `/api/version`, worded as the web words it and never recomputed. The app
/// reads no day for it and keys no day itself.
@Suite("SYMPTOM — dose offset on the episode list (#191)")
struct SymptomDoseOffsetTests {
    private static func event(_ id: String, at: String, offset: DayDoseOffset? = nil) -> SymptomEvent {
        SymptomEvent(
            id: id, definitionId: "def-cough", occurredAt: at, intensity: 4, note: nil, episodeId: "ep-a", doseOffset: offset
        )
    }

    private static let openKeys = ServerFeatureKeys.joined(["medication.dose-state", "day.dose-offset", "x.unknown"])

    private struct Envelope: Decodable {
        let data: SymptomEventPage
    }

    // MARK: - Wire

    @Test("an occurrence carries its offset; a missing or broken one costs the offset, never the row")
    func decode() throws {
        let json = #"""
        {"data":{"events":[
          {"id":"s-1","definitionId":"d","occurredAt":"2026-10-02T10:10:00Z","intensity":4,"note":null,"episodeId":"ep",
           "doseOffset":{"intakeId":"in-1","title":"Metformin","minutes":130}},
          {"id":"s-2","definitionId":"d","occurredAt":"2026-10-02T11:00:00Z","intensity":2,"note":null,"episodeId":"ep"},
          {"id":"s-3","definitionId":"d","occurredAt":"2026-10-02T12:00:00Z","intensity":2,"note":null,"episodeId":"ep",
           "doseOffset":{"title":"broken"}},
          {"id":"s-4","definitionId":"d","occurredAt":"2026-10-02T06:00:00Z","intensity":1,"note":null,"episodeId":"ep",
           "doseOffset":{"intakeId":"in-2","title":"Metformin","minutes":-40}}
        ],"limit":500,"hasMore":false}}
        """#
        let page = try JSONDecoder.hlDefault.decode(Envelope.self, from: Data(json.utf8)).data
        #expect(page.events.map(\.id) == ["s-1", "s-2", "s-3", "s-4"])
        #expect(page.events[0].doseOffset == DayDoseOffset(intakeId: "in-1", title: "Metformin", minutes: 130))
        #expect(page.events[1].doseOffset == nil)
        #expect(page.events[2].doseOffset == nil)
        #expect(page.events[3].doseOffset?.minutes == -40)
    }

    @Test("an older server's occurrence (no doseOffset) still decodes as before")
    func olderWire() throws {
        let json = #"{"id":"s-1","definitionId":"d","occurredAt":"2026-10-02T10:10:00Z","intensity":4,"note":null,"episodeId":null}"#
        let event = try JSONDecoder.hlDefault.decode(SymptomEvent.self, from: Data(json.utf8))
        #expect(event.id == "s-1")
        #expect(event.doseOffset == nil)
    }

    // MARK: - Gate

    @Test("the offset shows only behind the day.dose-offset key, never by version")
    func gate() {
        let offset = DayDoseOffset(intakeId: "in-1", title: "Metformin", minutes: 130)
        let row = EpisodeSymptomsModel.Row(event: Self.event("s-1", at: "2026-10-02T10:10:00Z", offset: offset), label: "Husten")
        #expect(EpisodeSymptomsModel.doseOffset(of: row, featureKeys: Self.openKeys) == offset)
        #expect(EpisodeSymptomsModel.doseOffset(of: row, featureKeys: nil) == nil)
        #expect(EpisodeSymptomsModel.doseOffset(of: row, featureKeys: "") == nil)
        #expect(EpisodeSymptomsModel.doseOffset(of: row, featureKeys: "medication.dose-state") == nil)
        let plain = EpisodeSymptomsModel.Row(event: Self.event("s-2", at: "2026-10-02T11:00:00Z"), label: "Husten")
        #expect(EpisodeSymptomsModel.doseOffset(of: plain, featureKeys: Self.openKeys) == nil)
    }

    @Test("the stored keys keep only known ones and are forgotten with the host")
    func keyStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "SymptomDoseOffsetTests.keyStore"))
        defaults.removePersistentDomain(forName: "SymptomDoseOffsetTests.keyStore")
        #expect(!ServerFeatureKeys.isOpen(.dayDoseOffset, defaults: defaults))
        ServerFeatureKeys.record(["day.dose-offset", "x.unknown"], defaults: defaults)
        #expect(ServerFeatureKeys.isOpen(.dayDoseOffset, defaults: defaults))
        #expect(defaults.string(forKey: ServerFeatureKeys.defaultsKey) == "day.dose-offset")
        ServerFeatureKeys.record([], defaults: defaults)
        #expect(!ServerFeatureKeys.isOpen(.dayDoseOffset, defaults: defaults))
        ServerFeatureKeys.record(["day.dose-offset"], defaults: defaults)
        ServerFeatureKeys.forget(defaults: defaults)
        #expect(!ServerFeatureKeys.isOpen(.dayDoseOffset, defaults: defaults))
    }

    @Test("the list reads the occurrences once and asks no day")
    @MainActor
    func modelReadsNoDay() async {
        let model = EpisodeSymptomsModel()
        let offset = DayDoseOffset(intakeId: "in-1", title: "Metformin", minutes: 130)
        await model.load(
            events: { [Self.event("s-1", at: "2026-10-02T10:10:00Z", offset: offset)] },
            definitions: { [SymptomDefinition(id: "def-cough", label: "Husten")] }
        )
        guard case let .loaded(rows) = model.state else {
            Issue.record("the list did not load")
            return
        }
        #expect(rows.first?.event.doseOffset == offset)
    }

    // MARK: - Wording

    @Test("after, before and at the dose; the server's minutes, only worded")
    func wording() {
        let english = Locale(identifier: "en_US")
        let after = DoseOffsetFormat.text(DayDoseOffset(intakeId: "i", title: "Metformin", minutes: 130), locale: english)
        let before = DoseOffsetFormat.text(DayDoseOffset(intakeId: "i", title: "Metformin", minutes: -40), locale: english)
        let atDose = DoseOffsetFormat.text(DayDoseOffset(intakeId: "i", title: "Metformin", minutes: 0), locale: english)
        #expect(after.contains("Metformin"))
        #expect(after.contains(HLTimeFormat.duration(130 * 60, locale: english)))
        #expect(before.contains(HLTimeFormat.duration(40 * 60, locale: english)))
        #expect(!before.contains("-"))
        #expect(after != before)
        #expect(atDose.contains("Metformin"))
        for text in [after, before, atDose] {
            #expect(!text.contains("symptoms.doseOffset"))
        }
    }

    @Test("VoiceOver hears the offset after the row")
    @MainActor
    func spoken() {
        let row = EpisodeSymptomsModel.Row(event: Self.event("s-1", at: "2026-10-02T10:10:00Z"), label: "Husten")
        let offset = DayDoseOffset(intakeId: "in-1", title: "Metformin", minutes: 130)
        let spoken = SymptomEventFormat.spokenLabel(row, doseOffset: offset)
        #expect(spoken.hasPrefix(SymptomEventFormat.spokenLabel(row)))
        #expect(spoken.contains("Metformin"))
    }
}
