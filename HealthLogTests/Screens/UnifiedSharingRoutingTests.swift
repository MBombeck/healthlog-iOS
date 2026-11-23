import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The unified sharing surface builds for every output form, and nothing from
/// outside the app opens it. The routes into it are walked end to end by
/// `UnifiedSharingJourneyUITest`.
@MainActor
@Suite("UnifiedSharingRouting", .serialized)
struct UnifiedSharingRoutingTests {
    @Test("Kontrolle: die eine Fläche baut sich auf und ist eine View")
    func unifiedSurfaceCompiles() {
        for form in UnifiedSharingStore.OutputForm.allCases {
            let view: any View = UnifiedSharingScreen(preselectedForm: form)
            _ = view
        }
    }

    /// The sharing surface hands out health data as FHIR, PDF or link. A URL from
    /// outside the app must never open it, neither as a custom scheme nor as a link.
    @Test("no deep link, universal link or Spotlight hit opens the sharing surface")
    func noDeepLinkReachesSharing() throws {
        let host = "healthlog.example.com"
        for path in ["share", "sharing", "export", "fhir", "doctor-report", "share-with-doctor"] {
            let custom = try #require(URL(string: "healthlog://\(path)"))
            if let route = DeepLinkRoute(url: custom) {
                #expect(!Self.opensSharing(route), "healthlog://\(path) resolved to \(route)")
            }
            let universal = try #require(URL(string: "https://\(host)/\(path)"))
            #expect(DeepLinkRoute.universalLink(universal, expectedHost: host) == nil)
        }
    }

    /// Exhaustive on purpose: a new route has to be classified here before it compiles.
    private static func opensSharing(_ route: DeepLinkRoute) -> Bool {
        switch route {
        case .dashboard, .coach, .insights, .medications, .medication, .medicationDue, .medicationHistory, .personalRecord,
             .settingsNotifications, .mood, .mentalWellbeing, .invite, .checkups, .checkupsVisit, .cycle,
             .timeline, .seizures, .seizureEvent, .settingsSecurity, .settingsIntegrations, .unknown:
            false
        }
    }

    /// Spotlight hits go through ``DeepLinkRoute``; App Intents and shortcuts do
    /// not, so no intent or shortcut provider anywhere may name the surface.
    @Test("no App Intent or shortcut provider names the sharing surface")
    func noIntentReachesSharing() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .appendingPathComponent("HealthLog")
        let sharingTypes = ["UnifiedSharing", "ShareWithDoctor", "HealthRecordExport", "FHIRExport", "DoctorReport"]
        var intentFiles = 0
        var hits: [String] = []
        let files = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
                }
                .joined(separator: "\n")
            guard code.contains(": AppIntent") || code.contains("AppShortcutsProvider") else { continue }
            intentFiles += 1
            for type in sharingTypes where code.contains(type) {
                hits.append("\(url.lastPathComponent) :: \(type)")
            }
        }
        #expect(intentFiles >= 5, "the scan must find the app's intents, found \(intentFiles)")
        #expect(hits.isEmpty, "an intent or shortcut reaches the sharing surface: \(hits)")
    }
}
