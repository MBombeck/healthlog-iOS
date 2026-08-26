import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **Phase 18 / 18-03 — every door the four cards ever opened.**
///
/// The consolidation is only finished when no old surface still answers. This
/// suite is the witness, and it is deliberately a *source* contract: SwiftUI
/// navigation is declarative, so what a route resolves to is a fact about the
/// host's source, and a runtime harness for it would be a re-implementation of
/// `NavigationStack` rather than a test of the app.
///
/// **The enumeration comes first, and it is complete.** Every entry into the
/// old sharing cluster was enumerated with a grep plus a control probe before
/// anything was rerouted; the list lives in `18-VALIDATION.md`. Three of the
/// four families a consolidation usually breaks turned out to be empty —
/// there is no sharing deep link, no sharing App Intent, and no settings
/// search index — and ``noHiddenEntryFamilies`` proves that by finding the
/// families themselves and then finding nothing sharing-shaped inside them. A
/// zero-result search with no control probe would prove only that the grep was
/// misspelled (12-11).
@MainActor
@Suite("UnifiedSharingRouting", .serialized)
struct UnifiedSharingRoutingTests {
    /// Screens the consolidation replaces. After 18-03 nothing in the app may
    /// name them, because nothing may still be able to reach them.
    private static let supersededScreens = [
        "ShareWithDoctorScreen",
        "HealthRecordExportScreen",
        "SettingsFHIRExportScreen",
        "DoctorReportScreen",
        "CreateShareLinkSheet",
        "ReportSelectionCard"
    ]

    private static func source(_ relativePath: String) throws -> String {
        try Phase8SourceScan.stripped(relativePath)
    }

    /// Every `.swift` under `HealthLog/`, comments removed, so "nothing names
    /// it" is a statement about the app rather than about the files this test
    /// happened to open — and a doc comment that still tells the old story is a
    /// prose problem, not a routing one.
    private static func productionSources() -> [(path: String, text: String)] {
        let root = Phase8SourceScan.repositoryRoot.appendingPathComponent("HealthLog")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { element in
            guard let url = element as? URL, url.pathExtension == "swift" else { return nil }
            let relative = url.path.replacingOccurrences(
                of: Phase8SourceScan.repositoryRoot.path + "/",
                with: ""
            )
            guard let text = try? Phase8SourceScan.stripped(relative) else { return nil }
            return (url.lastPathComponent, text)
        }
    }

    // MARK: - The one RED

    @Test("Jede alte Tür führt in die eine Fläche — und die alten Flächen antworten nirgends mehr")
    func everyEntryLandsInTheUnifiedSurface() throws {
        var violations: [String] = []

        // 1 + 2 — the two doors from outside the sharing cluster.
        let more = try Self.source("HealthLog/Screens/Settings/MoreScreen.swift")
        if !more.contains("UnifiedSharingScreen(") {
            violations.append("the Mehr header share glyph does not open the unified surface")
        }
        let export = try Self.source("HealthLog/Screens/Settings/Sub/SettingsExportScreen.swift")
        if !export.contains("UnifiedSharingScreen(") {
            violations.append("the Export screen's doctor row does not open the unified surface")
        }

        // 3 + 4 — the link-management screen mints nothing itself any more; both
        // its create paths lead into the one surface with the link preselected.
        let clinician = try Self.source("HealthLog/Screens/Settings/Sub/ShareWithClinicianScreen.swift")
        if !clinician.contains("UnifiedSharingScreen(preselectedForm: .link)") {
            violations.append("link management does not route creation into the unified surface")
        }
        if clinician.contains("CreateShareLinkSheet") {
            violations.append("link management still presents the old create sheet")
        }

        // 5–8 — the four legacy outputs are the four values of the last
        // question, each with a stable identifier a journey can target.
        let unified = try Self.source("HealthLog/Screens/Sharing/UnifiedSharingScreen.swift")
        let copy = try Self.source("HealthLog/Screens/Sharing/UnifiedSharingCopy.swift")
        if !unified.contains("ForEach(UnifiedSharingStore.OutputForm.allCases)") {
            violations.append("the form question does not enumerate every output")
        }
        if !unified.contains("sharing.unified.form.") {
            violations.append("the form rows carry no targetable identifier")
        }
        for form in UnifiedSharingStore.OutputForm.allCases
            where !copy.contains("sharing.unified.form.\(form.rawValue).title")
        {
            violations.append("no titled form row for \(form.rawValue)")
        }
        // 9 — managing what was already shared is a different question and keeps
        // its own surface, reachable from the one that creates links.
        if !unified.contains("ShareWithClinicianScreen()") {
            violations.append("the unified surface has no way to reach link management")
        }

        // Nothing in the app may still name a superseded screen.
        let sources = Self.productionSources()
        #expect(sources.count > 500, "control: the production tree was actually walked")
        for (path, text) in sources {
            for screen in Self.supersededScreens where text.contains(screen) {
                violations.append("\(path) still names \(screen)")
            }
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the four old screens still answer their routes

            D2 asked for one surface. Four cards that still resolve are five surfaces. Offen: \(violations)
            """
        )
    }

    // MARK: - Controls

    /// The three entry families a consolidation usually breaks. Each is found
    /// first (so the search is known to work), then searched for anything
    /// sharing-shaped. Both halves must hold.
    @Test("Kontrolle: es gibt keine Deep-Link-, Intent- oder Suchtür in die Sharing-Fläche")
    func noHiddenEntryFamilies() throws {
        let router = try Self.source("HealthLog/Services/DeepLinkRouter.swift")
        #expect(router.contains("enum DeepLinkRoute"), "control: the deep-link family exists")
        #expect(router.contains("case dashboard"), "control: the family has routes")
        for token in ["ShareWithDoctor", "HealthRecordExport", "FHIRExport", "UnifiedSharing"] {
            #expect(!router.contains(token), "no deep link resolves into sharing (\(token))")
        }

        let shortcuts = try Self.source("HealthLog/Intents/HealthLogAppShortcuts.swift")
        #expect(shortcuts.contains("AppShortcut"), "control: the App-Intent family exists")
        for token in ["Share", "Export", "FHIR", "Report"] {
            #expect(!shortcuts.contains("\(token)Intent"), "no shortcut resolves into sharing (\(token))")
        }

        let spotlight = try Self.source("HealthLog/Spotlight/SpotlightItemBuilder.swift")
        #expect(spotlight.contains("domainIdentifier"), "control: the Spotlight family exists")
        #expect(!spotlight.contains("sharing"), "nothing sharing-shaped is indexed for search")
    }

    @Test("Kontrolle: die eine Fläche baut sich auf und ist eine View")
    func unifiedSurfaceCompiles() {
        for form in UnifiedSharingStore.OutputForm.allCases {
            let view: any View = UnifiedSharingScreen(preselectedForm: form)
            _ = view
        }
    }
}
