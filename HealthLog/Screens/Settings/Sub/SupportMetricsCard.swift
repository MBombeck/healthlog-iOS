import SwiftUI

/// Settings › Support diagnostics: the MetricKit reports of the last days
/// (``AppMetricsLog``), kept on this device only (D5 #12). Read-only and
/// without a request of its own, like the rest of the screen.
struct SupportMetricsCard: View {
    let reports: [AppMetricsReport]

    var body: some View {
        HLCard(
            "settings.support.metrics_title",
            subtitle: "settings.support.metrics_subtitle"
        ) {
            if reports.isEmpty {
                HLEmptyNote("settings.support.metrics_empty")
                    .accessibilityIdentifier("settings.supportDiagnostics.metricsEmpty")
            } else {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(reports, id: \.endedAt) { report in
                        reportRows(report)
                    }
                }
                .accessibilityIdentifier("settings.supportDiagnostics.metrics")
            }
        }
    }

    private func reportRows(_ report: AppMetricsReport) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(HLDateFormat.dayMonth(report.endedAt))
                .hlText(.factLabel)
            if let launch = report.launchSeconds {
                HLSettingsStatRow(label: Text("settings.support.metrics_launch"), value: Self.duration(launch))
            }
            if let hang = report.hangSeconds {
                HLSettingsStatRow(label: Text("settings.support.metrics_hangs"), value: Self.duration(hang))
            }
            if let cpu = report.cpuSeconds {
                HLSettingsStatRow(label: Text("settings.support.metrics_cpu"), value: Self.duration(cpu))
            }
            if let memory = report.peakMemoryBytes {
                HLSettingsStatRow(label: Text("settings.support.metrics_memory"), value: Self.bytes(memory))
            }
            if let exits = report.backgroundExits {
                HLSettingsStatRow(label: Text("settings.support.metrics_bg_exits"), value: "\(exits.total)")
                if exits.total > 0 {
                    Text(Self.exitDetail(exits))
                        .hlText(.rowSubtitle)
                }
            }
            if report.crashes > 0 || report.hangs > 0 {
                HLSettingsStatRow(
                    label: Text("settings.support.metrics_diagnostics"),
                    value: String(localized: "settings.support.metrics_diag_value \(report.crashes) \(report.hangs)")
                )
            }
        }
    }

    static func exitDetail(_ exits: AppMetricsReport.ExitCounts) -> String {
        String(
            localized: "settings.support.metrics_exit_detail \(exits.memoryLimit) \(exits.watchdog) \(exits.lockedFile) \(exits.cpuLimit) \(exits.taskTimeout)"
        )
    }

    /// Seconds to two decimals, in the locale's own duration unit.
    static func duration(_ seconds: Double) -> String {
        Foundation.Measurement(value: (seconds * 100).rounded() / 100, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    static func bytes(_ value: Double) -> String {
        Foundation.Measurement(value: value, unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .memory))
    }
}
