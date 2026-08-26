import SwiftUI

/// **v0.14.2 (FW5-C) — "What the assistant knows" (server B4).**
///
/// Lists the coach facts the assistant has extracted about the user, grouped by
/// category, with swipe-to-forget per fact and a "Forget all" affordance. Facts
/// are server-extracted, so this is a read + delete surface — there is no add /
/// edit path.
///
/// **Server-only surface.** Coach memory lives on the server, so the screen gates
/// on `BackendAvailability.hasServer` (standalone → the calm
/// `HLCloudDerivedPlaceholder`, never a dead list). When paired but the operator
/// disabled the Coach surface, the store flips `isCoachDisabled` (from the typed
/// `HLError.assistantDisabled`) and we render the disabled-surface placeholder —
/// the same kill-switch the rest of the Coach stack honours.
///
/// Entry point: `Settings → Coach → What the assistant knows`.
struct CoachMemoryScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container

    @State private var store: CoachFactsStore?
    @State private var showForgetAllConfirmation = false

    var body: some View {
        Group {
            if backend.hasServer {
                connectedBody
            } else {
                List {
                    HLCloudDerivedPlaceholder(
                        variant: .inline,
                        surfaceName: String(localized: "what the assistant knows"),
                        onConnect: { authStore.beginServerPairing() }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("What the assistant knows")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard backend.hasServer, store == nil, let api = container?.api else { return }
            let s = CoachFactsStore(repo: CoachFactsRepository(api: api))
            store = s
            await s.load()
        }
        // R13 — die Bestätigungsleiter: ein Massenlöschen innerhalb einer
        // Sammlung ist ein `confirmationDialog`, kein `.alert` (der bleibt dem
        // Ein-Feld-Umbenennen vorbehalten).
        .hlConfirmDestructive(
            Text("Forget everything?"),
            isPresented: $showForgetAllConfirmation,
            message: Text("The assistant will forget everything it has learned about you. This cannot be undone."),
            confirm: Text("Forget everything"),
            cancel: Text("Cancel"),
            onCancel: { showForgetAllConfirmation = false },
            action: {
                Task { await store?.forgetAll() }
            }
        )
    }

    @ViewBuilder
    private var connectedBody: some View {
        if store?.isCoachDisabled == true {
            // Coach kill-switch — calm placeholder in a stable `List` root.
            List {
                HLCloudDerivedPlaceholder(
                    variant: .inline,
                    surfaceName: String(localized: "the coach")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        } else {
            // v0151 nav-scroll RCA-2: STABLE SCROLL ROOT. The connected path used
            // to swap `ProgressView → List` after load. `HLAsyncListScreen` renders
            // the `List` root from frame 1 (skeleton / empty / loaded are rows
            // INSIDE it). See `.planning/v0151-audit/RCA-nav-scroll-2.md`.
            HLAsyncListScreen(
                phase: phase,
                listStyle: .insetGrouped,
                loading: { HLAsyncListSkeletonRows() },
                empty: { emptyRows },
                content: { if let store { factRows(store: store) } }
            )
        }
    }

    /// Maps store state to the stable-root render phase. `nil` store and the first
    /// in-flight load render the skeleton; no facts (settled) → empty; otherwise the
    /// real list. `isCoachDisabled` is handled in `connectedBody`.
    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        if store.isLoading, !store.didLoad { return .loading }
        // AUD-5 H1 — a failed load with nothing learned is an ERROR, not the calm
        // "Nothing learned yet" empty state. Offer Retry so a 500 / cold-offline
        // fetch is not silently presented as "the assistant knows nothing".
        if store.isEmpty, store.error != nil {
            return .error(retry: { await store.load() })
        }
        if store.isEmpty { return .empty }
        return .loaded
    }

    /// Calm empty state — the assistant hasn't learned anything yet. Rendered
    /// INSIDE the stable `List` root.
    private var emptyRows: some View {
        Section {
            HLEmptyState(
                icon: "brain.head.profile",
                title: "Nothing learned yet",
                message: "The assistant hasn't learned anything about you yet. As you chat, facts it picks up will show here — and you can forget any of them."
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func factRows(store: CoachFactsStore) -> some View {
        Section {
            Text("These are facts the assistant has picked up about you. Swipe to forget any of them.")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .listRowSeparator(.hidden)
        }

        ForEach(store.groupedByCategory, id: \.category) { group in
            Section(Self.categoryTitle(group.category)) {
                ForEach(group.facts) { fact in
                    factRow(fact)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await store.forget(fact) }
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                }
            }
        }

        Section {
            Button(role: .destructive) {
                showForgetAllConfirmation = true
            } label: {
                Label("Forget everything", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("coachMemory.forgetAll")
        }
    }

    private func factRow(_ fact: CoachFactDTO) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(fact.text)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
        }
        .accessibilityIdentifier("coachMemory.fact.\(fact.id)")
    }

    /// Maps a raw server category key to a display title. Unknown categories fall
    /// back to a capitalised form of the key so a new server category never shows
    /// a blank header.
    static func categoryTitle(_ raw: String) -> String {
        switch raw.lowercased() {
        case "": String(localized: "General")
        case "preference", "preferences": String(localized: "Preferences")
        case "health": String(localized: "Health")
        case "medication", "medications": String(localized: "Medications")
        case "routine", "routines": String(localized: "Routines")
        case "goal", "goals": String(localized: "Goals")
        case "lifestyle": String(localized: "Lifestyle")
        default: raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

#Preview("CoachMemoryScreen") {
    NavigationStack {
        CoachMemoryScreen()
    }
}
