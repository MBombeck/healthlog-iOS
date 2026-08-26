import SwiftUI

/// **Settings → Health Score (v1.35.0 / GH #83) — which pillars count.**
///
/// The score used to be composed the same way for everybody. Since server
/// v1.35.0 a person decides what goes into it, and this is where that decision
/// is made: one row per pillar, one save, `PATCH /api/auth/me/health-score-config`.
///
/// Three things this screen is careful about.
///
/// **It does not predict the refusal.** The server accepts a selection only if
/// it spans at least three distinct fields of health, one of them physically
/// measured — and which pillar speaks to which field is server knowledge that
/// rides no wire (the resolved config carries ids only; the score report's
/// per-pillar `domain` covers only the pillars that currently *count*, so a
/// deselected pillar's field is unknowable here). A client-side preview would
/// therefore have to hardcode the mapping and would drift apart from the server
/// at its next release, silently, in the direction of telling a person their
/// selection is fine when it is not. The card footer states the rule as the
/// server states it; the arithmetic stays on the server.
///
/// **A refusal is an explanation, not a failure.** A `422` comes back with the
/// reason the selection was too narrow, and the screen renders a sentence
/// saying what that limit is *for*. It does not paint a red error, and it does
/// not throw the person's selection away — the ticks stay as they were so the
/// next attempt starts from what they meant.
///
/// **The first save is unconditional.** An account that never chose has no
/// concurrency token; ``HealthScoreConfigRepository`` omits the key entirely
/// rather than sending `null`, which the server would reject.
struct SettingsHealthScoreScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container
    /// Optional on purpose: this screen must not trap if it is ever reached on
    /// a path that never injected them. They exist only to invalidate a stale
    /// number after a save — the change is to what the score *means*, and
    /// walking back to a cached old value would read as "it didn't take".
    @Environment(HealthScoreStore.self) private var scoreStore: HealthScoreStore?
    @Environment(DailyDigestStore.self) private var digestStore: DailyDigestStore?

    @State private var store: HealthScoreConfigStore?

    var body: some View {
        HLSettingsPage(title: "Health Score") {
            if backend.hasServer {
                connectedBody
            } else {
                HLCloudDerivedPlaceholder(
                    variant: .inline,
                    surfaceName: String(localized: "Health Score"),
                    onConnect: { authStore.beginServerPairing() }
                )
            }
        }
        .navigationTitle("Health Score")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard backend.hasServer, store == nil, let api = container?.api else { return }
            let created = HealthScoreConfigStore(repo: HealthScoreConfigRepository(api: api))
            store = created
            await created.load()
        }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if let store {
            if store.config != nil {
                pillarsCard(store: store)
                saveSection(store: store)
            } else if store.loadFailed {
                loadFailedState(store: store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HLSpace.xxl)
            }
        }
    }

    private func loadFailedState(store: HealthScoreConfigStore) -> some View {
        HLEmptyState(
            icon: "wifi.exclamationmark",
            title: "Couldn't load which pillars count."
        ) {
            HLButton("Try again", icon: "arrow.clockwise", variant: .secondary) {
                Task { await store.load() }
            }
        }
        .containerCentered()
    }

    /// One row per pillar. No per-row description on purpose (R1/R2): the
    /// pillar names say what they are, and a paragraph under each switch would
    /// be eight restatements of a title.
    private func pillarsCard(store: HealthScoreConfigStore) -> some View {
        HLSettingsCard(
            icon: "slider.horizontal.3",
            title: "Pillars that count",
            // R2 (Grenze/Limit) — the hard bound the server enforces, stated
            // once, before the decision. Deliberately does not name which
            // pillars share an area: that mapping lives on the server and a
            // copy of it here would go stale without anyone noticing.
            footer: "At least three different areas of health have to remain, one of them physically measured. Several pillars can describe the same area and then count together as one."
        ) {
            ForEach(store.offeredPillars, id: \.rawValue) { pillar in
                HLSettingsToggleRow(
                    title: LocalizedStringKey(HealthScorePresentation.labelKey(for: pillar)),
                    description: nil,
                    isOn: Binding(
                        get: { store.isOn(pillar) },
                        set: { store.toggle(pillar, isOn: $0) }
                    ),
                    isEnabled: !store.isSaving,
                    accessibilityID: "settings.healthScore.pillar.\(pillar.rawValue)"
                )
            }
        }
    }

    private func saveSection(store: HealthScoreConfigStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLButton(
                "Save",
                variant: .primary,
                isLoading: store.isSaving,
                action: { Task { await save(store: store) } }
            )
            .disabled(store.isSaving || !store.hasChanges)
            .accessibilityIdentifier("settings.healthScore.save")

            // R2 (Folge) at the control that causes it: saving a different
            // selection changes what the number MEANS, which is invisible in
            // the number itself — the score keeps looking like a score. Shown
            // only while there is a pending change, so it describes something
            // that is actually about to happen rather than sitting as standing
            // prose. This is the reachable home of the sentence; the identical
            // one on the score's own detail card resolves from the same
            // definition site, so the two can never drift.
            if store.hasChanges, case .idle = store.outcome {
                Text(HealthScorePresentation.chosenCompositionExplanation)
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.healthScore.comparability")
            }

            outcomeLine(store: store)
        }
    }

    /// Save, then — only on success — pull the score surfaces fresh. The
    /// server evicted its own score caches on the write; the client's SWR cells
    /// still hold the number the old recipe produced, and letting the person
    /// walk back to Home and see it unchanged would read as "it didn't take".
    private func save(store: HealthScoreConfigStore) async {
        await store.save()
        guard store.outcome == .saved else { return }
        await scoreStore?.refresh()
        await digestStore?.refresh()
    }

    /// What the last attempt produced. The refused arm is deliberately not
    /// painted in the error colour — the server did not fail, it explained a
    /// limit, and colouring that red would tell the person something broke.
    @ViewBuilder
    private func outcomeLine(store: HealthScoreConfigStore) -> some View {
        switch store.outcome {
        case .idle:
            EmptyView()
        case .saved:
            Label(String(localized: "Saved"), systemImage: "checkmark.circle.fill")
                .font(.hlFootnote)
                .foregroundStyle(HLColor.statusOK)
                .accessibilityIdentifier("settings.healthScore.saved")
        case let .refused(reason):
            Text(HealthScorePresentation.explanation(for: reason))
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.healthScore.refused")
        case let .failed(message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.hlFootnote)
            .foregroundStyle(HLColor.statusBad)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.healthScore.failed")
        }
    }
}
