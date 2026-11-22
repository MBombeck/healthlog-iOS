import SwiftUI

/// Two-Axis Source-Priority Editor.
///
/// Erreichbar via `Settings → Quellen → Reihenfolge bearbeiten`. Mirror of
/// the web's `sources-section.tsx` per-metric ladder editor, in iOS-native
/// drag-reorder language.
///
/// **Modell:**
///   - Axis 1 (data-source): `APPLE_HEALTH`, `WITHINGS`, `WHOOP`, `FITBIT`,
///     `MANUAL`, `IMPORT`.
///   - Axis 2 (metric-kind): `steps`, `weight`, `bloodPressure`, `recovery`,
///     … — siehe `SourcePriorityStore.canonicalMetricKeys`.
///
/// Pro Metric eine eigene Sektion mit drag-reorder List. Die oberste Quelle
/// gewinnt, wenn mehrere Quellen einen Wert für denselben Zeitstempel haben
/// (`pickCanonicalSource()` server-seitig). Speichern erfolgt direkt nach
/// `.onMove` (optimistisch + Rollback), kein separater "Speichern"-Button
/// nötig — das mirror'd das Apple-Health-Customisation-Pattern (Dashboard-
/// Anpassen → drop = persist).
///
/// **Reset:** Toolbar-Aktion "Auf Standard zurücksetzen" ruft
/// `SourcePriorityStore.resetToDefaults()` auf — setzt jede Metric auf den
/// kanonischen Server-Default (`DEFAULT_SOURCE_PRIORITY`, mirrored in
/// `SourcePriorityStore.defaultLadder(forMetric:)`).
///
/// **Haptik:** `.sensoryFeedback(.selection, …)` beim Drop. Bei Save-
/// Erfolg leichter Success-Tick. Reduce-Motion respektiert (das ist
/// SwiftUI's `.onMove`-Default).
struct SourcePriorityEditorScreen: View {
    @Environment(SourcePriorityStore.self) private var store

    /// Trigger value for the success-haptic; bumps on every successful PUT.
    @State private var saveTickCount: Int = 0
    /// v0.5.5.1 haptic migration: trigger for the medium-impact drop tick.
    /// Bumps in `handleMove` so SwiftUI's declarative
    /// `.sensoryFeedback(.impact(.medium), trigger:)` fires on every reorder
    /// settle, replacing the legacy `UIImpactFeedbackGenerator(.medium)`.
    @State private var dropTickCount: Int = 0
    /// Drives the confirmation dialog for "Auf Standard zurücksetzen".
    @State private var showResetConfirm: Bool = false

    var body: some View {
        Group {
            if store.isLoading, store.ladder == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .hlScreenBackground()
            } else {
                editorList
            }
        }
        .navigationTitle(Text("Source priority"))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions([
            .more(label: "More actions") {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label(
                        String(localized: "Reset to default"),
                        systemImage: "arrow.uturn.backward"
                    )
                }
                .disabled(store.isSaving)
            }
        ])
        // Every move saves at once. The running save is a state, not an
        // action: the bar's default place, not the leading edge beside back.
        .toolbar {
            ToolbarItem {
                if store.isSaving {
                    HLInlineProgress()
                        .accessibilityLabel(Text("Saving"))
                }
            }
        }
        .hlConfirmDestructive(
            Text("Reset to defaults?"),
            isPresented: $showResetConfirm,
            message: Text(
                "Every metric returns to its recommended default order."
            ),
            confirm: Text(String(localized: "Reset")),
            cancel: Text(String(localized: "Cancel")),
            action: {
                Task {
                    let ok = await store.resetToDefaults()
                    if ok { bumpSaveTick() }
                }
            }
        )
        .sensoryFeedback(.success, trigger: saveTickCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: dropTickCount)
        // The banner below still presents as this overlay; this
        // reserves its height at the top so it covers nothing.
        .hlReserveErrorBannerSpace(store.error)
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.refresh() }
            }
        }
        .task {
            if store.ladder == nil {
                await store.load()
            }
        }
    }

    // MARK: - Editor list

    private var editorList: some View {
        // No empty lead and tail sections: "order your sources"
        // repeated the screen before, and "changes are saved immediately" is
        // what the drag already shows (spinner and haptic).
        List {
            ForEach(store.metricEntries) { row in
                metricSection(row)
            }
        }
        .hlPageMargins()
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
    }

    private func metricSection(_ row: SourcePriorityRow) -> some View {
        let augmented = augmentedSources(row.sources)
        return Section {
            ForEach(Array(augmented.enumerated()), id: \.element) { index, source in
                editorRow(rank: index + 1, source: source, isCanonical: row.sources.contains(source))
            }
            .onMove { offsets, destination in
                handleMove(offsets: offsets, destination: destination, in: row, augmented: augmented)
            }
        } header: {
            HLSectionHeader(LocalizedStringKey(row.label))
        }
        .hlFormRowSurface()
        // Audit-Gruppe 12 — hier stand „Reihenfolge per langem Drücken
        // anpassen." als Section-Footer, also **einmal je Metrik**: bei rund
        // zehn Metriken zehnmal derselbe Satz auf einer Seite. R2 verbietet
        // Bedien-Nacherzählungen als sichtbaren Text; die Drag-Handles der
        // aktiven `editMode`-Liste sagen es selbst. Der VoiceOver-Hint an der
        // Zeile (`accessibilityHint`, unten) bleibt — er ist unsichtbar und
        // trägt die Information für Screenreader.
    }

    private func editorRow(rank: Int, source: String, isCanonical: Bool) -> some View {
        // Rank in the row's title type, as on the source overview; symbol in
        // the row's symbol column.
        HLRowLayout(
            title: Text(LocalizedStringKey(SourcePriorityRow.displayLabel(forSource: source))),
            subtitle: isCanonical ? nil : Text("No values from this source yet")
        ) {
            EmptyView()
        } leading: {
            HStack(spacing: HLSpace.sm) {
                Text("\(rank).")
                    .font(HLRowTitle.font)
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
                    .frame(width: 20, alignment: .leading)
                HLRowGlyph(symbol: sourceIcon(for: source))
            }
        }
        .accessibilityElement(children: .combine)
        // v0.14 i18n P3 — was a German literal ("Rang …") that leaked to VoiceOver
        // under EN. Routed through a localized key (EN "Rank %lld: %@" / DE
        // "Rang %lld: %@").
        .accessibilityLabel(
            Text(String(localized: "Rank \(rank): \(SourcePriorityRow.displayLabel(forSource: source))"))
        )
        .accessibilityHint(Text("Press and drag to reorder."))
    }

    // MARK: - Move logic

    private func handleMove(
        offsets: IndexSet,
        destination: Int,
        in row: SourcePriorityRow,
        augmented: [String]
    ) {
        var mutated = augmented
        mutated.move(fromOffsets: offsets, toOffset: destination)
        // Keep the "canonical" set (the sources the server knows the user
        // actually has values for) intact — augmented tokens that never
        // had data stay in the list but are filtered out before PUT so
        // server-side `sourcePrioritySchema` doesn't reject unknown tokens.
        // The server *does* accept unknown tokens (W5e enumerates the full
        // four-token set), so we keep all of them — letting the user
        // pre-order future sources is the point of the "ghost row".
        dropTickCount &+= 1
        Task {
            let ok = await store.updateLadder(forMetric: row.metricKey, to: mutated)
            if ok { bumpSaveTick() }
        }
    }

    /// Sources the row carries on the wire, padded with any canonical
    /// tokens the server hasn't seen yet so the editor offers the full
    /// four-axis matrix from day one.
    private func augmentedSources(_ wire: [String]) -> [String] {
        var seen = Set(wire.map { $0.uppercased() })
        var augmented = wire
        // Garmin only on a server that takes it in a ladder.
        for token in SourcePriorityStore.offeredSourceTokens() {
            let upper = token.uppercased()
            if !seen.contains(upper) {
                augmented.append(token)
                seen.insert(upper)
            }
        }
        return augmented
    }

    private func bumpSaveTick() {
        saveTickCount &+= 1
    }

    private func sourceIcon(for source: String) -> String {
        // Shared with the read-only settings display so both surfaces render the
        // same per-source glyph.
        SourcePriorityRow.iconName(forSource: source)
    }
}

#if DEBUG
    #Preview("Editor") {
        NavigationStack {
            SourcePriorityEditorScreen()
        }
    }
#endif
