import SwiftUI

/// #186 — "Symptom erfassen" from Today: the symptom page of an illness
/// episode (``SymptomEventSheet``), opened without an episode. It loads the
/// person's active symptoms and the episodes an occurrence may be filed
/// against, then shows the page with nothing linked, as the web's quick
/// entry does. Saving writes `POST /api/symptoms/events` and goes back to
/// Today.
///
/// Pushed on Today's own stack, like the dashboard's other front doors, so
/// it needs no new presenter.
struct SymptomQuickEntryPage: View {
    @Environment(\.appContainer) private var container
    @State private var state: SymptomQuickEntryState = .loading

    var body: some View {
        Group {
            if case let .ready(definitions, episodes) = state {
                SymptomEventSheet(
                    mode: .create(definitions),
                    episode: nil,
                    episodes: episodes,
                    repository: container.map { SymptomEventsRepository(api: $0.api) },
                    onDone: {}
                )
            } else {
                HLPage { status }
                    .navigationTitle(Text("symptoms.add"))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var status: some View {
        if case let .disabled(reason) = state {
            FeatureDisabledCard(variant: .inline, reason: reason)
                .accessibilityIdentifier("symptoms.quick.disabled")
        } else {
            HLStateContainer(state.loadPhase(retry: { await load() })) {
                HLInlineProgress()
                    .frame(maxWidth: .infinity)
            } empty: {
                HLEmptyState(icon: "heart.text.square", title: "symptoms.quick.none.title", message: "symptoms.quick.none.message")
                    .accessibilityIdentifier("symptoms.quick.none")
            } content: {
                EmptyView()
            }
        }
    }

    private func load() async {
        guard let container else { return }
        let repository = SymptomEventsRepository(api: container.api)
        do {
            let definitions = try await repository.definitions()
            // The episodes only offer a link; without them the page still logs.
            await container.illnessStore.load()
            state = SymptomQuickEntryState.loaded(
                definitions: definitions,
                episodes: container.illnessStore.episodes
            )
        } catch {
            let offReason = container.moduleGate.offReason(.illness)
            state = SymptomQuickEntryState.after(error, offReason: offReason) ?? state
        }
    }
}

/// What the quick entry shows, pure so it is testable without a view host.
enum SymptomQuickEntryState: Equatable {
    case loading
    case ready(definitions: [SymptomDefinition], episodes: [IllnessEpisodeDTO])
    /// No active symptom to log: they are defined on the web.
    case noSymptoms
    case disabled(String?)
    case failed

    /// Only the active symptoms can be logged.
    nonisolated static func loaded(
        definitions: [SymptomDefinition],
        episodes: [IllnessEpisodeDTO]
    ) -> SymptomQuickEntryState {
        let active = definitions.filter(\.isActive)
        return active.isEmpty ? .noSymptoms : .ready(definitions: active, episodes: episodes)
    }

    /// The episode page's reading of a failed load: a refusal is the
    /// disabled card, anything else can be tried again, a cancel changes
    /// nothing (`nil`).
    nonisolated static func after(_ error: Error, offReason: String?) -> SymptomQuickEntryState? {
        switch EpisodeSymptomsModel.stateAfter(error, offReason: offReason) {
        case nil: nil
        case let .disabled(reason): .disabled(reason)
        default: .failed
        }
    }

    func loadPhase(retry: @escaping () async -> Void) -> HLLoadPhase {
        switch self {
        case .loading: .loading
        case .noSymptoms: .empty
        case .failed: .error(retry: retry)
        case .ready, .disabled: .loaded
        }
    }

    /// Whether Today offers the entry: the illness module is on and the
    /// server files occurrences by their link (``SymptomEventsRepository/minimumServerVersion``).
    nonisolated static func isOffered(illnessEnabled: Bool, serverVersion: String?) -> Bool {
        illnessEnabled && EpisodeSymptomsSection.isAvailable(serverVersion: serverVersion)
    }
}
