import SwiftUI

/// **LIFE (1.5.0)** — the door to "Life circumstances" under "About me".
///
/// Shown only when the last `/api/auth/me` said the server has the routes
/// (`features.lifeCircumstances`, v1.43). An older server, a standalone
/// install or a `/me` that has not loaded yet shows no row at all. The push
/// is a value on the More stack (`MoreRoute`), so the page survives the
/// privacy shield like every other page there (SET-ROUTE).
struct LifeCircumstancesEntryRow: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if Self.isOffered(container?.moduleGate.serverFeatures) {
            HLSettingsActionRow(
                icon: "figure.walk.motion",
                title: "life.title",
                subtitle: "life.aboutMe.subtitle",
                presents: .push,
                value: MoreRoute.lifeCircumstances
            )
            .accessibilityIdentifier("aboutMe.row.lifeCircumstances")
        }
    }

    /// Absent features, or the flag absent or `false`: no row.
    static func isOffered(_ features: ServerFeatures?) -> Bool {
        features?.lifeCircumstances == true
    }
}

/// The two pages of the "About me" branch on the More stack. One switch case
/// in `MoreScreen.moreDestination(_:)` for both keeps that switch inside its
/// complexity budget.
struct AboutMeRouteDestination: View {
    let route: MoreRoute

    var body: some View {
        if route == .lifeCircumstances {
            LifeCircumstancesScreen()
        } else {
            AboutMeScreen()
        }
    }
}
