import SwiftUI

/// **The history card.**
///
/// New readings always go first; the older history follows on its own in the
/// time left over. This card says how far that has got and offers the one
/// explicit step: "Sync everything now", with the honest note that it wants
/// the phone awake and on the charger.
extension AppleHealthIntegrationDetailScreen {
    var historyCard: some View {
        HistoryCatchUpCard(
            store: HealthHistoryCatchUpStore.shared,
            hasSynced: hkReadiness.displayedLastSyncedAt(serverLastSyncedAt: store.hkConfig?.lastSyncedAt) != nil
        )
    }
}

private struct HistoryCatchUpCard: View {
    let store: HealthHistoryCatchUpStore
    /// Before the first sync "0 of 36 complete" reads like a failure; the
    /// card says the count follows the next sync instead.
    let hasSynced: Bool

    var body: some View {
        // No subtitle: "new readings go first, the older history
        // follows on its own" and the four sentences over the button are one
        // short note now, shown only while there is something left to send.
        HLCard("settings.applehealth.history.title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text(statusText)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.applehealth.history.status")

                if store.isRunning, let overview = store.overview, overview.totalCount > 0 {
                    ProgressView(value: Double(overview.finishedCount), total: Double(overview.totalCount))
                }

                if !(store.overview?.isFinished ?? false) || store.isRunning {
                    Text("settings.applehealth.history.note")
                        .hlText(.footnote)
                        .fixedSize(horizontal: false, vertical: true)

                    HLButton(
                        store.isRunning
                            ? "settings.applehealth.history.stop"
                            : "settings.applehealth.history.sync_all",
                        systemImage: store.isRunning ? "stop.circle" : "arrow.down.circle",
                        variant: .secondary
                    ) {
                        if store.isRunning {
                            store.stop()
                        } else {
                            store.start()
                        }
                    }
                    .accessibilityIdentifier("settings.applehealth.history.syncAll")
                }
            }
        }
        .task { await store.refresh() }
    }

    private var statusText: String {
        switch store.phase {
        case .stalled:
            return String(localized: "settings.applehealth.history.stalled")
        case .cancelled where !(store.overview?.isFinished ?? false):
            return String(localized: "settings.applehealth.history.cancelled")
        default:
            break
        }
        guard hasSynced || store.isRunning, let overview = store.overview, overview.totalCount > 0 else {
            return String(localized: "settings.applehealth.history.unknown")
        }
        if overview.isFinished {
            return String(localized: "settings.applehealth.history.complete")
        }
        let progress = String(
            localized: "settings.applehealth.history.progress \(overview.finishedCount) \(overview.totalCount)"
        )
        guard store.isRunning else { return progress }
        return progress + "\n" + String(localized: "settings.applehealth.history.running")
    }
}
