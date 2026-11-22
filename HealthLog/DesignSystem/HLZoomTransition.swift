import SwiftUI

/// A sheet that grows out of the button that opened it.
///
/// The button marks itself as the source (`hlZoomSource`), the sheet's
/// content takes the zoom from it (`hlZoomTransition`), both with the same
/// id in the same namespace. The way from cause to effect stays visible, the
/// way Liquid Glass morphs its controls. With Reduce Motion the sheet keeps
/// the system's own presentation.
public extension View {
    /// Marks this control as the place a sheet zooms out of.
    func hlZoomSource(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        matchedTransitionSource(id: id, in: namespace)
    }

    /// Lets the content of a sheet zoom out of the control marked with the
    /// same `id` (``hlZoomSource(_:in:)``).
    func hlZoomTransition(from id: some Hashable, in namespace: Namespace.ID) -> some View {
        modifier(HLZoomTransitionModifier(id: AnyHashable(id), namespace: namespace))
    }
}

private struct HLZoomTransitionModifier: ViewModifier {
    let id: AnyHashable
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if HLZoomTransitionRule.zooms(reduceMotion: reduceMotion) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// When a sheet zooms out of its button. Pure, so the rule is tested.
public enum HLZoomTransitionRule {
    public nonisolated static func zooms(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}

public extension EnvironmentValues {
    /// The namespace a page's bar actions mark themselves in as zoom
    /// sources, each under its role (``HLTabHeaderAction/Role``). The page
    /// zooms its coach sheet out of the coach button with
    /// `.hlZoomTransition(from: HLTabHeaderAction.Role.coach, in: ns)`.
    @Entry var hlActionZoomNamespace: Namespace.ID?
}

/// Marks a page action as the zoom source of its role when the page gave a
/// namespace.
struct HLActionZoomSource: ViewModifier {
    let role: AnyHashable
    @Environment(\.hlActionZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.hlZoomSource(role, in: namespace)
        } else {
            content
        }
    }
}
