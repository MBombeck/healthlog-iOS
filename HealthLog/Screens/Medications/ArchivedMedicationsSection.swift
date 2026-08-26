import SwiftUI

/// Archived-medications section host (REG-5, B1 extract, 2026-05-21).
///
/// v0.5.6 — visual contract unified with `ActiveMedicationsSection`.
/// Both sections now lead with the same uppercase-tracked
/// semibold-subhead label on `HLText.secondary` — the canonical
/// monochrome card-group pattern documented in
/// `.planning/v056-marathon/A3-monochrome-template.md` (Insights
/// lineage). The count chip rides on the same row as the section
/// label, matching the inline-metadata rhythm the Active-section
/// follow-up patterns use. The expand/collapse affordance moves
/// *inside* the card (the `DisclosureGroup`'s default chevron handles
/// disclosure state) so the external header stays presentation-only.
///
/// Extracted from `MedicationsScreen.swift` to keep that host under
/// the SwiftLint file-length budget (600 lines). Same lineage as the
/// earlier `ComplianceHeatmapSection.swift` (W-UX2) and
/// `ActiveMedicationRow.swift` (W-MEDS-VISUAL-IMPL, Issue #7) extracts.
struct ArchivedMedicationsSection: View {
    let medications: [Medication]
    @Binding var isExpanded: Bool
    let onUnarchive: (Medication) -> Void

    /// **POLISH-MED (v0.5.5.6).** Header now matches the Apple
    /// grouped-list footnote style adopted across the screen
    /// (`.hlFootnote.weight(.semibold)` uppercased on `.textSecondary`);
    /// the inner `HLCard` wrapper is gone so the `DisclosureGroup` sits
    /// directly on the screen surface alongside the Active section's
    /// free-floating rows. Row chrome inside the disclosure tightens
    /// to match the IntakeRow rhythm (hlSubhead.semibold name +
    /// hlCaption metadata, xs vertical padding).
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.xs) {
                HLSectionLabel("medications.section.archived.title")
                Spacer()
                Text("\(medications.count)")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
                    .accessibilityLabel(
                        Text("medications.section.archived.count_a11y \(medications.count)")
                    )
            }

            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 0) {
                    ForEach(Array(medications.enumerated()), id: \.element.id) { idx, med in
                        HStack(spacing: HLSpace.md) {
                            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                                Text(med.name)
                                    .font(.hlSubhead.weight(.semibold))
                                    .foregroundStyle(HLText.secondary)
                                    .lineLimit(1)
                                if let archivedAt = med.archivedAt {
                                    Text(relativeArchive(archivedAt))
                                        .font(.hlCaption)
                                        .foregroundStyle(HLText.tertiary)
                                        .lineLimit(1)
                                } else {
                                    Text(med.dose)
                                        .font(.hlCaption)
                                        .foregroundStyle(HLText.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button {
                                onUnarchive(med)
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward.circle")
                                    .labelStyle(.iconOnly)
                                    // Audit-01 H4 — glyph on the canonical scale
                                    // (was a raw `.title3`).
                                    .font(.hlIcon(HLIconSize.lg))
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Restore \(med.name)"))
                        }
                        .padding(.vertical, HLSpace.xs)
                        if idx < medications.count - 1 {
                            Divider()
                        }
                    }
                }
            } label: {
                // Disclosure label: presentation-light (the section
                // identity is owned by the external header above), just
                // the toggle affordance copy for at-a-glance reassurance.
                Text(isExpanded ? "medications.section.archived.collapse" : "medications.section.archived.expand")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
            }
        }
    }

    /// W-PERF-SWR (High) — shared formatter. `RelativeDateTimeFormatter` is
    /// heavyweight to allocate; building one PER ROW in `relativeArchive` was
    /// pure waste. Hoisted to a static configured identically (`.full` units,
    /// `de_DE` locale) so the output is byte-for-byte unchanged.
    static let archiveRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: "de_DE")
        return f
    }()

    /// Pure relative-archive label reusing the shared formatter — exposed so a
    /// unit test can assert output parity with a freshly-allocated formatter.
    /// MainActor-isolated (the View is, and `RelativeDateTimeFormatter` is not
    /// `Sendable`). `relativeArchive` is a thin `now`-injecting wrapper.
    static func relativeArchiveLabel(for date: Date, relativeTo reference: Date) -> String {
        "Archiviert \(archiveRelativeFormatter.localizedString(for: date, relativeTo: reference))"
    }

    private func relativeArchive(_ date: Date) -> String {
        Self.relativeArchiveLabel(for: date, relativeTo: .now)
    }
}
