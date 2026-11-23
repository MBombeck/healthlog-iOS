import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

// "Bericht kopieren": the screen's story as plain
// text on the clipboard (``SyncDiagnosticsReport``), a precursor to the
// support info of #134. Copying is the whole effect: nothing is sent.

extension SettingsHKSyncDiagnosticsScreen {
    var reportCard: some View {
        // One row, one heading: "Bericht kopieren" names it.
        HLCard(footer: "settings.hkdiag.report.footer") {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSettingsActionRow(
                    icon: "doc.on.doc",
                    title: "settings.hkdiag.report.copy",
                    presents: .confirm
                ) {
                    copyReport()
                }
                .accessibilityIdentifier("settings.hkdiag.copyReport")
                if reportCopied {
                    Text("settings.hkdiag.report.copied")
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The report from what this screen has loaded right now.
    var reportInput: SyncDiagnosticsReport.Input {
        SyncDiagnosticsReport.Input(
            generatedAt: Date(),
            build: AppBuildMetadata(
                marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"),
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            ),
            osVersion: Self.osVersion,
            serverVersion: serverVersion ?? UserDefaults.standard.string(forKey: KnownServerVersion.defaultsKey),
            server: serverSummary,
            serverLoadFailed: serverLoadFailed,
            heldGroups: heldGroups,
            statsLog: statsUploadLog,
            history: HealthHistoryCatchUpStore.shared.overview.map(HistoryKindRow.rows) ?? [],
            lastCollectionTriggerAt: diagnostics.lastCollectionTriggerAt,
            lastCollectionTriggerSource: diagnostics.lastCollectionTriggerSource,
            kinds: rows,
            recentFailures: RecentFailureLog.shared.snapshot(),
            hourly: hourlyStatus(),
            hrBuckets: hrBucketSnapshot
        )
    }

    /// The report names the server as it is now, not as the last throttled
    /// foreground saw it: a server update would otherwise read as missing.
    func loadServerVersion() async {
        guard let api = container?.api else { return }
        serverVersion = await Self.refreshedServerVersion { try await api.fetchServerVersion() }
    }

    /// Asks `GET /api/version` and records the answer for every gate that
    /// reads it; offline, the last recorded version stays and is returned.
    static func refreshedServerVersion(
        defaults: UserDefaults = .standard,
        fetch: () async throws -> ServerVersionInfo
    ) async -> String? {
        if let info = try? await fetch() {
            HealthKitServerTypeGate.record(info, defaults: defaults)
            return info.version
        }
        return defaults.string(forKey: KnownServerVersion.defaultsKey)
    }

    private func copyReport() {
        let text = SyncDiagnosticsReport(reportInput).text
        #if canImport(UIKit)
            UIPasteboard.general.string = text
        #endif
        reportCopied = true
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
