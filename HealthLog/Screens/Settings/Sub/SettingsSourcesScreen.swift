import SwiftUI

/// `/settings/sources` — Quellen-Priorität (Cross-Source-Priority-Leiter).
///
/// **v0.11 Settings-IA-Restructure:** die per-Apple-Health-Typ Sync-Toggles
/// (`dataTypesCard`) sind auf `AppleHealthIntegrationDetailScreen` unter
/// Integrationen gewandert — IA-logisch gehören sie zur Apple-Health-
/// Verbindung. Dieser Top-Level-Settings-Eintrag hostet jetzt NUR noch die
/// Cross-Source-Priority-Leiter (AppleHealth / Withings / Manual / Import pro
/// Metrik). Reiner UI-Re-Parent — `SourcePriorityStore` / `SourcePriority-
/// EditorScreen` unverändert.
///
/// **v0.5.3-F3 erweitert:** Die Karte rendert die per-Metric Source-Ladder
/// read-only (Daten via `SourcePriorityStore` / `GET /api/auth/me/source-
/// priority`) mit einem `NavigationLink` in `SourcePriorityEditorScreen`.
struct SettingsSourcesScreen: View {
    @Environment(SourcePriorityStore.self) private var priorityStore

    var body: some View {
        HLPage {
            // Nothing configured is the whole screen's state: the
            // app's empty lockup on the page, not a card titled like the
            // screen over one grey sentence.
            if !priorityStore.isLoading, priorityStore.metricEntries.isEmpty {
                // What the order is for, and the way to set it, like
                // every other empty page.
                HLEmptyState(
                    icon: "list.number",
                    title: "settings.sources.priority.empty.title",
                    message: "settings.sources.priority.empty.message"
                ) {
                    NavigationLink {
                        SourcePriorityEditorScreen()
                    } label: {
                        HLButtonLabel("Edit order", systemImage: "slider.horizontal.3", variant: .secondary)
                    }
                    .hlPressable()
                    .accessibilityIdentifier("settings.sources.priority.edit")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.sources.priority.empty")
            } else {
                priorityLadderCard
            }
        }
        .navigationTitle("Source priority")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if priorityStore.ladder == nil {
                await priorityStore.load()
            }
        }
    }

    // MARK: - Priority ladder (read-only)

    private var priorityLadderCard: some View {
        // No subtitle: the hub row above says "which source wins
        // per metric" already.
        HLCard("Source priority") {
            if priorityStore.isLoading, priorityStore.ladder == nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, HLSpace.sm)
            } else {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(priorityStore.metricEntries) { row in
                        priorityRow(row)
                    }
                    // R8/R10 — war eine handgebaute Chevron-Zeile mit eigenem
                    // Icon-Glyph; jetzt der kanonische Auslöser mit
                    // Icon-Chip (26×26) und Primitive-eigenem Chevron.
                    HLSettingsActionRow(
                        icon: "slider.horizontal.3",
                        title: "Edit order",
                        presents: .push
                    ) {
                        SourcePriorityEditorScreen()
                    }
                    .accessibilityIdentifier("settings.sources.priority.edit")
                }
            }
        }
    }

    /// One source per row (rank · icon · name), matching the
    /// reorder editor's `editorRow` layout instead of the old horizontal capsule
    /// strip. The strip squished + truncated once a metric carried three or four
    /// sources; the vertical list stays readable at any count.
    private func priorityRow(_ row: SourcePriorityRow) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HLRowTitle(Text(LocalizedStringKey(row.label)))
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                ForEach(Array(row.sources.enumerated()), id: \.offset) { index, source in
                    HStack(spacing: HLSpace.sm) {
                        Text("\(index + 1).")
                            .font(HLRowTitle.font)
                            .foregroundStyle(HLText.tertiary)
                            .monospacedDigit()
                            .frame(width: 20, alignment: .leading)
                        HLRowGlyph(symbol: SourcePriorityRow.iconName(forSource: source))
                        Text(LocalizedStringKey(SourcePriorityRow.displayLabel(forSource: source)))
                            .hlText(.prose)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                "\(Text(LocalizedStringKey(row.label))): \(row.sources.map { SourcePriorityRow.displayLabel(forSource: $0) }.joined(separator: ", "))"
            )
        )
    }
}
