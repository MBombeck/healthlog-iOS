import SwiftUI

/// **V1 (1.2, #66 / HealthLog#1173)** — when each summed or averaged type last
/// reached the server, and which trigger carried it.
///
/// The five day totals (steps, active energy, flights, distance, daylight) and
/// the pulse buckets go up as `stats:` rows, not as single readings, so the
/// per-kind list above (session counters, reset on every launch) cannot answer
/// whether they arrived on their own overnight. This card reads the persistent
/// per-account record (``HealthKitStatsUploadLog``). A row whose time moves on
/// with "Background" or "Foreground" next to it, without anybody pressing
/// "Sync all", is the evidence the server team asked for.
extension SettingsHKSyncDiagnosticsScreen {
    /// The identifiers this card lists, in display order.
    static let statsUploadIdentifiers: [String] = HealthKitCumulativeTypeConfig.defaults.map(\.identifier)
        + [HealthKitHRBucketRow.hkIdentifier]

    var statsUploadCard: some View {
        HLSettingsCard(
            icon: "sum",
            title: "settings.hkdiag.stats.title",
            footer: "settings.hkdiag.stats.footer"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                statRow(label: "settings.hkdiag.stats.last_sweep", value: statsEventLabel(statsUploadLog?.lastSweep))
                ForEach(Self.statsUploadIdentifiers, id: \.self) { identifier in
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
                        Text(Self.statsTypeTitle(identifier))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.primary)
                        Spacer(minLength: HLSpace.sm)
                        Text(statsEventLabel(statsUploadLog?.uploads[identifier]))
                            .font(.hlCaption.monospacedDigit())
                            .foregroundStyle(HLText.tertiary)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("settings.hkdiag.statsUploads")
    }

    func loadStatsUploads() {
        let userID = container?.keychain.getString(forKey: KeychainKey.userID)
        statsUploadLog = HealthKitStatsUploadLogStore.load(ownerID: userID)
    }

    /// "5 minutes ago, Background", or "Never".
    func statsEventLabel(_ entry: HealthKitStatsUploadLog.Entry?) -> String {
        guard let entry else { return String(localized: "settings.hkdiag.never") }
        let trigger = HKSyncDiagnosticsVocabulary.collectionTrigger(entry.trigger)
        return "\(relativeOrNever(entry.at)), \(trigger)"
    }

    static func statsTypeTitle(_ identifier: String) -> String {
        guard let kind = HKSyncDiagnostics.metricKind(for: identifier) else { return identifier }
        return String(localized: kind.descriptor.title)
    }
}
