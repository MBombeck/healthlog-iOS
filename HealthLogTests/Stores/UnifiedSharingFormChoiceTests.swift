import Foundation
@testable import HealthLog
import Testing

/// **The sharing surface opens without an output form.**
///
/// The surface used to start on "Link" without running the steps a form
/// choice runs. A saved profile that carried a leaf the link route refuses
/// (`INSURANCE`) then kept the link action dead until the user tapped "Link"
/// a second time. Now nothing is chosen on open, and every way to a form, the
/// tap and a door that presets one, goes through `setOutputForm(_:)`.
@MainActor
@Suite("UnifiedSharing — form choice", .serialized, .mockURLSession)
struct UnifiedSharingFormChoiceTests {
    private typealias Inputs = SharingWireFixtureTests.Inputs

    /// Answers the two selection reads: the fixture vocabulary, and either no
    /// saved profile or one that carries every leaf.
    private func stubReads(savedLeaves: [String]?) {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/meta/capabilities" {
                return SharingWire.jsonOK(req, SharingWire.capabilitiesJSON(leaves: Inputs.vocabulary))
            }
            if let savedLeaves {
                return SharingWire.jsonOK(req, SharingWire.profileJSON(leaves: savedLeaves))
            }
            return SharingWire.jsonOK(req, #"{"profile":null}"#)
        }
    }

    private func makeStore(form: UnifiedSharingStore.OutputForm? = nil) -> UnifiedSharingStore {
        let api = SharingWire.makeAPI()
        let profile = ReportSelectionStore(
            capabilities: ServerCapabilitiesRepository(api: api),
            profiles: ReportSelectionRepository(api: api)
        )
        let store = if let form {
            UnifiedSharingStore(profile: profile, form: form, now: { Inputs.anchor }, calendar: Inputs.calendar)
        } else {
            UnifiedSharingStore(profile: profile, now: { Inputs.anchor }, calendar: Inputs.calendar)
        }
        store.linkLabel = Inputs.linkLabel
        store.practiceName = Inputs.practiceName
        store.expiresAt = Inputs.expiresAt
        return store
    }

    @Test("Ohne Vorgabe ist keine Form gewählt, und keine Ausgabe lässt sich erzeugen")
    func noFormUntilChosen() async {
        stubReads(savedLeaves: nil)
        let store = makeStore()
        await store.load()

        let form: UnifiedSharingStore.OutputForm? = store.outputForm
        #expect(form == nil, "the surface opened on \(String(describing: form))")
        #expect(!store.canProduce, "the action is live before a form was chosen")
        #expect(store.shareLinkBody() == nil)
        #expect(store.pdfArguments(locale: Inputs.locale) == nil)
        #expect(store.packageRequest() == nil)
        #expect(await store.prepareFHIRScope() == false)
    }

    @Test("Vor der Wahl wird nichts eingegrenzt, „Link“ grenzt beim ersten Tippen ein")
    func firstLinkTapNarrows() async {
        stubReads(savedLeaves: Inputs.vocabulary)
        let store = makeStore()
        await store.load()

        #expect(store.offeredLeaves == Inputs.vocabulary, "an undecided surface narrowed to \(store.offeredLeaves)")
        #expect(store.chosen == Set(Inputs.vocabulary))

        store.setOutputForm(.link)

        #expect(store.offeredLeaves == Inputs.linkSelection.leaves)
        #expect(store.chosen == Set(Inputs.linkSelection.leaves))
        #expect(store.droppedForForm == ["INSURANCE"])
        #expect(store.canProduce, "the first tap on Link left the action dead")
        #expect(store.shareLinkBody()?.selection == Inputs.linkSelection)
    }

    @Test("Eine vorgegebene Form läuft über dieselben Schritte, auch nach dem Laden")
    func presetFormRunsTheSameSteps() async {
        stubReads(savedLeaves: Inputs.vocabulary)
        let preset = makeStore(form: .link)
        await preset.load()

        stubReads(savedLeaves: Inputs.vocabulary)
        let tapped = makeStore()
        await tapped.load()
        tapped.setOutputForm(.link)

        let form: UnifiedSharingStore.OutputForm? = preset.outputForm
        #expect(form == .link)
        #expect(preset.canProduce, "a preset Link kept a leaf the link route refuses")
        #expect(preset.chosen == tapped.chosen)
        #expect(preset.droppedForForm == tapped.droppedForForm)
        #expect(preset.shareLinkBody()?.selection == tapped.shareLinkBody()?.selection)
        #expect(preset.shareLinkBody()?.rangeStart == tapped.shareLinkBody()?.rangeStart)
    }

    @Test("Ein vorgegebenes Zeitfenster bleibt bis zur Wahl und endet mit FHIR")
    func windowSurvivesUntilFHIR() throws {
        let window = try #require(ReportWindow(from: "2023-10-01", to: "2023-11-10"))
        let store = makeStore()
        store.presetWindow(window)
        #expect(store.window == window)

        store.setOutputForm(.pdf)
        #expect(store.window == window)
        store.setOutputForm(.fhir)
        #expect(store.window == nil)
    }
}
