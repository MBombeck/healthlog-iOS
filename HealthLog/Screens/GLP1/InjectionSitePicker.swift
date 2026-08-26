import SwiftUI

/// Renders the injection-site picker section: body-map grid that
/// surfaces last-used + suggested-next via subtle highlights, a
/// rotation-hint card, and a recent-history list.
///
/// **MDR boundary:** rotation is hygiene guidance (avoid local
/// lipohypertrophy from repeated same-site injections), not a clinical
/// dosing recommendation. Copy uses "Vorschlag laut Rotationsplan",
/// never "you must".
public struct InjectionSitePicker: View {
    @State private var store: InjectionSiteStore
    @State private var stagedSite: InjectionSite?

    public init(store: InjectionSiteStore) {
        _store = State(initialValue: store)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // T2-4: section label Withings rhythm.
            HLSectionLabel("Injektionsstelle")
            rotationHintCard
            bodyMapCard
            historyCard
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var rotationHintCard: some View {
        // v0.6.1.19 Y10.5 (c): empty-state copy at the bottom is the
        // canonical empty state — the top "Wähle eine Stelle, um die
        // Rotation zu starten" is redundant. Render the hint card
        // only when a rotation suggestion exists.
        if let suggested = store.suggestedNextSite {
            HLCard(style: .ghost) {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(HLText.secondary)
                        Text(String(
                            format: String(localized: "Vorschlag laut Rotationsplan: %@"),
                            suggested.localizedLabel
                        ))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                    }
                    Text(String(localized: "Rotate the site to protect your skin."))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            }
        }
    }

    private var bodyMapCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                InjectionBodyMap(
                    lastUsed: store.lastUsedSite,
                    suggested: store.suggestedNextSite,
                    selected: stagedSite
                ) { site in
                    stagedSite = site
                }
                if let staged = stagedSite {
                    HStack(spacing: HLSpace.sm) {
                        Text(String(
                            format: String(localized: "Selected: %@"),
                            staged.localizedLabel
                        ))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                        Spacer()
                        Button {
                            stagedSite = nil
                        } label: {
                            Text(String(localized: "Reset"))
                                .font(.hlSubhead)
                                .foregroundStyle(HLText.secondary)
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task {
                                await store.log(site: staged)
                                stagedSite = nil
                            }
                        } label: {
                            Text(String(localized: "Log"))
                                .font(.hlSubhead.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historyCard: some View {
        if store.mergedHistory.isEmpty {
            HLCard(style: .ghost) {
                Text(String(localized: "No sites logged yet."))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
        } else {
            HLCard {
                VStack(spacing: 0) {
                    let history = store.mergedHistory
                    ForEach(Array(history.enumerated()), id: \.element.id) { idx, record in
                        HistoryRow(record: record) {
                            if record.source == .local {
                                Task { await store.delete(id: record.id) }
                            }
                        }
                        if idx < history.count - 1 {
                            Divider().background(HLColor.separator)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - History row

private struct HistoryRow: View {
    let record: InjectionSiteRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(record.site.localizedLabel)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Text(record.when.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
            }
            Spacer()
            if record.source == .server {
                HLBadge(String(localized: "Server"), tone: .neutral)
            } else {
                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(HLText.secondary)
                }
                .accessibilityLabel(Text(String(localized: "Entry actions")))
            }
        }
        .padding(.vertical, HLSpace.sm)
        .accessibilityElement(children: .combine)
    }
}
