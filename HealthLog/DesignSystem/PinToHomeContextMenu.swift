import SwiftUI

/// v0.14 A — "pin to home" long-press affordance shared by the Insights
/// metric tiles and the Dashboard tiles.
///
/// Attaches a `.contextMenu` with a single toggle action:
/// - "Add to Home" when the metric is not on the dashboard tile-strip.
/// - "Remove from Home" when it is.
///
/// The action flips `tileVisible` on the server-backed
/// `DashboardWidgetLayout` via `DashboardLayoutStore.setPinned(forId:pinned:)`
/// (optimistic write-through; the same PUT path the customisation screen uses),
/// fires a light haptic, and surfaces a brief confirmation toast through the
/// app-wide `UndoCoordinator` (tap "Undo" to reverse the pin).
///
/// **Honest gating** — the menu action is only offered when:
/// 1. The metric maps to a real server widget id
///    (`DashboardWidgetId.id(forMetricKind:)` is non-nil). Metrics without an
///    id (the v1.10 additive signals, derived/composite tiles) can't be
///    persisted server-side, so we omit the action entirely rather than show a
///    dead button.
/// 2. The app is NOT in standalone mode. The layout PUT has no offline
///    persistence path today (the layout store always round-trips the server);
///    in standalone we omit the action rather than silently drop the toggle.
struct PinToHomeContextMenu: ViewModifier {
    let kind: MetricKind
    let container: AppContainer?

    func body(content: Content) -> some View {
        if let container,
           let widgetId = DashboardWidgetId.id(forMetricKind: kind),
           container.syncModeStore.isStandalone == false
        {
            content.contextMenu {
                PinToHomeButton(
                    kind: kind,
                    widgetId: widgetId,
                    layoutStore: container.dashboardLayoutStore,
                    undoCoordinator: container.undoCoordinator
                )
            }
        } else {
            content
        }
    }
}

/// The single toggle button inside the context menu. Split out so it can read
/// the live `isPinned` state from the `@Observable` layout store at render time
/// (the menu rebuilds when long-pressed, so the label always reflects truth).
private struct PinToHomeButton: View {
    let kind: MetricKind
    let widgetId: String
    let layoutStore: DashboardLayoutStore
    let undoCoordinator: UndoCoordinator

    var body: some View {
        let pinned = layoutStore.isPinned(forId: widgetId)
        Button {
            pin(!pinned)
        } label: {
            if pinned {
                Label {
                    Text("Remove from Home", comment: "Context-menu action — unpin a metric tile from the home dashboard")
                } icon: {
                    Image(systemName: "rectangle.badge.minus")
                }
            } else {
                Label {
                    Text("Add to Home", comment: "Context-menu action — pin a metric tile to the home dashboard")
                } icon: {
                    Image(systemName: "rectangle.badge.plus")
                }
            }
        }
    }

    private func pin(_ pinned: Bool) {
        let name = String(localized: kind.descriptor.title)
        let message = pinned
            ? String(
                localized: "\(name) added to Home",
                comment: "Toast — metric pinned to home dashboard. %@ = metric name."
            )
            : String(
                localized: "\(name) removed from Home",
                comment: "Toast — metric unpinned from home dashboard. %@ = metric name."
            )
        Task { @MainActor in
            await layoutStore.setPinned(forId: widgetId, pinned: pinned)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let id = widgetId
            undoCoordinator.enqueue(message: message) { [weak layoutStore] in
                await layoutStore?.setPinned(forId: id, pinned: !pinned)
            }
        }
    }
}

extension View {
    /// Attaches the shared "pin to home" long-press menu for a metric tile.
    /// No-op (returns self) for metrics without a server widget id or in
    /// standalone mode — see `PinToHomeContextMenu`.
    func pinToHomeContextMenu(kind: MetricKind, container: AppContainer?) -> some View {
        modifier(PinToHomeContextMenu(kind: kind, container: container))
    }
}
