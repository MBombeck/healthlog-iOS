import SwiftUI

/// #12 — what the heart-rate bucket path has done for the signed-in account.
///
/// Since the cutover the app sends heart rate as 10-minute values instead of
/// single readings. When those values stop arriving, the questions are always
/// the same three: from which day on does the app use them, when did the
/// server last accept one, and which gate held the path back. Read from the
/// per-account ledger (``HRBucketSyncLedger``), so the answer survives a
/// relaunch; nothing here mutates it.
struct HRBucketDiagnosticsSnapshot: Equatable, Sendable {
    let cutover: Date?
    let ledger: HRBucketSyncLedger
    /// SYNC-HR — the sweep running in this process when the screen loaded.
    var activity: HRBucketSweepActivity?

    static func load(userId: String?, defaults: UserDefaults = .standard) -> HRBucketDiagnosticsSnapshot {
        HRBucketDiagnosticsSnapshot(
            cutover: HRBucketCutoverStore.persistedCutover(userId: userId, defaults: defaults),
            ledger: HRBucketSyncLedgerStore.load(userId: userId, defaults: defaults),
            activity: HRBucketSweepActivityBoard.current()
        )
    }

    /// SYNC-HR (server #586, promise 1) — when the newest heart-rate value
    /// the server holds was taken: the server's own `PULSE` entry of
    /// `metricFreshness` when it sends one, the device ledger otherwise
    /// (older server, or the server answer not loaded yet).
    func lastAccepted(freshness: [MetricFreshness]?) -> Date? {
        let server = ServerFreshnessFacts.row(
            forHealthKitIdentifier: HealthKitHRBucketRow.hkIdentifier,
            in: freshness
        )?.lastSeenAt
        return server ?? ledger.lastAcceptedBucket
    }

    /// The sweep in flight longer than its deadline at `now`, if any.
    func overdueSweep(now: Date) -> HRBucketSweepActivity? {
        guard let activity, activity.isOverdue(now: now) else { return nil }
        return activity
    }

    /// Raw-fallback days on or after the cutover.
    var rawFallbackDayCount: Int {
        guard let cutover else { return ledger.rawDays.count }
        let first = HRBucketSyncLedger.day(of: cutover)
        return ledger.rawDays.count(where: { $0 >= first })
    }
}

extension SettingsHKSyncDiagnosticsScreen {
    var heartRateBucketCard: some View {
        // 1.4 B2-c — what the cutover means is in the (i).
        HLSettingsCard(
            icon: "heart.text.square",
            title: "settings.hkdiag.hrbuckets.title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                statRow(label: "settings.hkdiag.hrbuckets.cutover", value: hrBucketCutoverLabel)
                statRow(
                    label: "settings.hkdiag.hrbuckets.last_accepted",
                    value: hrBucketDateLabel(hrBucketSnapshot?.lastAccepted(freshness: serverSummary?.freshness))
                )
                statRow(label: "settings.hkdiag.hrbuckets.last_run", value: hrBucketLastRunLabel)
                // 1.4 B4 — when the last run was itself the hold, the row
                // below said the same gate and time a second time.
                if hrBucketSnapshot?.ledger.lastSuppression != hrBucketSnapshot?.ledger.lastEvent {
                    statRow(
                        label: "settings.hkdiag.hrbuckets.last_suppression",
                        value: hrBucketEventLabel(hrBucketSnapshot?.ledger.lastSuppression)
                    )
                }
                statRow(
                    label: "settings.hkdiag.hrbuckets.raw_days",
                    value: "\(hrBucketSnapshot?.rawFallbackDayCount ?? 0)"
                )
            }
        }
        .accessibilityIdentifier("settings.hkdiag.heartRateBuckets")
    }

    func loadHeartRateBuckets() {
        let userID = container?.keychain.getString(forKey: KeychainKey.userID)
        hrBucketSnapshot = HRBucketDiagnosticsSnapshot.load(userId: userID)
    }

    private var hrBucketCutoverLabel: String {
        guard let cutover = hrBucketSnapshot?.cutover else {
            return String(localized: "settings.hkdiag.hrbuckets.not_armed")
        }
        return cutover.formatted(Date.ISO8601FormatStyle().year().month().day())
    }

    private func hrBucketDateLabel(_ date: Date?) -> String {
        guard let date else { return String(localized: "settings.hkdiag.never") }
        return date.formatted(.dateTime.day().month().hour().minute())
    }

    /// SYNC-HR — a sweep past its deadline is named as such, with its start.
    private var hrBucketLastRunLabel: String {
        if let overdue = hrBucketSnapshot?.overdueSweep(now: Date()) {
            return HKSyncDiagnosticsVocabulary.heartRateBucketRunningSince(overdue.startedAt)
        }
        return hrBucketEventLabel(hrBucketSnapshot?.ledger.lastEvent)
    }

    private func hrBucketEventLabel(_ event: HRBucketSyncLedger.Event?) -> String {
        guard let event else { return String(localized: "settings.hkdiag.never") }
        let gate = HKSyncDiagnosticsVocabulary.heartRateBucketGate(event.gate)
        return "\(gate), \(relativeOrNever(event.at))"
    }
}
