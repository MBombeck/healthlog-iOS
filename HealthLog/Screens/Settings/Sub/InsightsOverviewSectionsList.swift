import SwiftUI

/// **Parity Build 4 · 4.5 — the Insights-overview arrangement, at last.**
///
/// The iOS twin of the web `InsightsEditMode` section list
/// (`insights-edit-mode.tsx:369-418`, embedded in Settings via
/// `insights-overview-arrange-section.tsx`): one row per overview block, an
/// eye/visibility control, drag to reorder.
///
/// Web has had this since v1.15.11. iOS had **no `sections` concept at all** —
/// the model round-tripped the array as an opaque echo and nothing read it — so
/// section show/hide and reorder were completely unreachable from the phone.
/// That was the only P0 in the layout/dashboard/insights audit cluster
/// (`12-layout-dashboard-insights-domains.md` §A #1/#2).
///
/// A `Section` of the parent `List`, extracted into its own file/type purely for
/// file-length discipline. Both controls write straight through
/// `InsightsLayoutStore` (optimistic write-through + Outbox replay), exactly
/// like the tab-strip list above it.
struct InsightsOverviewSectionsList: View {
    @Environment(InsightsLayoutStore.self) private var layoutStore

    /// Sections whose row is editable from iOS but which iOS does not render.
    ///
    /// - `period-review`: the retrospective card was removed from the iOS
    ///   overview in v0.14.9 on an operator call ("doesn't fit, too much") — a
    ///   documented divergence, not a gap to close.
    /// - `ecg`: iOS has no ECG surface yet (`02-insights.md` §B; scheduled for a
    ///   later build). The row still rides the same `sections` array, so hiding
    ///   or moving it from the phone correctly rearranges the WEB overview.
    ///
    /// 1.4 B2-c — these rows are not listed on iOS any more: a switch that
    /// changes nothing on this phone needed a "shown on the web only" line to
    /// be honest, and the honest answer is not to offer it here. Their place in
    /// the shared `sections` array is kept on every reorder (see ``move``).
    private static let webOnlySectionIDs: Set<String> = [
        InsightsLayoutSectionId.periodReview,
        InsightsLayoutSectionId.ecg
    ]

    /// Localized label per server section id. A static table rather than a
    /// `switch` so the twelve-case lookup stays a single audit point and dodges
    /// the cyclomatic-complexity budget (same idiom as
    /// `InsightsLayoutTileId.catalogueTypeToServerId`). Values are resolved
    /// lazily in `label(for:)` so `String(localized:)` runs at render time.
    private static let labelKeys: [String: LocalizedStringResource] = [
        InsightsLayoutSectionId.wellnessScores: "Your health scores",
        InsightsLayoutSectionId.dailyBriefing: "Daily briefing",
        InsightsLayoutSectionId.vitals: "Vitals",
        InsightsLayoutSectionId.trends: "Trends",
        InsightsLayoutSectionId.periodReview: "Period review",
        InsightsLayoutSectionId.cycleSummary: "Cycle summary",
        InsightsLayoutSectionId.signals: "Signals of the day",
        InsightsLayoutSectionId.rhythmEvents: "Heart rhythm events",
        InsightsLayoutSectionId.healthStatus: "Health status",
        InsightsLayoutSectionId.breathing: "Breathing during sleep",
        InsightsLayoutSectionId.labsChanges: "Lab changes",
        InsightsLayoutSectionId.ecg: "ECG recordings"
    ]

    var body: some View {
        Section {
            ForEach(shownSections) { section in
                row(for: section)
            }
            .onMove(perform: move)
        } header: {
            // R12 — Abschnitts-Header im List-Gerüst: System-Default.
            Text(String(localized: "Overview sections"))
        }
        // UI-Standard R3 — der Abschnitts-Footer ist gefallen. Er sagte
        // dasselbe wie der Tabs-Footer eine Sektion darüber („zum Verschieben
        // gedrückt halten", „ohne Daten bleibt es ausgeblendet") und begann mit
        // einer Umformulierung seines eigenen Headers. Die Aussage hat ihre
        // Heimat im ersten Abschnitt dieses Screens.
    }

    private func row(for section: InsightsLayoutSection) -> some View {
        Toggle(isOn: binding(for: section.id)) {
            Text(label(for: section.id))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
        }
        .accessibilityIdentifier("settings.insights.section.\(section.id)")
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { layoutStore.layout.isSectionVisible(id) },
            set: { _ in Task { await layoutStore.toggleSectionVisible(forId: id) } }
        )
    }

    /// The sections this phone renders, in the stored order.
    private var shownSections: [InsightsLayoutSection] {
        layoutStore.sections.filter { !Self.webOnlySectionIDs.contains($0.id) }
    }

    /// Reorders the shown rows and writes the full order back with every
    /// web-only section at the index it already had.
    private func move(from source: IndexSet, to destination: Int) {
        var shown = shownSections.map(\.id)
        shown.move(fromOffsets: source, toOffset: destination)
        Task { await layoutStore.reorderSections(Self.merge(shown: shown, into: layoutStore.sections.map(\.id))) }
    }

    /// `all` with its shown ids replaced, slot by slot, by `shown`; the
    /// web-only ids keep their slots. Pure for the test.
    static func merge(shown: [String], into all: [String]) -> [String] {
        var next = shown.makeIterator()
        return all.map { webOnlySectionIDs.contains($0) ? $0 : (next.next() ?? $0) }
    }

    /// Falls back to the raw slug for a section id a future server release adds
    /// — the row still round-trips and stays orderable, it just has no name yet.
    private func label(for id: String) -> String {
        guard let key = Self.labelKeys[id] else { return id }
        return String(localized: key)
    }
}
