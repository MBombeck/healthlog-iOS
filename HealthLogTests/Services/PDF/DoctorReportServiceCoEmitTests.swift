//
//  DoctorReportServiceCoEmitTests.swift
//  HealthLogTests
//
//  Created 2026-05-22 — v0.6.0 H.6 coverage for the local Doctor-Report
//  flow co-emitting PDF + FHIR R4 Document Bundle JSON in a single
//  `LocalDoctorReportStore.generate(...)` call. Asserts:
//    1. Both `pdfURL` and `fhirURL` are populated.
//    2. `shareItems` returns exactly `[pdfURL, fhirURL]`.
//    3. Both files exist on disk after generate.
//    4. The `.fhir.json` parses back into a valid `ModelsR4.Bundle`
//       of type `.document`.
//    5. Regeneration cleans up BOTH previous artifacts.
//    6. `clearOnLogout()` removes both files + resets URLs.
//

import Foundation
@testable import HealthLog
import ModelsR4
import PDFKit
import Testing

private typealias Measurement = HealthLog.Measurement
private typealias FHIRBundle = ModelsR4.Bundle

/// v0.6.0 H.6 — local Doctor-Report co-emit.
@MainActor
@Suite("LocalDoctorReportStore — H.6 PDF + FHIR co-emit")
struct DoctorReportServiceCoEmitTests {
    private static let now = Date(timeIntervalSince1970: 1_716_000_000)

    // MARK: - Fixtures

    private static func makeStore() async throws -> LocalDoctorReportStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let measurementsRepo = MeasurementsRepository(api: api, outbox: outbox)
        let medicationsRepo = MedicationsRepository(api: api, outbox: outbox)
        let moodRepo = MoodRepository(api: api, outbox: outbox)
        let settingsRepo = SettingsRepository(api: api)
        let measurementsStore = MeasurementsStore(repo: measurementsRepo)
        let medicationsStore = MedicationsStore(repo: medicationsRepo)
        let moodStore = MoodStore(repo: moodRepo)
        let suiteName = "DoctorReportServiceCoEmitTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = SettingsStore(repo: settingsRepo, defaults: defaults)
        return LocalDoctorReportStore(
            measurementsStore: measurementsStore,
            medicationsStore: medicationsStore,
            moodStore: moodStore,
            settingsStore: settingsStore,
            now: { Self.now }
        )
    }

    // MARK: - Tests

    @Test("generate() co-emits both PDF and FHIR JSON URLs")
    func generateCoEmitsBothURLs() async throws {
        let store = try await Self.makeStore()
        await store.generate(locale: .de)

        let pdfURL = try #require(store.pdfURL)
        let fhirURL = try #require(store.fhirURL)
        defer {
            try? FileManager.default.removeItem(at: pdfURL)
            try? FileManager.default.removeItem(at: fhirURL)
        }

        #expect(pdfURL.pathExtension == "pdf")
        #expect(fhirURL.pathExtension == "json")
        #expect(fhirURL.lastPathComponent.hasSuffix(".fhir.json"))
        #expect(store.error == nil)
    }

    @Test("shareItems returns [pdfURL, fhirURL] in operator-primary order")
    func shareItemsReturnsBothInOrder() async throws {
        let store = try await Self.makeStore()
        #expect(store.shareItems.isEmpty)

        await store.generate(locale: .de)
        let pdfURL = try #require(store.pdfURL)
        let fhirURL = try #require(store.fhirURL)
        defer {
            try? FileManager.default.removeItem(at: pdfURL)
            try? FileManager.default.removeItem(at: fhirURL)
        }

        let items = store.shareItems
        #expect(items.count == 2)
        #expect(items.first == pdfURL)
        #expect(items.last == fhirURL)
    }

    @Test("both co-emitted files exist on disk after generate()")
    func bothFilesExistOnDisk() async throws {
        let store = try await Self.makeStore()
        await store.generate(locale: .de)
        let pdfURL = try #require(store.pdfURL)
        let fhirURL = try #require(store.fhirURL)
        defer {
            try? FileManager.default.removeItem(at: pdfURL)
            try? FileManager.default.removeItem(at: fhirURL)
        }

        #expect(FileManager.default.fileExists(atPath: pdfURL.path))
        #expect(FileManager.default.fileExists(atPath: fhirURL.path))
        // PDF is non-empty and reload-able by PDFKit.
        let pdfData = try Data(contentsOf: pdfURL)
        #expect(!pdfData.isEmpty)
        #expect(PDFDocument(data: pdfData) != nil)
        // FHIR is non-empty.
        let fhirData = try Data(contentsOf: fhirURL)
        #expect(!fhirData.isEmpty)
    }

    @Test("FHIR JSON parses to a ModelsR4.Bundle of type .document")
    func fhirJSONParsesToValidBundle() async throws {
        let store = try await Self.makeStore()
        await store.generate(locale: .de)
        let fhirURL = try #require(store.fhirURL)
        defer {
            if let url = store.pdfURL {
                try? FileManager.default.removeItem(at: url)
            }
            try? FileManager.default.removeItem(at: fhirURL)
        }

        let data = try Data(contentsOf: fhirURL)
        let decoded = try JSONDecoder().decode(FHIRBundle.self, from: data)
        #expect(decoded.type.value == .document)
        // Document bundle MUST start with a Composition (FHIR R4 §3.2).
        let entries = try #require(decoded.entry)
        #expect(!entries.isEmpty)
        if case .composition = entries.first?.resource {
            // Expected — Composition is the mandatory first entry.
        } else {
            Issue.record("First entry of a document bundle must be a Composition")
        }
    }

    @Test("regenerate cleans up BOTH previous PDF and FHIR files")
    func regenerationCleansUpBothPreviousFiles() async throws {
        let store = try await Self.makeStore()
        await store.generate(locale: .de)
        let firstPDF = try #require(store.pdfURL)
        let firstFHIR = try #require(store.fhirURL)
        defer {
            try? FileManager.default.removeItem(at: firstPDF)
            try? FileManager.default.removeItem(at: firstFHIR)
        }

        await store.generate(locale: .de)
        let secondPDF = try #require(store.pdfURL)
        let secondFHIR = try #require(store.fhirURL)
        defer {
            try? FileManager.default.removeItem(at: secondPDF)
            try? FileManager.default.removeItem(at: secondFHIR)
        }

        #expect(!FileManager.default.fileExists(atPath: firstPDF.path))
        #expect(!FileManager.default.fileExists(atPath: firstFHIR.path))
        #expect(FileManager.default.fileExists(atPath: secondPDF.path))
        #expect(FileManager.default.fileExists(atPath: secondFHIR.path))
    }

    @Test("clearOnLogout removes both files and resets URLs")
    func clearOnLogoutRemovesBoth() async throws {
        let store = try await Self.makeStore()
        await store.generate(locale: .de)
        let pdfURL = try #require(store.pdfURL)
        let fhirURL = try #require(store.fhirURL)

        store.clearOnLogout()

        #expect(store.pdfURL == nil)
        #expect(store.fhirURL == nil)
        #expect(store.shareItems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pdfURL.path))
        #expect(!FileManager.default.fileExists(atPath: fhirURL.path))
    }
}
