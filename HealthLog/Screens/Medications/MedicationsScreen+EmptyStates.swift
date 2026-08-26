import SwiftUI

// Splitting note (A360-4 / file_length-Disziplin): the empty-state,
// deep-link-placeholder and first-paint-skeleton subviews of
// `MedicationsScreen` live here so the screen file stays under the 600-line
// budget. Pure code movement — no behaviour change. These types are
// module-internal (used only by `MedicationsScreen`).

// MARK: - Empty state

/// v0.7.0 — migrated to `ContentUnavailableView` (iOS 17+) with the
/// `actions:` slot carrying the primary "Medikament hinzufügen" CTA.
///
/// The pre-v0.7.0 implementation wrapped the empty state in an `HLCard`
/// and used the monochrome `BrandMark` as the hero glyph (Y8 H-1: the
/// empty Medications tab is the most-seen empty surface, so it doubled
/// as a brand-anchor surface). The system `ContentUnavailableView`
/// supersedes that bespoke layout — it ships the standard centered
/// vertical rhythm, Dynamic-Type behaviour and a dedicated actions
/// region for the CTA. The `pills` SF Symbol replaces the BrandMark
/// because `ContentUnavailableView`'s glyph slot expects a `Label`
/// system icon, not a custom asset; the brand presence is now carried
/// by the surrounding navigation/tab chrome rather than the empty
/// state itself.
struct EmptyMedicationsState: View {
    let onAdd: () -> Void

    var body: some View {
        HLEmptyState(
            icon: "pills",
            title: "No medications yet",
            message: "Add your first medication. Reminders, compliance heatmap and history follow automatically."
        ) {
            HLButton(
                String(localized: "Add medication"),
                icon: "plus",
                variant: .restrained,
                action: onAdd
            )
        }
        .accessibilityIdentifier("medications.empty")
    }
}

// MARK: - Deep-link placeholder

/// QoS-1 (A360-4) — the cold `healthlog://medications/<id>` placeholder shown
/// while the catalog hydrates before the requested medication can be resolved.
///
/// The pre-fix version was a bare `ProgressView` whose `.task` called
/// `store.load()` with **no error capture**, so an offline cold-start or a 5xx
/// left the user staring at an infinite spinner with no signal anything went
/// wrong. This view owns the load and renders three honest terminal states:
///
/// - **loading** — the calm spinner while the first load is in flight,
/// - **error** — the canonical `ErrorBanner` over the spinner with an "Erneut
///   versuchen" retry that re-drives `store.load(force:)`,
/// - **not found** — once the load settles (`!isLoading`, `error == nil`) but
///   the requested id is absent (a stale reminder for an archived/deleted med),
///   a calm `ContentUnavailableView` instead of a spinner that never resolves.
struct MedicationDeepLinkPlaceholder: View {
    let store: MedicationsStore
    let requestedID: String

    /// The load has settled with no error, the catalog is non-empty, and the
    /// requested medication still isn't present → terminal "not found".
    private var isNotFound: Bool {
        Self.isNotFound(
            isLoading: store.isLoading,
            hasError: store.error != nil,
            isCatalogEmpty: store.medications.isEmpty,
            isResolvable: store.medications.contains { $0.id == requestedID }
        )
    }

    /// Pure decision (A360-4 QoS-1): the placeholder shows the terminal
    /// "not found" state only once the load has settled (`!isLoading`), no error
    /// is up (an error owns the screen instead), the catalog actually loaded
    /// (non-empty), and the requested id is still absent. Extracted so the
    /// precedence is unit-testable without hosting the view. `nonisolated` —
    /// pure decision, no view state, so it needn't hop to the main actor.
    nonisolated static func isNotFound(
        isLoading: Bool,
        hasError: Bool,
        isCatalogEmpty: Bool,
        isResolvable: Bool
    ) -> Bool {
        !isLoading && !hasError && !isCatalogEmpty && !isResolvable
    }

    var body: some View {
        Group {
            if isNotFound {
                HLEmptyState(
                    icon: "pills.circle",
                    title: "Medication not found",
                    message: "This medication is no longer available. It may have been archived or deleted."
                )
                .accessibilityIdentifier("medications.deeplink.notFound")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hlScreenBackground()
        .hlErrorBannerOverlay(error: store.error) {
            Task { await store.load(force: true) }
        }
        .task { if store.medications.isEmpty { await store.load() } }
    }
}

// MARK: - First-paint skeleton (W-IMPL-SKELETON)

/// First-paint silhouette painted while the Medications tab cold-starts.
/// **v0.5.5.1 (W-IMPL-SKELETON):** rebuilt on top of `HLSkeleton` so the
/// shimmer + reduce-motion contract lives at the token layer — the prior
/// `RoundedRectangle.fill(HLColor.surface)` + `.opacity(0.55)` block had
/// to manually paint each rectangle and skipped the reduce-motion gate
/// entirely. Section headers, Today-timeline rows, the 4-week compliance
/// grid and the active-medication rows all keep their original silhouette,
/// only the underlying primitive moved.
///
/// Gate preserved (`isShowingInitialSkeleton` = `isLoading && medications.isEmpty
/// && todayIntakes.isEmpty`) — synthesised today rows only fire when
/// `medications` is non-empty so the skeleton-vs-content branch is
/// unaffected by W-MED2.
struct MedicationsSkeletonContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            // Compliance placeholder — section header + the 7×4 grid the
            // live `ComplianceHeatmapSection` paints. Aspect-ratio'd
            // square `.rect` skeletons reproduce the heatmap rhythm.
            //
            // v0.6.1.2 Y4 (D-018): the legacy "Today" placeholder row above
            // dropped together with `TodayTimelineSection` — the Medikamente
            // tab no longer carries a per-day dose-list; take-action lives
            // on the detail screen now.
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLSkeleton(.capsule, width: 180, height: 18)
                HLCard {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: HLSpace.xs), count: 7),
                        spacing: HLSpace.xs
                    ) {
                        ForEach(0 ..< 28, id: \.self) { _ in
                            HLSkeleton(.rect, height: 28, cornerRadius: 4)
                        }
                    }
                }
            }

            // Active meds placeholder — section header + three card-row
            // silhouettes (circle icon + name/dose capsule pair).
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLSkeleton(.capsule, width: 160, height: 18)
                HLCard {
                    VStack(spacing: 0) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            HStack(spacing: HLSpace.md) {
                                HLSkeleton(.circle, width: 28, height: 28)
                                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                                    HLSkeleton(.capsule, width: 140, height: 14)
                                    HLSkeleton(.capsule, width: 80, height: 12)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, HLSpace.sm)
                        }
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading medications"))
    }
}
