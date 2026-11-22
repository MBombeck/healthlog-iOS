import Foundation
@testable import HealthLog
import Testing

/// Documents, recently deleted documents, allergies and family history in the
/// one row form: a title, one detail line of side facts joined by ", ", and
/// at most one status as text.
@MainActor
@Suite("E-P3 documents and records: one row form")
struct EP3DocumentsRowFormTests {
    private func document(
        title: String? = "Befund Hausarzt",
        filename: String? = "befund.pdf",
        byteSize: Int = 3_460_000,
        documentDate: String? = "2026-10-21",
        servingClass: DocumentServingClass = .inline,
        conditions: [DocumentConditionLink] = []
    ) -> InboundDocument {
        InboundDocument(
            id: "d1",
            kind: .doctorReport,
            title: title,
            filename: filename,
            mimeType: "application/pdf",
            byteSize: byteSize,
            status: .stored,
            providerType: nil,
            reportDate: nil,
            documentDate: documentDate,
            errorReason: nil,
            factCount: 0,
            pendingCount: 0,
            conditionLinks: conditions,
            servingClass: servingClass,
            createdAt: "2026-10-21T08:00:00Z",
            updatedAt: "2026-10-21T08:00:00Z"
        )
    }

    // MARK: - Document row

    @Test("The detail line is filename, date and size, in one line")
    func detailLineJoinsFilenameDateAndSize() {
        let doc = document()
        let content = DocumentRowContent(document: doc, isProcessing: false, isReady: false)
        let expected = [
            "befund.pdf",
            DocumentFormat.mediumDate("2026-10-21"),
            DocumentFormat.bytes(3_460_000)
        ].joined(separator: ", ")
        #expect(content.title == "Befund Hausarzt")
        #expect(content.detail == expected)
        #expect(content.detail?.contains("\n") == false)
    }

    @Test("A document named after its file does not repeat the filename")
    func filenameAsTitleIsNotRepeated() {
        let content = DocumentRowContent(
            document: document(title: nil),
            isProcessing: false,
            isReady: false
        )
        #expect(content.title == "befund.pdf")
        #expect(content.detail == [
            DocumentFormat.mediumDate("2026-10-21"),
            DocumentFormat.bytes(3_460_000)
        ].joined(separator: ", "))
    }

    @Test("Without title and filename the row says untitled")
    func untitledFallback() {
        let content = DocumentRowContent(
            document: document(title: nil, filename: nil),
            isProcessing: false,
            isReady: false
        )
        #expect(content.title == String(localized: "documents.card.untitled"))
    }

    @Test("Linked conditions stay on the detail page, not in the row")
    func conditionsAreNotInTheRow() {
        let link = DocumentConditionLink(episodeId: "e1", name: "Bronchitis")
        let content = DocumentRowContent(
            document: document(conditions: [link]),
            isProcessing: false,
            isReady: false
        )
        #expect(content.detail?.contains("Bronchitis") == false)
        #expect(content.status == nil)
    }

    private struct StatusCase {
        let processing: Bool
        let ready: Bool
        let serving: DocumentServingClass
        let expected: DocumentRowContent.Status?
    }

    @Test("At most one status, the most urgent first")
    func oneStatusByPriority() {
        let cases = [
            StatusCase(processing: true, ready: true, serving: .attachment, expected: .processing),
            StatusCase(processing: false, ready: true, serving: .attachment, expected: .ready),
            StatusCase(processing: false, ready: false, serving: .attachment, expected: .downloadOnly),
            StatusCase(processing: false, ready: false, serving: .inline, expected: nil)
        ]
        for item in cases {
            let content = DocumentRowContent(
                document: document(servingClass: item.serving),
                isProcessing: item.processing,
                isReady: item.ready
            )
            #expect(content.status == item.expected)
        }
    }

    @Test("The status is text with its tone: only a finished read is green")
    func statusMapsToRowStatus() {
        let ready = DocumentRowContent(document: document(), isProcessing: false, isReady: true)
        #expect(ready.rowStatus == HLRowStatus(
            String(localized: "documents.card.ready"),
            icon: "checkmark.circle",
            tone: .success
        ))
        let processing = DocumentRowContent(document: document(), isProcessing: true, isReady: false)
        #expect(processing.rowStatus?.tone == .neutral)
        #expect(processing.rowStatus?.title == String(localized: "documents.card.processing"))
        let download = DocumentRowContent(
            document: document(servingClass: .attachment),
            isProcessing: false,
            isReady: false
        )
        #expect(download.rowStatus?.tone == .neutral)
        #expect(download.rowStatus?.title == String(localized: "documents.card.attachmentBadge"))
        #expect(DocumentRowContent(document: document(), isProcessing: false, isReady: false).rowStatus == nil)
    }

    @Test("VoiceOver hears title, detail line and status in reading order")
    func accessibilityTextFollowsTheRow() {
        let content = DocumentRowContent(document: document(), isProcessing: true, isReady: false)
        let text = content.accessibilityText
        #expect(text.hasPrefix("Befund Hausarzt, befund.pdf"))
        #expect(text.hasSuffix(String(localized: "documents.card.processing")))
    }

    // MARK: - Recently deleted

    @Test("A deleted document's two dates share one detail line")
    func deletedDatesShareOneLine() {
        let row = DeletedDocument(
            id: "d1", deletedAt: "2026-11-01T10:00:00.000Z", purgeAt: "2026-12-01T10:00:00.000Z"
        )
        let lines = DeletedDocumentRowDates.lines(for: row)
        let detail = HLRowDetail.joined(lines)
        #expect(detail == lines.joined(separator: ", "))
        #expect(HLRowDetail.joined(DeletedDocumentRowDates.lines(for: DeletedDocument(id: "d2"))) == nil)
    }

    // MARK: - Records

    private func allergy(
        severity: AllergySeverity? = .severe,
        status: AllergyStatus = .active
    ) -> AllergyDTO {
        AllergyDTO(
            id: "a1", substance: "Penicillin", category: .medication, type: .allergy,
            severity: severity, status: status, onsetAt: nil,
            reaction: "Anaphylaxis", note: nil, createdAt: "", updatedAt: ""
        )
    }

    @Test("An allergy's detail line is type, category and severity")
    func allergyDetailOrder() {
        let parts = RecordsRowContent.allergyDetailParts(allergy())
        #expect(HLRowDetail.joined(parts) == [
            AllergyType.allergy.localizedLabel,
            AllergyCategory.medication.localizedLabel,
            AllergySeverity.severe.localizedLabel
        ].joined(separator: ", "))
    }

    @Test("A severity the app does not know is left out, not guessed")
    func unknownSeverityDropsOut() {
        let unknown = HLRowDetail.joined(RecordsRowContent.allergyDetailParts(allergy(severity: .unknown)))
        let none = HLRowDetail.joined(RecordsRowContent.allergyDetailParts(allergy(severity: nil)))
        let expected = [AllergyType.allergy.localizedLabel, AllergyCategory.medication.localizedLabel]
            .joined(separator: ", ")
        #expect(unknown == expected)
        #expect(none == expected)
    }

    @Test("Only a record that no longer applies carries a status")
    func allergyStatusOnlyWhenNotActive() {
        #expect(RecordsRowContent.allergyStatus(allergy(status: .active)) == nil)
        #expect(RecordsRowContent.allergyStatus(allergy(status: .resolved)) == AllergyStatus.resolved.localizedLabel)
        #expect(RecordsRowContent.allergyStatus(allergy(status: .inactive)) == AllergyStatus.inactive.localizedLabel)
    }

    @Test("A family entry's detail line is the relative and the age at onset")
    func familyDetailLine() {
        let entry = FamilyHistoryEntryDTO(
            id: "f1", relationship: .mother, condition: "Diabetes",
            ageAtOnset: 52, note: nil, createdAt: "", updatedAt: ""
        )
        let age = String(format: String(localized: "familyHistory.row.ageAtOnset"), 52)
        #expect(HLRowDetail.joined(RecordsRowContent.familyDetailParts(entry))
            == "\(FamilyRelationship.mother.localizedLabel), \(age)")

        let noAge = FamilyHistoryEntryDTO(
            id: "f2", relationship: .father, condition: "Gout",
            ageAtOnset: nil, note: nil, createdAt: "", updatedAt: ""
        )
        #expect(HLRowDetail.joined(RecordsRowContent.familyDetailParts(noAge))
            == FamilyRelationship.father.localizedLabel)
    }
}
