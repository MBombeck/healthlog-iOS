import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **CU-18 / GH #64 — Dosis-Provenienz auf `GET /api/medications/{id}/dose-history`.**
///
/// Seit Server v1.32.8 trägt jede Intake-Zeile ein nullbares `source`
/// (`WEB | API | REMINDER | IMPORT | APPLE_HEALTH`); vor der Migration
/// entstandene Zeilen tragen `null`. Diese Suite pinnt die echten Werte gegen
/// den **echten** ``APIClient`` (`MockURLProtocol`, kein Mock-Server) über den
/// produktiven Repository-Pfad ``MedicationsRepository/doseHistory(medicationID:from:to:now:)``
/// und sichert die Render-Entscheidung des Provenienz-Chips in
/// `LedgerHistoryRow` ab: der Chip hängt an ``MedicationDoseHistoryRow/provenance``,
/// also genügt dieser Wert als Beleg dafür, was gerendert wird.
@Suite("CU-18 — Dosis-Provenienz (#64)", .serialized)
struct MedicationDoseProvenanceWireTests {
    private func makeRepo() throws -> MedicationsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    /// One ledger row carrying `intake.source` verbatim (`nil` → key absent,
    /// `"null"` → explicit JSON null).
    private func row(id: String, day: Int, source: String?) -> String {
        let sourceJSON = source.map { $0 == "null" ? "null" : "\"\($0)\"" }
        let sourceKey = sourceJSON.map { #","source":\#($0)"# } ?? ""
        return #"""
        {"kind":"slot","at":"2026-07-\#(String(format: "%02d", day))T06:00:00.000Z","timeOfDay":"08:00",
        "status":"taken_on_time","intake":{"id":"\#(id)",
        "scheduledFor":"2026-07-\#(String(format: "%02d", day))T06:00:00.000Z",
        "takenAt":"2026-07-\#(String(format: "%02d", day))T06:05:00.000Z","skipped":false,"autoMissed":false\#(sourceKey)}}
        """#
    }

    private func respond(rows: [String]) {
        let body = #"""
        {"data":{"from":"2026-07-01T00:00:00.000Z","to":"2026-07-31T00:00:00.000Z",
        "family":"daily","hasExpectedSlots":true,"rows":[\#(rows.joined(separator: ","))]}}
        """#
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
    }

    // MARK: - Die fünf echten Server-Werte

    @Test("Alle fünf `source`-Literale mappen auf ihr Provenienz-Label")
    func allFiveSourcesMap() async throws {
        respond(rows: [
            row(id: "e-web", day: 1, source: "WEB"),
            row(id: "e-api", day: 2, source: "API"),
            row(id: "e-rem", day: 3, source: "REMINDER"),
            row(id: "e-imp", day: 4, source: "IMPORT"),
            row(id: "e-ah", day: 5, source: "APPLE_HEALTH")
        ])
        let ledger = try await makeRepo().doseHistory(medicationID: "med-1")
        #expect(ledger.rows.count == 5)

        let expected: [DoseIntakeProvenance] = [.web, .api, .reminder, .import, .appleHealth]
        #expect(ledger.rows.map(\.provenance) == expected)
        // Der Rohwert bleibt erhalten — das Label ist eine Leseansicht, keine
        // Ersetzung.
        #expect(ledger.rows.map { $0.intake?.source } == ["WEB", "API", "REMINDER", "IMPORT", "APPLE_HEALTH"])
    }

    @Test("Provenienz-Labels sind übersetzt (kein Key-Durchschlag im Chip)")
    func labelsResolveFromCatalog() {
        for provenance in DoseIntakeProvenance.allCases {
            let label = String(localized: provenance.labelResource)
            #expect(!label.isEmpty)
            #expect(
                label != "med.ledger.provenance.\(provenance.rawValue.lowercased())",
                "Der Chip würde den Katalog-Key statt eines Labels rendern: \(label)"
            )
            #expect(!label.hasPrefix("med.ledger."), "Unaufgelöster Katalog-Key: \(label)")
            #expect(!provenance.systemImage.isEmpty)
        }
        // Die a11y-Hülle des Chips ist ebenfalls übersetzt und trägt den Platzhalter.
        let a11y = String(localized: "med.ledger.provenance.a11y")
        #expect(a11y.contains("%@"))
        #expect(a11y != "med.ledger.provenance.a11y")
    }

    // MARK: - Ehrliche Leerstellen

    @Test("Explizites null (Altbestand) und fehlender Schlüssel (≤ v1.32.7) rendern keinen Chip")
    func absentSourceRendersNoChip() async throws {
        respond(rows: [
            row(id: "e-null", day: 6, source: "null"),
            row(id: "e-absent", day: 7, source: nil)
        ])
        let ledger = try await makeRepo().doseHistory(medicationID: "med-1")
        #expect(ledger.rows.count == 2)
        #expect(ledger.rows[0].intake?.source == nil)
        #expect(ledger.rows[0].provenance == nil)
        #expect(ledger.rows[1].intake?.source == nil)
        #expect(ledger.rows[1].provenance == nil)
    }

    @Test("Sechstes, unbekanntes Literal: Zeile überlebt, Chip bleibt aus")
    func unknownSourceLiteralIsTolerated() async throws {
        respond(rows: [
            row(id: "e-future", day: 8, source: "SHORTCUT"),
            row(id: "e-web", day: 9, source: "WEB")
        ])
        let ledger = try await makeRepo().doseHistory(medicationID: "med-1")
        // Kein Decode-Fehler, keine verworfene Zeile.
        #expect(ledger.rows.count == 2)
        #expect(ledger.rows[0].intake?.source == "SHORTCUT")
        #expect(ledger.rows[0].provenance == nil, "Ein unbenennbarer Wert darf kein Label erfinden")
        #expect(ledger.rows[1].provenance == .web)
    }

    @Test("Eine Zeile ohne Intake trägt nie eine Provenienz")
    func projectedSlotHasNoProvenance() async throws {
        respond(rows: [
            #"""
            {"kind":"slot","at":"2026-07-10T06:00:00.000Z","timeOfDay":"08:00","status":"missed","intake":null}
            """#
        ])
        let ledger = try await makeRepo().doseHistory(medicationID: "med-1")
        #expect(ledger.rows[0].intake == nil)
        #expect(ledger.rows[0].provenance == nil)
    }
}
