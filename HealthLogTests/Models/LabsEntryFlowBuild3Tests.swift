import Foundation
@testable import HealthLog
import Testing

/// **Build 3 / item 3.2 — the labs entry flow.**
///
/// Three contracts, each of which was a real defect before:
///   1. "Save & next value" keeps the sample date between rows (twenty sheets
///      vs. one when a real report is typed in).
///   2. A cleared note / panel / reference bound sends an explicit `null` so
///      the server DELETES it — `encodeIfPresent` omitted the key, the column
///      stayed, and the field the operator had just emptied came back on the
///      next sync.
///   3. A `hidden` biomarker leaves the entry picker without losing its data.
@Suite("Build 3 — labs entry flow")
struct LabsEntryFlowBuild3Tests {
    private static let sampleDate = Date(timeIntervalSince1970: 1_770_000_000)

    private static func filledDraft() -> LabEntryDraft {
        LabEntryDraft(
            selectedBiomarkerID: "bm-ldl",
            analyte: "LDL",
            unit: "mg/dL",
            valueText: "116",
            qualitativeText: "",
            referenceLowText: "0",
            referenceHighText: "116",
            panel: "Lipide",
            note: "nüchtern",
            takenAt: sampleDate,
            resultType: .numeric
        )
    }

    // MARK: - 1. Save & next value — state retention

    @Test("save-and-next KEEPS the sample date — the whole point of the flow")
    func saveAndNextKeepsTakenAt() {
        let next = Self.filledDraft().resetForNextValue()
        #expect(next.takenAt == Self.sampleDate, "the blood-draw date must survive so it is picked once per report")
    }

    @Test("save-and-next clears everything that describes the row just saved")
    func saveAndNextClearsTheRow() {
        let next = Self.filledDraft().resetForNextValue()
        #expect(next.selectedBiomarkerID == nil, "the next row is the next analyte")
        #expect(next.analyte.isEmpty)
        #expect(next.unit.isEmpty)
        #expect(next.valueText.isEmpty)
        #expect(next.qualitativeText.isEmpty)
        #expect(next.referenceLowText.isEmpty)
        #expect(next.referenceHighText.isEmpty)
        #expect(next.panel.isEmpty)
        #expect(next.note.isEmpty, "the note belongs to the value just saved")
    }

    @Test("save-and-next keeps the qualitative mode so a qualitative report stays qualitative")
    func saveAndNextKeepsResultType() {
        var draft = Self.filledDraft()
        draft.resultType = .qualitative
        draft.qualitativeText = "negativ"
        let next = draft.resetForNextValue()
        #expect(next.resultType == .qualitative, "flipping back to numeric after every row would fight the operator")
        #expect(next.qualitativeText.isEmpty, "the result text itself still belongs to the saved row")
    }

    @Test("repeated save-and-next never drifts the sample date")
    func saveAndNextIsStableAcrossManyRows() {
        var draft = Self.filledDraft()
        // Twenty analytes off one report — the realistic case.
        for _ in 0 ..< 20 {
            draft = draft.resetForNextValue()
        }
        #expect(draft.takenAt == Self.sampleDate, "the date must be identical after twenty rows, not merely close")
    }

    // MARK: - 2. Explicit-null clearing

    private static func encodedJSON(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("an emptied lab note encodes an explicit null, not an omitted key")
    func clearedNoteSendsNull() throws {
        let patch = LabResultPatch(note: .fromEditor("   "))
        let json = try Self.encodedJSON(patch)
        #expect(json.keys.contains("note"), "a cleared note must be SENT — omitting it leaves the column untouched")
        #expect(json["note"] is NSNull, "a cleared note must be an explicit JSON null")
    }

    @Test("an untouched lab note omits the key entirely")
    func untouchedNoteOmitsKey() throws {
        let patch = LabResultPatch(value: 5.4)
        let json = try Self.encodedJSON(patch)
        #expect(!json.keys.contains("note"), "an unchanged field must not appear on the wire at all")
        #expect((json["value"] as? NSNumber)?.doubleValue == 5.4)
    }

    @Test("a written lab note encodes its trimmed text")
    func setNoteSendsValue() throws {
        let patch = LabResultPatch(note: .fromEditor("  nüchtern  "))
        let json = try Self.encodedJSON(patch)
        #expect(json["note"] as? String == "nüchtern")
    }

    @Test("cleared panel and both reference bounds each send an explicit null")
    func clearedPanelAndBoundsSendNull() throws {
        let patch = LabResultPatch(
            panel: .fromEditor(""),
            referenceLow: .fromEditor("", parse: { LocaleDecimalParser.parse($0) }),
            referenceHigh: .fromEditor("", parse: { LocaleDecimalParser.parse($0) })
        )
        let json = try Self.encodedJSON(patch)
        #expect(json["panel"] is NSNull)
        #expect(json["referenceLow"] is NSNull)
        #expect(json["referenceHigh"] is NSNull)
    }

    @Test("an unparseable bound is left UNCHANGED rather than clearing a stored range")
    func unparseableBoundIsUnchanged() throws {
        // A typo must never destroy data. The field is non-empty, so the
        // operator clearly meant a value — the conservative reading is to leave
        // the stored bound alone, not to wipe it.
        let patch = LabResultPatch(referenceHigh: .fromEditor("abc", parse: { LocaleDecimalParser.parse($0) }))
        let json = try Self.encodedJSON(patch)
        #expect(!json.keys.contains("referenceHigh"), "a typo'd bound must not be sent at all")
    }

    @Test("a locale-comma bound parses into a set value")
    func localeCommaBoundParses() throws {
        let patch = LabResultPatch(referenceHigh: .fromEditor("1,5", parse: { LocaleDecimalParser.parse($0) }))
        let json = try Self.encodedJSON(patch)
        #expect((json["referenceHigh"] as? NSNumber)?.doubleValue == 1.5)
    }

    @Test("biomarker context, panel and bounds are clearable too")
    func biomarkerClearableFields() throws {
        let patch = BiomarkerPatch(
            name: "Ferritin",
            lowerBound: .clear,
            upperBound: .set(400),
            context: .clear,
            panel: .unchanged
        )
        let json = try Self.encodedJSON(patch)
        #expect(json["name"] as? String == "Ferritin")
        #expect(json["lowerBound"] is NSNull, "a cleared bound must be an explicit null")
        #expect((json["upperBound"] as? NSNumber)?.doubleValue == 400)
        #expect(json["context"] is NSNull)
        #expect(!json.keys.contains("panel"), "an unchanged field stays off the wire")
        #expect(!json.keys.contains("hidden"), "visibility is untouched unless explicitly set")
    }

    @Test("a patch round-trips through the outbox unchanged in all three states")
    func patchRoundTripsThroughOutbox() throws {
        // The outbox re-issues the stored payload verbatim on replay, so a
        // decode→encode cycle must preserve unchanged / clear / set exactly.
        let original = LabResultPatch(
            panel: .clear,
            value: 12.5,
            referenceLow: .set(3),
            referenceHigh: .unchanged,
            note: .clear
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LabResultPatch.self, from: data)
        #expect(decoded == original, "outbox replay must re-issue the identical wire body")
        #expect(decoded.panel == .clear)
        #expect(decoded.referenceHigh == .unchanged)
        #expect(decoded.note == .clear)
    }

    // MARK: - 3. Hidden biomarkers

    private static func marker(id: String, name: String, hidden: Bool) -> BiomarkerDTO {
        BiomarkerDTO(
            id: id,
            name: name,
            unit: "mg/dL",
            lowerBound: nil,
            upperBound: nil,
            panel: nil,
            hasContext: false,
            context: nil,
            hidden: hidden,
            createdAt: "",
            updatedAt: ""
        )
    }

    @Test("hidden is decoded from the wire and defaults to visible when absent")
    func hiddenDecodes() throws {
        let hidden = try JSONDecoder().decode(
            BiomarkerDTO.self,
            from: Data(#"{"id":"b1","name":"LDL","unit":"mg/dL","hidden":true}"#.utf8)
        )
        #expect(hidden.hidden)
        // A pre-v1.22 server omits the key. Defaulting to hidden would make
        // every marker vanish from the picker, so the safe direction is visible.
        let legacy = try JSONDecoder().decode(
            BiomarkerDTO.self,
            from: Data(#"{"id":"b2","name":"HDL","unit":"mg/dL"}"#.utf8)
        )
        #expect(!legacy.hidden, "a missing hidden key must never hide a marker")
    }

    @Test("the picker offers only visible markers")
    func selectableDropsHidden() {
        let markers = [
            Self.marker(id: "b1", name: "LDL", hidden: false),
            Self.marker(id: "b2", name: "Retired marker", hidden: true),
            Self.marker(id: "b3", name: "HDL", hidden: false)
        ]
        let offered = markers.selectable
        #expect(offered.map(\.id) == ["b1", "b3"])
        #expect(markers.count == 3, "hiding is a filter on the picker, never a deletion from the catalog")
    }

    @Test("hiding a marker is a boolean patch, not a delete")
    func hidingIsAPatch() throws {
        let patch = BiomarkerPatch(hidden: true)
        let json = try Self.encodedJSON(patch)
        #expect(json["hidden"] as? Bool == true)
        #expect(json.count == 1, "hiding must not disturb any other column")
    }

    // MARK: - Seed catalog

    @Test("the seed catalog mirrors the web catalog's 30 entries across 10 panels")
    func seedCatalogShape() {
        #expect(BiomarkerSeedCatalog.all.count == 30)
        #expect(BiomarkerSeedPanel.allCases.count == 10)
        for panel in BiomarkerSeedPanel.allCases {
            #expect(!BiomarkerSeedCatalog.seeds(in: panel).isEmpty, "every panel group must carry at least one seed")
        }
    }

    @Test("seed slugs are unique and every seed carries a unit")
    func seedCatalogIntegrity() {
        let slugs = BiomarkerSeedCatalog.all.map(\.slug)
        #expect(Set(slugs).count == slugs.count, "a duplicate slug would make the picker ambiguous")
        for seed in BiomarkerSeedCatalog.all {
            #expect(!seed.unit.isEmpty, "a seeded marker without a unit defeats the point of seeding")
        }
    }

    @Test("an open-ended seed keeps the missing bound nil rather than inventing a zero")
    func openEndedSeedsStayOpen() throws {
        // LDL has no clinically useful floor; HDL has no ceiling. A fabricated
        // 0 would make the server compute a bogus range verdict.
        let ldl = try #require(BiomarkerSeedCatalog.seed(slug: "ldl"))
        #expect(ldl.lowerBound == nil)
        #expect(ldl.upperBound == 116)
        let hdl = try #require(BiomarkerSeedCatalog.seed(slug: "hdl"))
        #expect(hdl.lowerBound == 40)
        #expect(hdl.upperBound == nil)
    }

    @Test("every seed slug resolves an explainer, so a seeded marker is never unexplained")
    func seedSlugsHaveExplainers() {
        // The seed slugs deliberately share the `BiomarkerExplainer` slug space
        // — that was the missing half: iOS had explainers that never seeded.
        let explained = Set(BiomarkerExplainer.knownSlugs)
        for seed in BiomarkerSeedCatalog.all {
            #expect(explained.contains(seed.slug), "seeded marker has no explainer entry: \(seed.slug)")
        }
    }
}
