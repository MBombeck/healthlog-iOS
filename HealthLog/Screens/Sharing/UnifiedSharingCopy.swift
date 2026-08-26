import SwiftUI

/// Every localized value the unified sharing surface renders, in one place.
///
/// **Values, not views.** The screen was split for length, and this is the half
/// that carries no layout at all: labels, the two counted summaries, the four
/// action titles and the provenance badge. Keeping the split on that line means
/// a later reader looking for "what does this surface call the ZIP" has exactly
/// one file to open, and the view files stay about arrangement.
@MainActor
enum UnifiedSharingCopy {
    /// "12 of 91 selected" — resolved with the counts so the panel is honest
    /// about the scope without the user opening the drawer.
    static func countSummary(_ store: UnifiedSharingStore) -> String {
        String(
            format: String(localized: "report.selection.count"),
            store.chosen.count,
            store.offeredLeaves.count
        )
    }

    static func droppedSummary(_ store: UnifiedSharingStore) -> String {
        String(format: String(localized: "sharing.unified.dropped"), store.droppedForForm.count)
    }

    static func periodLabel(_ days: Int) -> LocalizedStringKey {
        switch days {
        case 30: "30 days"
        case 90: "90 days"
        case 180: "6 months"
        default: "1 year"
        }
    }

    static func formTitle(_ form: UnifiedSharingStore.OutputForm) -> LocalizedStringKey {
        switch form {
        case .link: "sharing.unified.form.link.title"
        case .pdf: "sharing.unified.form.pdf.title"
        case .zip: "sharing.unified.form.zip.title"
        case .fhir: "sharing.unified.form.fhir.title"
        }
    }

    static func formBody(_ form: UnifiedSharingStore.OutputForm) -> LocalizedStringKey {
        switch form {
        case .link: "sharing.unified.form.link.body"
        case .pdf: "sharing.unified.form.pdf.body"
        case .zip: "sharing.unified.form.zip.body"
        case .fhir: "sharing.unified.form.fhir.body"
        }
    }

    static func actionTitle(_ form: UnifiedSharingStore.OutputForm) -> String.LocalizationValue {
        switch form {
        case .link: "sharing.unified.action.link"
        case .pdf: "sharing.unified.action.pdf"
        case .zip: "sharing.unified.action.zip"
        case .fhir: "sharing.unified.action.fhir"
        }
    }

    /// FW5-C's provenance badge, kept per output because "your server" means a
    /// rendered PDF on one path and the canonical FHIR bundle on the other.
    static func sourceLabel(_ source: FHIRExportSource, form: UnifiedSharingStore.OutputForm) -> String {
        switch (source, form) {
        case (.server, .fhir): String(localized: "Source: your server (canonical FHIR).")
        case (.local, .fhir): String(localized: "Source: this device (offline FHIR).")
        case (.server, _): String(localized: "Source: your server (rendered PDF).")
        case (.local, _): String(localized: "Source: this device (offline PDF).")
        }
    }

    /// The two things the selection panel may have to say about itself, moved
    /// here with the panel it used to live on (`ReportSelectionCard`, removed
    /// in 18-03).
    static func noticeText(_ notice: ReportSelectionStore.Notice) -> String {
        switch notice {
        case .rebuiltFromCapabilities:
            String(localized: "report.selection.notice.rebuilt")
        case let .droppedRetiredLeaves(count):
            String(format: String(localized: "report.selection.notice.dropped"), count)
        }
    }
}
