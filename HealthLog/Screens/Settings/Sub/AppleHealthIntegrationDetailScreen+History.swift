import SwiftUI

/// **1.3 (#127, public #25) — the history card.**
///
/// New readings always go first; the older history follows on its own in the
/// time left over. This card says how far that has got and offers the one
/// explicit step: "Sync everything now", with the honest note that it wants
/// the phone awake and on the charger.
extension AppleHealthIntegrationDetailScreen {
    var historyCard: some View {
        HistoryCatchUpCard(store: HealthHistoryCatchUpStore.shared)
    }
}

private struct HistoryCatchUpCard: View {
    let store: HealthHistoryCatchUpStore

    var body: some View {
        // 1.4 B2-c — no subtitle: "new readings go first, the older history
        // follows on its own" and the four sentences over the button are one
        // short note now, shown only while there is something left to send.
        HLSettingsCard(
            icon: "clock.arrow.circlepath",
            title: "settings.applehealth.history.title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text(statusText)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.applehealth.history.status")

                if store.isRunning, let overview = store.overview, overview.totalCount > 0 {
                    ProgressView(value: Double(overview.finishedCount), total: Double(overview.totalCount))
                        .tint(HLText.primary)
                }

                if !(store.overview?.isFinished ?? false) || store.isRunning {
                    Text("settings.applehealth.history.note")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HLButton(
                        store.isRunning
                            ? String(localized: "settings.applehealth.history.stop")
                            : String(localized: "settings.applehealth.history.sync_all"),
                        icon: store.isRunning ? "stop.circle" : "arrow.down.circle",
                        variant: .secondary,
                        size: .regular
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
        guard let overview = store.overview, overview.totalCount > 0 else {
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
