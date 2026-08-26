import SwiftUI

/// Per-kind presentation metadata (mirror of the web `document-kind-meta.ts`).
/// There is NO per-kind colour/tint — icons render monochrome; only an SF Symbol
/// + a localized German label per kind. The display order is fixed and shared by
/// the filter chip rail, the bulk "set kind" menu, and the cards.
enum DocumentKindMeta {
    /// The fixed display order (web `DOCUMENT_KIND_ORDER`).
    static let order: [DocumentKind] = [
        .doctorReport, .labResult, .imaging, .dischargeLetter,
        .prescription, .referral, .vaccination, .insurance, .other
    ]

    /// The localized label key for a kind (`documents.kind.<KIND>`, de + en).
    static func labelKey(_ kind: DocumentKind) -> LocalizedStringKey {
        switch kind {
        case .doctorReport: "documents.kind.doctorReport"
        case .dischargeLetter: "documents.kind.dischargeLetter"
        case .labResult: "documents.kind.labResult"
        case .imaging: "documents.kind.imaging"
        case .prescription: "documents.kind.prescription"
        case .referral: "documents.kind.referral"
        case .insurance: "documents.kind.insurance"
        case .vaccination: "documents.kind.vaccination"
        case .other: "documents.kind.other"
        }
    }

    /// The SF Symbol for a kind (stands in for the web Lucide glyph).
    static func icon(_ kind: DocumentKind) -> String {
        switch kind {
        case .doctorReport: "stethoscope"
        case .dischargeLetter: "doc.text"
        case .labResult: "testtube.2"
        case .imaging: "photo.on.rectangle"
        case .prescription: "pills"
        case .referral: "arrow.left.arrow.right"
        case .insurance: "checkmark.shield"
        case .vaccination: "syringe"
        case .other: "doc"
        }
    }
}
