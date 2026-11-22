import Foundation

/// The More-stack screens a link opens. Split out of
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
            openSidebarDestination(.checkups)
        case let .checkupsVisit(id):
            // VISIT — `/checkups?visit=<id>`: Vorsorge, whose "Nächster
            // Termin" shows that visit while it is booked.
            focusVisit(id)
            openSidebarDestination(.checkups)
        case .cycle:
            openSidebarDestination(.cycle)
        case .timeline:
            timeline.noteOpened()
            openSidebarDestination(.timeline)
        case .seizures:
            openSidebarDestination(.seizures)
        case let .seizureEvent(id):
            openSidebarDestination(.seizures)
            appendToSeizures(SeizureEventRoute(id: id))
        default:
            break
        }
    }

    /// Pushes `value` onto the stack the diary just opened on: its own
    /// sidebar tab, or More behind the diary's row.
    private func appendToSeizures(_ value: some Hashable) {
        if shellLayout.visibleSections.contains(.seizures) {
            var path = sectionPath(.seizures)
            path.append(value)
            sectionPaths[.seizures] = path
        } else {
            morePath.append(value)
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
}
