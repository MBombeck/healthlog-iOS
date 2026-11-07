import Foundation

/// #141 / #126 3.2 — the More-stack screens a link opens. Split out of
/// `AppRouter.swift` (file length and the `applyImmediate` complexity budget):
/// `healthlog://settings/notifications` and the four screens only a push `url`
/// names (``DeepLinkRoute/fromPushPath(_:)``) all land on the More tab with the
/// real back stack behind them.
extension AppRouter {
    func applyMoreStackRoute(_ route: DeepLinkRoute) {
        switch route {
        case .settingsNotifications:
            openSettings(.notifications)
        case .settingsSecurity:
            openSettings(.security)
        case .settingsIntegrations:
            requestSettingsIntegrations()
        case .checkups:
            focusedVisitId = nil
            openMoreDestination(.checkups)
        case let .checkupsVisit(id):
            // VISIT — `/checkups?visit=<id>`: Vorsorge, whose "Nächster
            // Termin" shows that visit while it is booked.
            focusVisit(id)
            openMoreDestination(.checkups)
        case .cycle:
            openMoreDestination(.cycle)
        default:
            break
        }
    }

    /// VISIT — name the visit "Nächster Termin" on Vorsorge shows next
    /// (``NextVisitSection``); it falls back to the soonest when that visit is
    /// no longer booked.
    func focusVisit(_ id: String?) {
        focusedVisitId = id
    }

    /// Mehr, Einstellungen, then `leaf`.
    private func openSettings(_ leaf: SettingsRoute) {
        selectedTab = .more
        morePath = .init()
        morePath.append(SettingsRoute.root)
        morePath.append(leaf)
    }

    /// Mehr, then the clinical-spine screen the More list itself links to.
    private func openMoreDestination(_ destination: SettingsRoute) {
        selectedTab = .more
        morePath = .init()
        morePath.append(destination)
    }
}
