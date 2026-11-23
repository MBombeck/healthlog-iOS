import SwiftUI

/// Dashboard profile-avatar binding glue.
///
/// The avatar sits **inline** with the "Hi, <name>" greeting row (it reads
/// as "this represents me", not as a toolbar control) and flips the shared
/// `isPresented` binding; the destination push lives here so the Dashboard
/// body stays declarative.
extension View {
    /// Attach the avatar's account presentation to the
    /// host `NavigationStack`. The caller's view layer renders the avatar
    /// wherever it likes (inline header, list row, etc.); this modifier just
    /// owns the typed-binding-driven presentation. The sheet presents Konto
    /// (`SettingsAccountScreen`); the profile editor
    /// stays one hop inside it, as under Einstellungen.
    func dashboardProfileDestination(isPresented: Binding<Bool>) -> some View {
        modifier(DashboardProfileDestinationModifier(isPresented: isPresented))
    }
}

private struct DashboardProfileDestinationModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            // The avatar opens KONTO, the account
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

/// **The avatar sheet's content: Konto.**
///
/// `SettingsAccountScreen` in its own `NavigationStack`, so the account cards
/// can push (Security, Sessions) and present (Edit Profile, Reset, Delete)
/// exactly as they do under Einstellungen → Konto — one surface, two doors.
/// Same `.form` sheet height the profile editor used, and the sheet frame
/// every sheet has.
private struct DashboardAccountSheet: View {
    var body: some View {
        // Changes on the account take effect where they are made, so the bar
        // only says "Done".
        HLSheetScaffold("Account", action: .done()) {
            SettingsAccountScreen(showsIrreversibleActions: false)
        }
    }
}
