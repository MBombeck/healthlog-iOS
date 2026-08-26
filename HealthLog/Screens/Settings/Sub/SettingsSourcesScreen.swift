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
        HLSettingsPage(title: "Source priority") {
            priorityLadderCard
        }
        .navigationTitle("Source priority")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if priorityStore.ladder == nil {
                await priorityStore.load()
            }
        }
    }

    // MARK: - Priority ladder (v0.5.3-F3 read-only)

    private var priorityLadderCard: some View {
        HLSettingsCard(
            icon: "list.number",
            title: "Source priority",
            subtitle: "Which source wins per metric when values overlap."
        ) {
            if priorityStore.isLoading, priorityStore.ladder == nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, HLSpace.sm)
            } else if priorityStore.metricEntries.isEmpty {
                Text("No source priority configured yet.")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            } else {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(priorityStore.metricEntries) { row in
                        priorityRow(row)
                    }
                    Divider().opacity(0.4)
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

    /// FW-SOURCES (b210) — one source per row (rank · icon · name), matching the
    /// reorder editor's `editorRow` layout instead of the old horizontal capsule
    /// strip. The strip squished + truncated once a metric carried three or four
    /// sources; the vertical list stays readable at any count.
    private func priorityRow(_ row: SourcePriorityRow) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(LocalizedStringKey(row.label))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                ForEach(Array(row.sources.enumerated()), id: \.offset) { index, source in
                    HStack(spacing: HLSpace.sm) {
                        Text("\(index + 1).")
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.tertiary)
                            .monospacedDigit()
                            .frame(width: 20, alignment: .leading)
                        Image(systemName: SourcePriorityRow.iconName(forSource: source))
                            .font(.hlIcon(HLIconSize.rowAction))
                            .foregroundStyle(HLText.secondary)
                            .frame(width: 22)
                        Text(LocalizedStringKey(SourcePriorityRow.displayLabel(forSource: source)))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("\(row.label): \(row.sources.map { SourcePriorityRow.displayLabel(forSource: $0) }.joined(separator: ", "))")
        )
    }
}
