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
    /// **v0.5.4.1 → 25-02.** Attach the avatar's account presentation to the
    /// host `NavigationStack`. The caller's view layer renders the avatar
    /// wherever it likes (inline header, list row, etc.); this modifier just
    /// owns the typed-binding-driven presentation. 25-02 (E-2026-08-29 #4):
    /// the sheet presents Konto (`SettingsAccountScreen`); the profile editor
    /// stays one hop inside it, as under Einstellungen.
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
            // 25-02 (E-2026-08-29 #4) — the avatar opens KONTO, the account
            // area exactly as it appears under Einstellungen → Konto. v0.11 IA
            // had deep-linked the avatar straight to the profile editor; the
            // operator retargeted it: the avatar stands for the account, and
            // the editor stays reachable inside Konto (its Profil card, the
            // same one hop it is under Einstellungen). The presentation stays
            // this ONE sheet — never a push — so the Phase-06 census does not
            // move; only the sheet's content changed.
            .sheet(isPresented: $isPresented) {
                DashboardAccountSheet()
            }
    }
}

/// **25-02 (E-2026-08-29 #4) — the avatar sheet's content: Konto.**
///
/// `SettingsAccountScreen` in its own `NavigationStack`, so the account cards
/// can push (Security, Sessions) and present (Edit Profile, Reset, Delete)
/// exactly as they do under Einstellungen → Konto — one surface, two doors.
/// Same `.form` sheet height the profile editor used, and the same leading
/// Done idiom as `EditProfileSheet`, so the retarget changes the destination,
/// not the presentation grammar.
private struct DashboardAccountSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsAccountScreen()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Done")) { dismiss() }
                            .accessibilityIdentifier("dashboard.accountSheet.done")
                    }
                }
        }
        .hlSheetPresentation(.form)
    }
}
