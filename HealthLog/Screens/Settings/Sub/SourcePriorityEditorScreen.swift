import SwiftUI

/// v0.5.4-SP4 — Two-Axis Source-Priority Editor.
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
    /// v0.11 W3 — the per-metric source ladder is persisted + arbitrated
    /// server-side (`pickCanonicalSource()`); the editor PUTs to the server.
    /// Standalone has a single local source, so this surface yields to
    /// `HLCloudDerivedPlaceholder`. `hasServer` is always `true` in paired mode
    /// → inert there. (§4 matrix: source-priority = (B)/hide.)
    @Environment(BackendAvailability.self) private var backend
    /// v0.11 W3 — shared "Server verbinden" CTA path for the placeholder.
    @Environment(AuthStore.self) private var authStore

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
            if !backend.hasServer {
                ScrollView {
                    HLCloudDerivedPlaceholder(
                        variant: .hero,
                        surfaceName: String(localized: "cloud_derived.surface.source_priority"),
                        onConnect: { authStore.beginServerPairing() }
                    )
                    .padding(HLSpace.lg)
                }
                .hlScreenBackground()
            } else if store.isLoading, store.ladder == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .hlScreenBackground()
            } else {
                editorList
            }
        }
        .navigationTitle(Text("Source priority"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label(
                            String(localized: "Reset to default"),
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                    .disabled(store.isSaving)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel(Text("More actions"))
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if store.isSaving {
                    ProgressView()
                        .controlSize(.small)
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
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.refresh() }
            }
        }
        .task {
            // v0.11 W3 — standalone has no server ladder to fetch; firing
            // `store.load()` would 401. Gate on `hasServer` so the placeholder
            // branch never triggers a doomed request.
            if backend.hasServer, store.ladder == nil {
                await store.load()
            }
        }
    }

    // MARK: - Editor list

    private var editorList: some View {
        List {
            introSection
            ForEach(store.metricEntries) { row in
                metricSection(row)
            }
            footerSection
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .hlScreenBackground()
        .hlScrollEdgeSoft()
    }

    private var introSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text(
                "Order your sources per data type. The topmost source wins when several values exist for the same time."
            )
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .padding(.top, HLSpace.xs)
        }
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
            Text(LocalizedStringKey(row.label))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .textCase(nil)
        }
        // Audit-Gruppe 12 — hier stand „Reihenfolge per langem Drücken
        // anpassen." als Section-Footer, also **einmal je Metrik**: bei rund
        // zehn Metriken zehnmal derselbe Satz auf einer Seite. R2 verbietet
        // Bedien-Nacherzählungen als sichtbaren Text; die Drag-Handles der
        // aktiven `editMode`-Liste sagen es selbst. Der VoiceOver-Hint an der
        // Zeile (`accessibilityHint`, unten) bleibt — er ist unsichtbar und
        // trägt die Information für Screenreader.
    }

    private func editorRow(rank: Int, source: String, isCanonical: Bool) -> some View {
        HStack(spacing: HLSpace.md) {
            Text("\(rank).")
                .font(.hlBody.weight(.semibold))
                .foregroundStyle(HLText.tertiary)
                .monospacedDigit()
                .frame(width: 20, alignment: .leading)
            Image(systemName: sourceIcon(for: source))
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(LocalizedStringKey(SourcePriorityRow.displayLabel(forSource: source)))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                if !isCanonical {
                    Text("No values from this source yet")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, HLSpace.xxs)
        .accessibilityElement(children: .combine)
        // v0.14 i18n P3 — was a German literal ("Rang …") that leaked to VoiceOver
        // under EN. Routed through a localized key (EN "Rank %lld: %@" / DE
        // "Rang %lld: %@").
        .accessibilityLabel(
            Text(String(localized: "Rank \(rank): \(SourcePriorityRow.displayLabel(forSource: source))"))
        )
        .accessibilityHint(Text("Press and drag to reorder."))
    }

    private var footerSection: some View {
        Section {
            EmptyView()
        } footer: {
            // Audit-Gruppe 13 — „Quellen ohne Werte werden zur Auswahl
            // angezeigt …" erklärte für die ganze Liste, was die betroffene
            // Zeile selbst markiert („Noch keine Werte aus dieser Quelle",
            // `editorRow`). Die Zeile ist die Heimat (R3, zustandsabhängiger
            // Text schlägt statischen); der Listen-Footer ist gefallen. Die
            // Folge-Aussage „Änderungen werden sofort gespeichert." bleibt —
            // sie ist nirgends sonst sichtbar (R2 Folge).
            Text("Changes are saved immediately.")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .padding(.top, HLSpace.xs)
        }
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
        for token in SourcePriorityStore.canonicalSourceTokens {
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
