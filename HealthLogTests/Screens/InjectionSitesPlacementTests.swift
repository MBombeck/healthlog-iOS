import Foundation
@testable import HealthLog
import Testing

/// #105 — the global injection-site deny-list is a statement about the user's
/// own body and a standing preference, not a property of one medication. Its
/// door therefore lives in Über mich (with the Körperdaten), and the moment
/// the question arises — the site picker after logging an injection — links
/// there. The Medications tab is a list of preparations and carries no
/// settings door any more. Placement is pinned at source level, the way the
/// 25-02 decisions are.
@Suite("#105 — injection sites live in Über mich and are reachable from the site picker")
struct InjectionSitesPlacementTests {
    private static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("the Medications tab has no injection-sites door")
    func medicationsTabHasNoDoor() throws {
        let medications = try Self.source("HealthLog/Screens/Medications/MedicationsScreen.swift")
        #expect(!medications.contains("SettingsInjectionSitesScreen"))
        #expect(!medications.contains("injectionSitesRow"))
        #expect(!medications.contains("showsInjectionSitesDoor"))
    }

    @Test("Über mich carries the door, gated like before")
    func aboutMeCarriesTheDoor() throws {
        let aboutMe = try Self.source("HealthLog/Screens/AboutMe/AboutMeScreen.swift")
        #expect(aboutMe.contains("SettingsInjectionSitesScreen()"))
        #expect(aboutMe.contains("\"aboutMe.injectionSitesRow\""))
        #expect(aboutMe.contains("showsInjectionSites(medications:"))
    }

    @Test("the site picker links to the deny-list")
    func sitePickerLinksToTheDenyList() throws {
        let sheet = try Self.source("HealthLog/Screens/Medications/IntakeSiteCaptureSheet.swift")
        #expect(sheet.contains("SettingsInjectionSitesScreen()"))
        #expect(sheet.contains("\"meds.quick.site.manage\""))
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
