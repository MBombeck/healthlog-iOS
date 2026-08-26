import SwiftUI

/// **v0.5.4-NF-1 → v0.5.4.1.** Dashboard profile-avatar binding glue.
///
/// v0.5.4 lived as a `topBarTrailing` toolbar item that hosted both the
/// `HLProfileAvatar` and the `navigationDestination(isPresented:)` push.
/// On the v0.5.4 walkthrough the operator wanted the avatar **inline**
/// with the "Hi, <name>" greeting row instead of floating in the navigation
/// chrome — the inline placement reads as "this represents me" rather
/// than "this is a toolbar control."
///
/// v0.5.4.1 keeps the destination push here so the Dashboard body stays
/// declarative; the avatar itself is now hosted inside `Header(...)` and
/// flips the shared `isPresented` binding. The legacy
/// `dashboardProfileToolbar(isPresented:)` overload is preserved as a
/// thin wrapper so source-compat survives but it now ONLY wires the
/// destination (no toolbar item is emitted, removing the duplicate-
/// avatar artefact the operator screenshot caught).
extension View {
    /// **v0.5.4.1.** Attach the profile-editor presentation to the host
    /// `NavigationStack`. The caller's view layer renders the avatar wherever
    /// it likes (inline header, list row, etc.); this modifier just owns the
    /// typed-binding-driven presentation. SET-6: presents `EditProfileSheet`
    /// as a sheet (modal edit transaction) rather than a navigation push.
    func dashboardProfileDestination(isPresented: Binding<Bool>) -> some View {
        modifier(DashboardProfileDestinationModifier(isPresented: isPresented))
    }

    /// **Legacy / source-compat.** v0.5.4 NF-1 call sites still reference
    /// `dashboardProfileToolbar(isPresented:)` — this overload re-routes
    /// them to the presentation modifier. NO toolbar item is emitted here;
    /// the v0.5.4.1 inline avatar in `Header(...)` is the canonical
    /// affordance now.
    func dashboardProfileToolbar(isPresented: Binding<Bool>) -> some View {
        dashboardProfileDestination(isPresented: isPresented)
    }
}

private struct DashboardProfileDestinationModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            // v0.11 IA — the Home avatar deep-links straight to the profile
            // EDITOR (`EditProfileScreen`). The operator reads the top-right
            // avatar as "this is me — tap to edit my profile", so the
            // intermediate Settings→Account hub (which only forwarded to the
            // same editor via a card row) is one hop too many. The editor takes
            // no parameters — it resolves `SettingsStore` + `AvatarStore` from
            // the environment, both already in scope at the Dashboard
            // NavigationStack. Sign-out and delete-account moved onto
            // `SettingsAccountScreen`, so the avatar shortcut no longer needs
            // to surface them.
            //
            // SET-6 (AUDIT-QOL-UX §5) — present as a sheet (modal edit
            // transaction) via `EditProfileSheet`, matching every other edit
            // surface; was a `navigationDestination` push.
            .sheet(isPresented: $isPresented) {
                EditProfileSheet()
            }
    }
}
