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

    static func load(userId: String?, defaults: UserDefaults = .standard) -> HRBucketDiagnosticsSnapshot {
        HRBucketDiagnosticsSnapshot(
            cutover: HRBucketCutoverStore.persistedCutover(userId: userId, defaults: defaults),
            ledger: HRBucketSyncLedgerStore.load(userId: userId, defaults: defaults)
        )
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
        HLSettingsCard(
            icon: "heart.text.square",
            title: "settings.hkdiag.hrbuckets.title",
            subtitle: "settings.hkdiag.hrbuckets.subtitle"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                statRow(label: "settings.hkdiag.hrbuckets.cutover", value: hrBucketCutoverLabel)
                statRow(
                    label: "settings.hkdiag.hrbuckets.last_accepted",
                    value: hrBucketDateLabel(hrBucketSnapshot?.ledger.lastAcceptedBucket)
                )
                statRow(label: "settings.hkdiag.hrbuckets.last_run", value: hrBucketEventLabel(hrBucketSnapshot?.ledger.lastEvent))
                statRow(
                    label: "settings.hkdiag.hrbuckets.last_suppression",
                    value: hrBucketEventLabel(hrBucketSnapshot?.ledger.lastSuppression)
                )
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

    private func hrBucketEventLabel(_ event: HRBucketSyncLedger.Event?) -> String {
        guard let event else { return String(localized: "settings.hkdiag.never") }
        let gate = HKSyncDiagnosticsVocabulary.heartRateBucketGate(event.gate)
        return "\(gate), \(relativeOrNever(event.at))"
    }
}
