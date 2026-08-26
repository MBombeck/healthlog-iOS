import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for `PhotoOfMedSheet` — covers the public-init contract surface
/// (the `onConfirm: (MedicationDraft) async -> Void` callback) and the
/// view's instantiation. The full state machine + camera-capture path is
/// integration-tested at the level of the underlying services
/// (`MedicationOCRServiceTests`, `MedicationExtractionServiceTests`,
/// `MedicationDraftHeuristicTests`) — testing the SwiftUI view body
/// directly would require ViewInspector or a snapshot harness, neither of
/// which is in T-6's scope.
@Suite("PhotoOfMedSheet — public API contract + onConfirm callback")
@MainActor
struct PhotoOfMedSheetTests {
    @Test("PhotoOfMedSheet — public init compiles with async onConfirm callback")
    func initWithAsyncOnConfirm() async {
        // Compile-time + run-time contract: the sheet accepts an async
        // closure that hands the caller a confirmed MedicationDraft.
        let draftBox = DraftBox()
        let sheet = PhotoOfMedSheet { draft in
            await draftBox.store(draft)
        }
        // Drive the callback ourselves to mimic what the view does after
        // the user taps "Übernehmen". The view's confirm() method routes
        // through this exact callback signature.
        let testDraft = MedicationDraft(
            name: "Metformin",
            doseStrength: "500 mg",
            doseForm: "Filmtablette",
            manufacturerHint: "Hexal AG",
            source: .heuristic
        )
        await sheet.onConfirm(testDraft)
        let captured = await draftBox.draft
        #expect(captured == testDraft)
    }

    @Test("PhotoOfMedSheet — onConfirm relays the FoundationModels-sourced draft verbatim")
    func relaysFoundationModelsDraft() async {
        let draftBox = DraftBox()
        let sheet = PhotoOfMedSheet { draft in
            await draftBox.store(draft)
        }
        let fmDraft = MedicationDraft(
            name: "Ozempic",
            doseStrength: "0,5 mg",
            doseForm: "Spritze",
            manufacturerHint: "Novo Nordisk A/S",
            source: .foundationModels
        )
        await sheet.onConfirm(fmDraft)
        let captured = await draftBox.draft
        #expect(captured?.source == .foundationModels)
        #expect(captured?.name == "Ozempic")
        #expect(captured?.doseStrength == "0,5 mg")
    }

    @Test("PhotoOfMedSheet — onConfirm tolerates a draft with only the name field populated")
    func relaysNameOnlyDraft() async {
        let draftBox = DraftBox()
        let sheet = PhotoOfMedSheet { draft in
            await draftBox.store(draft)
        }
        let sparse = MedicationDraft(name: "Aspirin", source: .heuristic)
        await sheet.onConfirm(sparse)
        let captured = await draftBox.draft
        #expect(captured?.name == "Aspirin")
        #expect(captured?.doseStrength == nil)
        #expect(captured?.doseForm == nil)
        #expect(captured?.manufacturerHint == nil)
    }
}

/// Test-local box for capturing the draft handed back through the
/// `onConfirm` callback. Actor-isolated so the test stays
/// strict-concurrency-clean.
private actor DraftBox {
    private(set) var draft: MedicationDraft?

    func store(_ draft: MedicationDraft) {
        self.draft = draft
    }
}
