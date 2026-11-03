import SwiftUI

/// Renders the injection-site picker section: body-map grid that
/// surfaces last-used + suggested-next via subtle highlights, the
/// rotation suggestion as the map card's first line, and a recent-history
/// list.
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
            bodyMapCard
            historyCard
        }
    }

    // MARK: - Sections

    /// 1.4 B2 — the rotation suggestion is the body map's own first line, with
    /// its citation beside it, instead of a ghost card above the map. Nothing
    /// renders there before the first site is logged.
    @ViewBuilder
    private var rotationLine: some View {
        if let suggested = store.suggestedNextSite {
            let text = Text(String(
                format: String(localized: "Vorschlag laut Rotationsplan: %@"),
                suggested.localizedLabel
            ))
            .font(.hlSubhead)
            .foregroundStyle(HLText.primary)
            // 1.0.3 (App Review 1.4.1) — the rotation hygiene claim is Frid et
            // al. 2016 (FITTER injection technique).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                    text
                    Spacer(minLength: HLSpace.sm)
                    HLSourcesLink(topic: .injectionRotation)
                }
                VStack(alignment: .leading, spacing: 0) {
                    text
                    HLSourcesLink(topic: .injectionRotation)
                }
            }
        }
    }

    private var bodyMapCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                rotationLine
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

    /// The logged sites, when there are any. 1.4 B2: no card saying there are
    /// none; the body map above is where the first one is logged.
    @ViewBuilder
    private var historyCard: some View {
        if !store.mergedHistory.isEmpty {
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
            // 1.4 B2 — a synced row simply has no delete menu; it no longer
            // wears a "Server" mark (no technical words in user copy).
            if record.source == .local {
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
