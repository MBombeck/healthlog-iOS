import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The global injection-site deny-list is a statement about the user's
/// own body and a standing preference, not a property of one medication. Its
/// door therefore lives in Über mich (with the Körperdaten), and the moment
/// the question arises — the site picker after logging an injection — links
/// there. The Medications tab is a list of preparations and carries no
/// settings door any more.
@Suite("#105 — injection sites live in Über mich and are reachable from the site picker")
struct InjectionSitesPlacementTests {
    /// The carrier itself: the `destination:` form is a push, the action form is not.
    @Test("HLButton's destination form is a push; its action form is not")
    @MainActor
    func hlButtonDestinationFormPushes() {
        let push = HLButton(
            "Manage sites",
            icon: "circle.grid.cross",
            variant: .secondary,
            size: .compact,
            destination: { Text(verbatim: "list") }
        )
        #expect(push.pushesDestination)
        let action = HLButton("Manage sites", variant: .secondary) {}
        #expect(!action.pushesDestination)
    }

    /// Same rule the Medications door had: only for somebody the deny-list
    /// can do anything for — at least one injection medication, active or
    /// archived; a GLP-1 counts as injectable by class.
    @Test("the door needs an injection medication")
    @MainActor
    func theDoorNeedsAnInjectionMedication() {
        #expect(!AboutMeScreen.showsInjectionSites(medications: []))
        let oral = Medication(id: "m1", name: "Lisinopril", dose: "5 mg", schedule: MedicationSchedule(times: []), deliveryForm: "ORAL")
        #expect(!AboutMeScreen.showsInjectionSites(medications: [oral]))
        let pen = Medication(id: "m2", name: "Insulin", dose: "10 IE", schedule: MedicationSchedule(times: []), deliveryForm: "INJECTION")
        #expect(AboutMeScreen.showsInjectionSites(medications: [oral, pen]))
        let glp1 = Medication(id: "m3", name: "Trulicity", dose: "5 mg", treatmentClass: "GLP1", schedule: MedicationSchedule(times: []))
        #expect(AboutMeScreen.showsInjectionSites(medications: [glp1]))
    }
}
