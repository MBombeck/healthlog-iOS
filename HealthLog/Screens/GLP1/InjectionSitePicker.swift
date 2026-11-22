import SwiftUI

/// Renders the injection-site section: the body map with the rotation
/// suggestion as its first line, the last injection and its site, and the
/// recent history.
///
/// **#169 — a site belongs to a dose.** Picking a spot on the map no longer
/// logs a site of its own; it sets the site of the last recorded injection
/// (`PUT …/intake/{eventId}`). Sites an older build kept only on the device
/// are offered for their dose and go up once the person confirms. A site the
/// medication does not allow gets one plain sentence and is not retried.
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
        // The page's gap, so the header keeps its own room.
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            HLSectionHeader("Injektionsstelle", rank: .area)
            bodyMapCard
            offersCard
            historyCard
        }
        // Each row's delete asks first; the question hangs here, not on the menu.
        .hlDeleteConfirmation()
    }

    // MARK: - Sections

    /// A device-only site is gone for good once deleted, so it asks first.
    private func deleteAction(id: String) -> HLDeleteAction {
        .confirmed(title: "Delete entry?", message: "The history entry will be removed. This action cannot be undone.") {
            await store.delete(id: id)
        }
    }

    /// The rotation suggestion is the body map's own first line, with
    /// its citation beside it, instead of a ghost card above the map. Nothing
    /// renders there before the first site is known.
    @ViewBuilder
    private var rotationLine: some View {
        if let suggested = store.suggestedNextSite {
            let text = Text(String(
                format: String(localized: "Vorschlag laut Rotationsplan: %@"),
                suggested.localizedLabel
            ))
            .hlText(.prose)
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

    /// The last dose and its site, or what to do before there is one.
    @ViewBuilder
    private var lastInjectionLine: some View {
        if let intake = store.lastInjection, let takenAt = intake.takenAt {
            let when = "\(HLDateFormat.dayMonth(takenAt)), \(HLTimeFormat.time(takenAt))"
            let line = store.lastInjectionSite.map { site in
                String(
                    format: String(
                        localized: "glp1.site.lastInjection.withSite",
                        defaultValue: "Last injection %1$@: %2$@"
                    ),
                    when,
                    site.localizedLabel
                )
            } ?? String(
                format: String(
                    localized: "glp1.site.lastInjection.noSite",
                    defaultValue: "Last injection %@: no site yet"
                ),
                when
            )
            Text(verbatim: line)
                .hlText(.footnote)
        } else {
            Text(String(
                localized: "glp1.site.noDose",
                defaultValue: "Once a dose is recorded, you can set its site here."
            ))
            .hlText(.footnote)
        }
    }

    private var bodyMapCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                rotationLine
                lastInjectionLine
                InjectionBodyMap(
                    lastUsed: store.lastUsedSite,
                    suggested: store.suggestedNextSite,
                    selected: stagedSite
                ) { site in
                    // Without a dose to put it on, the map only shows.
                    guard store.canSetSite else { return }
                    stagedSite = stagedSite == site ? nil : site
                }
                if let notice = store.notice {
                    HLFormErrorText(notice)
                }
                actions
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let staged = stagedSite {
            Text(String(
                format: String(localized: "Selected: %@"),
                staged.localizedLabel
            ))
            .hlText(.prose)
            HLButtonPair {
                HLButton(
                    LocalizedStringKey("glp1.site.setOnLastInjection"),
                    isLoading: store.isSaving
                ) {
                    Task {
                        // A refused or failed write keeps the selection, so
                        // the person sees what was not saved.
                        if await store.setSiteOnLastInjection(staged) { stagedSite = nil }
                    }
                }
                .accessibilityIdentifier("glp1.site.setOnLastInjection")
            } secondary: {
                HLButton("Reset", variant: .secondary) {
                    stagedSite = nil
                }
            }
        } else if store.canSetSite, store.lastInjectionSite != nil {
            HLButton(LocalizedStringKey("glp1.site.clearOnLastInjection"), variant: .secondary) {
                Task { await store.setSiteOnLastInjection(nil) }
            }
            .accessibilityIdentifier("glp1.site.clearOnLastInjection")
        }
    }

    /// Sites an older build kept only on this device, each offered for the
    /// dose it fits. A tap puts it on that dose.
    @ViewBuilder
    private var offersCard: some View {
        let offers = store.offers
        if !offers.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLCard(layout: .rows) {
                    ForEach(offers) { offer in
                        OfferRow(offer: offer) {
                            Task { await store.apply(offer) }
                        }
                    }
                }
                Text(String(
                    localized: "glp1.site.offers.footer",
                    defaultValue: "These sites were saved only on this device. Tap one to add it to its dose."
                ))
                .hlText(.footnote)
            }
        }
    }

    /// The known sites, when there are any. No card saying there are none.
    @ViewBuilder
    private var historyCard: some View {
        if !store.mergedHistory.isEmpty {
            HLCard(layout: .rows) {
                ForEach(store.mergedHistory, id: \.id) { record in
                    HistoryRow(record: record, delete: deleteAction(id: record.id))
                }
            }
        }
    }
}

// MARK: - Rows

/// One device-only site and the dose it fits.
private struct OfferRow: View {
    let offer: InjectionSiteOfferMatcher.Offer
    let apply: () -> Void

    var body: some View {
        let when = "\(HLDateFormat.dayMonth(offer.takenAt)), \(HLTimeFormat.time(offer.takenAt))"
        HLRowButton(action: apply) {
            HLRow(
                title: Text(verbatim: offer.site.localizedLabel),
                detail: Text(verbatim: String(
                    format: String(
                        localized: "glp1.site.offer.detail",
                        defaultValue: "For the dose on %@"
                    ),
                    when
                )),
                accessory: .symbol("plus.circle")
            )
        }
        .accessibilityHint(Text(String(
            localized: "glp1.site.offer.hint",
            defaultValue: "Adds this site to the dose"
        )))
    }
}

private struct HistoryRow: View {
    let record: InjectionSiteRecord
    let delete: HLDeleteAction

    var body: some View {
        HLRow(
            title: Text(verbatim: record.site.localizedLabel),
            detail: Text(verbatim: "\(HLDateFormat.dayMonth(record.when)), \(HLTimeFormat.time(record.when))")
        )
        // A dose's site has no actions here; it no longer wears a "Server"
        // mark (no technical words in user copy).
        .glp1RowActions(delete: record.source == .local ? delete : nil)
    }
}
