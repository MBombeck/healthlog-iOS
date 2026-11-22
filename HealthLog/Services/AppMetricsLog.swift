import Foundation
import Synchronization
#if canImport(MetricKit)
    import MetricKit
#endif

/// **Field data from iOS, kept on this device (D5 #12).**
///
/// Launch time, hangs, terminations in the background (`0xdead10cc`, the
/// memory limit, the watchdog) and CPU time were visible only to somebody who
/// measured them on their own device. MetricKit delivers them about once a
/// day; this keeps the last ``capacity`` reports in a small ring buffer in the
/// app's own defaults, where Settings › Support diagnostics shows them.
///
/// **Nothing leaves the device.** No report is uploaded, forwarded or shared
/// with anybody; the only reader is the support screen, behind its own gate.
/// A report holds counts and durations only, no health data and no
/// identifiers.
struct AppMetricsReport: Codable, Sendable, Equatable {
    struct ExitCounts: Codable, Sendable, Equatable {
        var memoryLimit = 0
        var watchdog = 0
        var lockedFile = 0
        var cpuLimit = 0
        var taskTimeout = 0

        var total: Int {
            memoryLimit + watchdog + lockedFile + cpuLimit + taskTimeout
        }
    }

    /// The end of the period the report covers.
    var endedAt: Date
    /// Mean time to the first frame of a launch.
    var launchSeconds: Double?
    /// Mean hang duration.
    var hangSeconds: Double?
    /// Total CPU time over the period.
    var cpuSeconds: Double?
    /// Peak memory over the period.
    var peakMemoryBytes: Double?
    /// Abnormal terminations while the app ran in the background.
    var backgroundExits: ExitCounts?
    /// Crash and hang diagnostics iOS delivered for the period.
    var crashes = 0
    var hangs = 0
}

/// The ring buffer. Thread-safe: MetricKit calls its subscriber on a queue of
/// its own, the support screen reads on the main actor.
final class AppMetricsLog: Sendable {
    static let shared = AppMetricsLog()
    static let capacity = 14
    static let defaultsKey = "hl.diagnostics.metrickit.v1"

    /// The defaults suite, by name: `UserDefaults` is not `Sendable`, so the
    /// log resolves it on each access (`nil` = the app's standard defaults).
    private let suiteName: String?
    private let lock = Mutex(())

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Newest first.
    func reports() -> [AppMetricsReport] {
        lock.withLock { _ in load() }.sorted { $0.endedAt > $1.endedAt }
    }

    func record(_ report: AppMetricsReport) {
        lock.withLock { _ in
            var all = load()
            all.append(report)
            all.sort { $0.endedAt < $1.endedAt }
            if all.count > Self.capacity { all.removeFirst(all.count - Self.capacity) }
            save(all)
        }
    }

    /// Adds crash and hang diagnostics to the report of their period, or
    /// keeps them in a report of their own.
    func recordDiagnostics(endedAt: Date, crashes: Int, hangs: Int) {
        guard crashes > 0 || hangs > 0 else { return }
        lock.withLock { _ in
            var all = load()
            if let index = all.firstIndex(where: { abs($0.endedAt.timeIntervalSince(endedAt)) < 6 * 3600 }) {
                all[index].crashes += crashes
                all[index].hangs += hangs
            } else {
                all.append(AppMetricsReport(endedAt: endedAt, crashes: crashes, hangs: hangs))
                all.sort { $0.endedAt < $1.endedAt }
                if all.count > Self.capacity { all.removeFirst(all.count - Self.capacity) }
            }
            save(all)
        }
    }

    func clear() {
        lock.withLock { _ in defaults.removeObject(forKey: Self.defaultsKey) }
    }

    private func load() -> [AppMetricsReport] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let reports = try? JSONDecoder().decode([AppMetricsReport].self, from: data) else { return [] }
        return reports
    }

    private func save(_ reports: [AppMetricsReport]) {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

#if canImport(MetricKit) && os(iOS)
    /// The MetricKit subscriber. Registered once at launch; it only turns a
    /// payload into an ``AppMetricsReport`` and hands it to the log.
    final class AppMetricsSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
        static let shared = AppMetricsSubscriber(log: .shared)

        private let log: AppMetricsLog
        private let started = Mutex(false)

        init(log: AppMetricsLog) {
            self.log = log
        }

        func start() {
            let first = started.withLock { value -> Bool in
                defer { value = true }
                return !value
            }
            guard first else { return }
            MXMetricManager.shared.add(self)
        }

        func didReceive(_ payloads: [MXMetricPayload]) {
            for payload in payloads {
                log.record(Self.report(from: payload))
            }
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads {
                log.recordDiagnostics(
                    endedAt: payload.timeStampEnd,
                    crashes: payload.crashDiagnostics?.count ?? 0,
                    hangs: payload.hangDiagnostics?.count ?? 0
                )
            }
        }

        static func report(from payload: MXMetricPayload) -> AppMetricsReport {
            var report = AppMetricsReport(endedAt: payload.timeStampEnd)
            if let launch = payload.applicationLaunchMetrics {
                report.launchSeconds = meanSeconds(launch.histogrammedTimeToFirstDraw)
            }
            if let responsiveness = payload.applicationResponsivenessMetrics {
                report.hangSeconds = meanSeconds(responsiveness.histogrammedApplicationHangTime)
            }
            report.cpuSeconds = payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value
            report.peakMemoryBytes = payload.memoryMetrics?.peakMemoryUsage.converted(to: .bytes).value
            if let background = payload.applicationExitMetrics?.backgroundExitData {
                report.backgroundExits = AppMetricsReport.ExitCounts(
                    memoryLimit: background.cumulativeMemoryResourceLimitExitCount,
                    watchdog: background.cumulativeAppWatchdogExitCount,
                    lockedFile: background.cumulativeSuspendedWithLockedFileExitCount,
                    cpuLimit: background.cumulativeCPUResourceLimitExitCount,
                    taskTimeout: background.cumulativeBackgroundTaskAssertionTimeoutExitCount
                )
            }
            return report
        }

        /// The count-weighted mean of a duration histogram, from bucket
        /// midpoints; `nil` without a sample.
        private static func meanSeconds(_ histogram: MXHistogram<UnitDuration>) -> Double? {
            var total = 0.0
            var count = 0
            let buckets = histogram.bucketEnumerator
            while let bucket = buckets.nextObject() as? MXHistogramBucket<UnitDuration> {
                let start = bucket.bucketStart.converted(to: .seconds).value
                let end = bucket.bucketEnd.converted(to: .seconds).value
                total += (start + end) / 2 * Double(bucket.bucketCount)
                count += bucket.bucketCount
            }
            return count > 0 ? total / Double(count) : nil
        }
    }
#endif
