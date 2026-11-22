import SwiftUI

/// **"What the assistant knows" (server B4).**
///
/// Lists the coach facts the assistant has extracted about the user, grouped by
/// category, with swipe-to-forget per fact and a "Forget all" affordance. Facts
/// are server-extracted, so this is a read + delete surface — there is no add /
/// edit path.
///
/// **Server-only surface.** Coach memory lives on the server. When the operator
/// disabled the Coach surface, the store flips `isCoachDisabled` (from the typed
/// `HLError.aiUnavailable`) and we render the disabled-surface placeholder —
/// the same kill-switch the rest of the Coach stack honours.
///
/// Entry point: `Settings → Coach → What the assistant knows`.
struct CoachMemoryScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: CoachFactsStore?

    var body: some View {
        connectedBody
            .navigationTitle("What the assistant knows")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard store == nil, let api = container?.api else { return }
                let s = CoachFactsStore(repo: CoachFactsRepository(api: api))
                store = s
                await s.load()
            }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if store?.isCoachDisabled == true {
            // Coach kill-switch — calm placeholder in a stable `List` root.
            List {
                CoachUnavailableCard()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .hlPageMargins()
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
        // A failed load with nothing learned is an ERROR, not the calm
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
                // The first sentence repeated the title.
                message: "coachMemory.empty.message"
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .hlFormRowSurface()
    }

    @ViewBuilder
    private func factRows(store: CoachFactsStore) -> some View {
        // No lead line: the title says what this is, the rows
        // swipe like every list, and "Forget everything" closes the list.
        ForEach(store.groupedByCategory, id: \.category) { group in
            Section {
                ForEach(group.facts) { fact in
                    factRow(fact)
                        .hlSwipeDelete(.confirmed(title: "settings.coachMemory.forget.confirm.title") {
                            await store.forget(fact)
                        })
                }
            } header: {
                HLSectionHeader(verbatim: Self.categoryTitle(group.category))
            }
            .hlFormRowSurface()
        }

        Section {
            HLDeleteButton(
                "Forget everything",
                form: .row,
                action: .confirmed(
                    title: "Forget everything?",
                    message: "The assistant will forget everything it has learned about you. This cannot be undone."
                ) {
                    await store.forgetAll()
                }
            )
            .accessibilityIdentifier("coachMemory.forgetAll")
        }
        .hlFormRowSurface()
    }

    private func factRow(_ fact: CoachFactDTO) -> some View {
        // A remembered fact is a sentence: it wraps in the row title's type
        // instead of ending in "…".
        HLRowTitle(Text(verbatim: fact.text))
            .frame(maxWidth: .infinity, minHeight: HLRowMetrics.minHeight, alignment: .leading)
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
