import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

// W5 (1.3.0, #126 1.4) — "Bericht kopieren": the screen's story as plain
// text on the clipboard (``SyncDiagnosticsReport``), a precursor to the
// support info of #134. Copying is the whole effect: nothing is sent.

extension SettingsHKSyncDiagnosticsScreen {
    var reportCard: some View {
        // 1.4 B4 — one row, one heading: "Bericht kopieren" names it.
        HLSettingsCard(footer: "settings.hkdiag.report.footer") {
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
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
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
            serverVersion: UserDefaults.standard.string(forKey: KnownServerVersion.defaultsKey),
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
