import Foundation
@testable import HealthLog
import Testing

/// **Wave 4.1 — the persisted-summary DTO gap.**
///
/// Before this wave `DocumentDTO.swift` decoded neither `summary` nor
/// `summaryGeneratedAt` nor `contentIndexSource`, so the prose the web shows at
/// the top of a document could not appear on iOS at all. These tests pin (1)
/// that the three fields now decode, (2) that every degenerate wire shape —
/// key absent, explicit `null`, an unknown enum literal, a wrong-typed value —
/// decodes CLEANLY instead of failing the enclosing list, and (3) the derived
/// helpers (`isAiRead`, `resolvedSummary`, `labFactCount`) the detail screen
/// paints from.
@Suite("Documents — persisted summary + content-index source decode")
struct DocumentSummaryDecodeTests {
    /// Minimal valid document wire shape; `extra` splices in the fields under test.
    private func documentObject(extra: String = "") -> String {
        let base = #"""
        "id":"d1","kind":"LAB_RESULT","mimeType":"application/pdf","byteSize":100,
        "status":"STORED","createdAt":"2026-07-18T08:00:00.000Z",
        "updatedAt":"2026-07-18T08:00:00.000Z","hasContentIndex":true
        """#
        return "{\(base)\(extra)}"
    }

    private func documentJSON(extra: String = "") -> Data {
        Data(documentObject(extra: extra).utf8)
    }

    private func decode(_ data: Data) throws -> InboundDocument {
        try JSONDecoder.hlDefault.decode(InboundDocument.self, from: data)
    }

    // MARK: - Field present

    @Test("Present: summary, summaryGeneratedAt and contentIndexSource all decode")
    func fieldsPresent() throws {
        let doc = try decode(documentJSON(
            extra: #","summary":"Ein Laborbefund vom Hausarzt.","summaryGeneratedAt":"2026-07-18T08:05:00.000Z","contentIndexSource":"vision""#
        ))
        #expect(doc.summary == "Ein Laborbefund vom Hausarzt.")
        #expect(doc.resolvedSummary == "Ein Laborbefund vom Hausarzt.")
        #expect(doc.summaryGeneratedAt == "2026-07-18T08:05:00.000Z")
        #expect(doc.contentIndexSource == .vision)
        #expect(doc.isAiRead, "vision + hasContentIndex is the AI-read provenance case")
    }

    @Test("Every known contentIndexSource literal decodes; only vision is an AI read")
    func knownSourcesDecode() throws {
        struct SourceCase {
            let raw: String
            let expected: DocumentContentIndexSource
            let isAiRead: Bool
        }
        let cases = [
            SourceCase(raw: "vision", expected: .vision, isAiRead: true),
            SourceCase(raw: "text-ocr", expected: .textOCR, isAiRead: false),
            SourceCase(raw: "local-pdf", expected: .localPDF, isAiRead: false),
            SourceCase(raw: "local-ocr", expected: .localOCR, isAiRead: false)
        ]
        for c in cases {
            let doc = try decode(documentJSON(extra: #","contentIndexSource":"\#(c.raw)""#))
            #expect(doc.contentIndexSource == c.expected, "\(c.raw) decodes")
            #expect(doc.contentIndexSource?.isAiReadSource == c.isAiRead)
            #expect(doc.isAiRead == c.isAiRead)
        }
    }

    // MARK: - Field absent

    @Test("Absent: an older server that omits all three keys decodes with nil")
    func fieldsAbsent() throws {
        let doc = try decode(documentJSON())
        #expect(doc.summary == nil)
        #expect(doc.resolvedSummary == nil)
        #expect(doc.summaryGeneratedAt == nil)
        #expect(doc.contentIndexSource == nil)
        #expect(!doc.isAiRead, "no source ⇒ never claim an AI read")
    }

    // MARK: - Field null

    @Test("Null: explicit JSON null on all three decodes to nil, never throws")
    func fieldsNull() throws {
        let doc = try decode(documentJSON(
            extra: #","summary":null,"summaryGeneratedAt":null,"contentIndexSource":null"#
        ))
        #expect(doc.summary == nil)
        #expect(doc.summaryGeneratedAt == nil)
        #expect(doc.contentIndexSource == nil)
        #expect(!doc.isAiRead)
    }

    // MARK: - Unknown / hostile enum literal

    @Test("Unknown enum literal → .unknown, and never an AI read")
    func unknownSourceLiteral() throws {
        let doc = try decode(documentJSON(extra: #","contentIndexSource":"quantum-ocr""#))
        #expect(doc.contentIndexSource == .unknown, "a future server source degrades, it does not throw")
        #expect(doc.contentIndexSource?.isAiReadSource == false)
        #expect(!doc.isAiRead, "an unrecognised source is conservatively NOT provenance for an AI read")
    }

    @Test("Wrong-typed contentIndexSource degrades to nil instead of failing the decode")
    func wrongTypedSource() throws {
        let doc = try decode(documentJSON(extra: #","contentIndexSource":42"#))
        #expect(doc.contentIndexSource == nil)
        #expect(doc.id == "d1", "the rest of the document still decodes")
    }

    @Test("A whole list page survives one hostile row (tolerance is non-breaking)")
    func listSurvivesHostileRow() throws {
        let good = documentObject(extra: #","contentIndexSource":"vision","summary":"Da.""#)
        let hostile = documentObject(extra: #","contentIndexSource":"brand-new-source","summary":null"#)
        let json = Data(#"{"documents":[\#(good),\#(hostile)],"nextCursor":null}"#.utf8)
        let page = try JSONDecoder.hlDefault.decode(InboundDocumentList.self, from: json)
        #expect(page.documents.count == 2)
        #expect(page.documents[0].isAiRead)
        #expect(page.documents[1].contentIndexSource == .unknown)
        #expect(page.documents[1].resolvedSummary == nil)
    }

    // MARK: - resolvedSummary

    @Test("A whitespace-only summary resolves to nil so no empty section paints")
    func blankSummaryResolvesNil() throws {
        let doc = try decode(documentJSON(extra: #","summary":"   \n  ""#))
        #expect(doc.summary != nil, "the raw wire value is preserved")
        #expect(doc.resolvedSummary == nil, "but the render-time value is nil")
    }

    // MARK: - Detail envelope

    @Test("Detail flattens summary onto the document and exposes it + labFactCount")
    func detailFlattensSummary() throws {
        let json = Data(#"""
        {"id":"d1","kind":"LAB_RESULT","mimeType":"application/pdf","byteSize":100,"status":"EXTRACTED",
         "createdAt":"2026-07-18T08:00:00.000Z","updatedAt":"2026-07-18T08:00:00.000Z",
         "hasContentIndex":true,"contentIndexSource":"vision",
         "summary":"Blutbild vom 12. Juli.","summaryGeneratedAt":"2026-07-18T08:05:00.000Z",
         "facts":[
           {"id":"f1","factType":"OBSERVATION","status":"PENDING"},
           {"id":"f2","factType":"OBSERVATION","status":"APPROVED"},
           {"id":"f3","factType":"OBSERVATION","status":"REJECTED"},
           {"id":"f4","factType":"CONDITION","status":"PENDING"}
         ]}
        """#.utf8)
        let detail = try JSONDecoder.hlDefault.decode(InboundDocumentDetail.self, from: json)
        #expect(detail.summary == "Blutbild vom 12. Juli.")
        #expect(detail.summaryGeneratedAt == "2026-07-18T08:05:00.000Z")
        #expect(detail.document.isAiRead)
        #expect(detail.labFactCount == 2, "non-rejected OBSERVATION facts only — CONDITION and REJECTED excluded")
    }

    @Test("labFactCount is 0 without facts, so the Labs jump stays hidden")
    func labFactCountEmpty() {
        #expect(InboundDocumentDetail.labFactCount(in: []) == 0)
    }

    // MARK: - Round-trip

    @Test("Encode → decode round-trips the new fields")
    func roundTrip() throws {
        let doc = InboundDocument(
            id: "d1", kind: .labResult, title: "T", filename: nil,
            mimeType: "application/pdf", byteSize: 10, status: .stored,
            providerType: nil, reportDate: nil, documentDate: nil, errorReason: nil,
            factCount: 0, pendingCount: 0, conditionLinks: [], servingClass: .inline,
            hasContentIndex: true, contentIndexSource: .localPDF,
            summary: "Kurz.", summaryGeneratedAt: "2026-07-18T08:05:00.000Z",
            createdAt: "2026-07-18T08:00:00.000Z", updatedAt: "2026-07-18T08:00:00.000Z"
        )
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder.hlDefault.decode(InboundDocument.self, from: data)
        #expect(back == doc)
        #expect(back.contentIndexSource == .localPDF)
        #expect(!back.isAiRead, "a local PDF extraction is not an AI read")
    }
}

/// **Wave 4.6 — the bounded processing window** behind the list card's
/// "Wird verarbeitet…" / "Bereit" chips and the post-upload poll. Mirrors the
/// web `vault-utils.ts` (`RECENT_UPLOAD_WINDOW_MS`, `isDocumentProcessing`,
/// `hasProcessingDocument`). The point of the window is that it is BOUNDED: an
/// old, permanently-unindexed document must never show a stuck chip and must
/// never keep the list polling.
@Suite("Documents — processing window")
struct DocumentProcessingWindowTests {
    private func document(createdAt: Date, indexed: Bool) -> InboundDocument {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return InboundDocument(
            id: "d", kind: .other, title: nil, filename: nil,
            mimeType: "application/pdf", byteSize: 1, status: .stored,
            providerType: nil, reportDate: nil, documentDate: nil, errorReason: nil,
            factCount: 0, pendingCount: 0, conditionLinks: [], servingClass: .inline,
            hasContentIndex: indexed,
            createdAt: iso.string(from: createdAt), updatedAt: iso.string(from: createdAt)
        )
    }

    @Test("A fresh, not-yet-indexed upload is processing")
    func freshUnindexedIsProcessing() {
        let now = Date()
        let doc = document(createdAt: now.addingTimeInterval(-30), indexed: false)
        #expect(DocumentFormat.isProcessing(doc, now: now))
        #expect(DocumentFormat.hasProcessingDocument([doc], now: now))
    }

    @Test("A fresh but already-indexed upload is not processing")
    func freshIndexedIsNotProcessing() {
        let now = Date()
        let doc = document(createdAt: now.addingTimeInterval(-30), indexed: true)
        #expect(!DocumentFormat.isProcessing(doc, now: now))
    }

    @Test("An old, permanently-unindexed document never shows a stuck chip")
    func staleUnindexedIsNotProcessing() {
        let now = Date()
        let doc = document(createdAt: now.addingTimeInterval(-DocumentFormat.recentUploadWindow - 1), indexed: false)
        #expect(!DocumentFormat.isProcessing(doc, now: now))
        #expect(!DocumentFormat.hasProcessingDocument([doc], now: now), "…and never keeps the poll alive")
    }

    @Test("An unparseable createdAt is treated as not-processing (no poll, no chip)")
    func unparseableCreatedAtIsNotProcessing() {
        var doc = document(createdAt: Date(), indexed: false)
        doc = InboundDocument(
            id: doc.id, kind: doc.kind, title: nil, filename: nil,
            mimeType: doc.mimeType, byteSize: 1, status: .stored,
            providerType: nil, reportDate: nil, documentDate: nil, errorReason: nil,
            factCount: 0, pendingCount: 0, conditionLinks: [], servingClass: .inline,
            hasContentIndex: false, createdAt: "not-a-date", updatedAt: "not-a-date"
        )
        #expect(!DocumentFormat.isProcessing(doc))
    }

    @Test("hasProcessingDocument is false for an empty list")
    func emptyList() {
        #expect(!DocumentFormat.hasProcessingDocument([]))
    }
}
