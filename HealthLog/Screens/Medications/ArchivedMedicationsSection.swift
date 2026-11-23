import SwiftUI

/// Archived-medications section host.
///
/// Head, counter, rows and button come from `CollapsedMedicationsSection`,
/// which the „Ausgeblendet“ section shares, so the two read as one pattern.
/// The line under each name says when the medication was archived.
struct ArchivedMedicationsSection: View {
    let medications: [Medication]
    @Binding var isExpanded: Bool
    let onUnarchive: (Medication) -> Void

    var body: some View {
        CollapsedMedicationsSection(
            title: "medications.section.archived.title",
            medications: medications,
            countAccessibilityLabel: Text("medications.section.archived.count_a11y \(medications.count)"),
            isExpanded: $isExpanded,
            detail: { med in med.archivedAt.map(relativeArchive) ?? med.dose },
            action: .init(
                systemImage: "arrow.uturn.backward.circle",
                accessibilityLabel: { "Restore \($0.name)" },
                identifierPrefix: "medications.archived.restore",
                perform: onUnarchive
            )
        )
    }

    /// W-PERF-SWR (High) — shared formatter. `RelativeDateTimeFormatter` is
    /// heavyweight to allocate; building one PER ROW in `relativeArchive` was
    /// pure waste. Hoisted to a static configured once (`.full` units). L1 —
    /// the locale follows the app language (it was pinned to `de_DE`, so the
    /// English UI read "Archiviert vor 3 Tagen").
    static let archiveRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale.current
        return f
    }()

    /// Pure relative-archive label reusing the shared formatter — exposed so a
    /// unit test can assert output parity with a freshly-allocated formatter.
    /// MainActor-isolated (the View is, and `RelativeDateTimeFormatter` is not
    /// `Sendable`). `relativeArchive` is a thin `now`-injecting wrapper.
    static func relativeArchiveLabel(for date: Date, relativeTo reference: Date) -> String {
        let relative = archiveRelativeFormatter.localizedString(for: date, relativeTo: reference)
        return String(localized: "medications.archived.relative \(relative)")
    }

    private func relativeArchive(_ date: Date) -> String {
        Self.relativeArchiveLabel(for: date, relativeTo: .now)
    }
}
