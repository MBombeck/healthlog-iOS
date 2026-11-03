import SwiftUI

// W5 (1.3.0, #126 1.2 and 1.4, HealthLog#586, #1173) — one story.
//
// The screen used to show two truths for the same type: "Day totals and
// pulse" said Pulse "Nothing yet" (a record of what this iPhone sent as a
// 10-minute value) while "Freshness per type" said "Received 5 hours ago
// (Background)" (what the server received, single readings included). Both
// were right, neither said where it came from. Every card now names its
// source, and every time on a row says what it is: when the type was last
// checked, or when a new value last went to the server. A sweep that finds
// nothing new moves the first, never the second, so distance and energy no
// longer look stale on a day when nothing changed.

// 1.4 B2-c — the per-card "Quelle: …" line is gone: the server card is the
// only card from the server, and the (i) says which of this iPhone's cards
// count since the last launch and which are kept across launches.

// MARK: - Server rows (`metricFreshness`)

/// One `metricFreshness` entry as the facts the row states.
struct ServerFreshnessFacts: Equatable {
    let row: MetricFreshness

    /// Receipts closer than this are the same batch.
    static let sameBatchTolerance: TimeInterval = 60

    /// When a batch last carried the type, new or not: the last check.
    var lastChecked: Date? {
        row.lastReceivedAt
    }

    /// When a batch last brought a new or changed reading.
    var lastNewValue: Date? {
        row.lastNewSampleAt
    }

    /// The last check found nothing new: the type was confirmed, not changed.
    var lastCheckFoundNothingNew: Bool {
        guard let checked = lastChecked, let new = lastNewValue else { return false }
        return checked.timeIntervalSince(new) > Self.sameBatchTolerance
    }

    /// The last background arrival as its own line, unless the last check
    /// already was that background arrival.
    var separateBackgroundArrival: Date? {
        guard let background = row.lastBackgroundAt else { return nil }
        if row.lastTrigger == SyncTrigger.background.rawValue, let checked = lastChecked,
           abs(checked.timeIntervalSince(background)) <= Self.sameBatchTolerance
        {
            return nil
        }
        return background
    }

    var isMedicationDose: Bool {
        HKSyncDiagnosticsVocabulary.normalizedTypeKey(row.type) == "MEDICATION_DOSE"
    }

    /// "Last checked 5 minutes ago (Background)", or `nil` before server v1.42.
    var checkedLabel: String? {
        guard let checked = lastChecked else { return nil }
        let when = Self.relative(checked)
        guard let trigger = row.lastTrigger else {
            return String(localized: "settings.hkdiag.freshness_received \(when)")
        }
        let word = HKSyncDiagnosticsVocabulary.collectionTrigger(trigger)
        return String(localized: "settings.hkdiag.freshness_received_by \(when) \(word)")
    }

    /// "Last new value sent 9 hours ago", or `nil` when the server does not say.
    var newValueLabel: String? {
        guard let new = lastNewValue else { return nil }
        return String(localized: "settings.hkdiag.freshness_new_value \(Self.relative(new))")
    }

    /// "Last sent in the background 2 hours ago", when that is news.
    var backgroundLabel: String? {
        guard let background = separateBackgroundArrival else { return nil }
        return String(localized: "settings.hkdiag.freshness_background \(Self.relative(background))")
    }

    /// #146 / server #1247 — "Last entered here 2 minutes ago" on a type
    /// the server writes back to Apple Health, as the server sends it. It
    /// explains why the row reads fresh although Apple Health sent nothing new;
    /// the time on the right (`lastSeenAt`) and `stale` stay the server's own.
    var enteredHereLabel: String? {
        guard let entered = row.lastEnteredHereAt else { return nil }
        return String(localized: "settings.hkdiag.freshness_entered_here \(Self.relative(entered))")
    }

    /// The caption lines under the type name, in reading order.
    var detailLines: [String] {
        [checkedLabel, newValueLabel, backgroundLabel, enteredHereLabel].compactMap { $0 }
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// The server row for a HealthKit identifier, through the one mapping
    /// table the history floor uses (`APPLE_HEALTH_TYPE_MAP` on the server).
    static func row(forHealthKitIdentifier identifier: String, in freshness: [MetricFreshness]?) -> MetricFreshness? {
        guard let freshness, let serverType = HealthSampleReplayFloor.serverType[identifier] else { return nil }
        let key = HKSyncDiagnosticsVocabulary.normalizedTypeKey(serverType)
        return freshness.first { HKSyncDiagnosticsVocabulary.normalizedTypeKey($0.type) == key }
    }
}

// MARK: - Session rows (per kind)

extension KindRow {
    /// What the time on a session row says.
    enum TimeFact: Equatable {
        /// Nothing since the last launch.
        case none
        /// Checked, nothing new went to the server.
        case checkedOnly(Date)
        /// A new value went to the server; `checkedSince` when a later check
        /// found nothing more.
        case newValue(Date, checkedSince: Date?)
    }

    /// The last time this iPhone looked: a HealthKit delivery for the kind,
    /// or, for a summed kind, the last daily-statistics sweep.
    var lastCheckedAt: Date? {
        [stats.lastObservationAt, lastSweepAt].compactMap { $0 }.max()
    }

    /// The last time something new went up: a posted day value, or an anchor
    /// advance on a path that stored readings this session.
    var lastNewValueAt: Date? {
        let anchor = stats.samplesUploadedTotal > 0 ? stats.lastAnchorAdvancedAt : nil
        return [stats.lastStatsActionAt, anchor].compactMap { $0 }.max()
    }

    var timeFact: TimeFact {
        switch (lastNewValueAt, lastCheckedAt) {
        case (nil, nil):
            return .none
        case let (nil, checked?):
            return .checkedOnly(checked)
        case let (new?, checked):
            guard let checked, checked.timeIntervalSince(new) > ServerFreshnessFacts.sameBatchTolerance else {
                return .newValue(new, checkedSince: nil)
            }
            return .newValue(new, checkedSince: checked)
        }
    }

    /// 1.4 B4 — a row with nothing to report since the launch: nothing read,
    /// skipped or parked, no check, no new value. Its status says "Ruhend";
    /// "0 gelesen, 0 übertragen" and "Seit dem App-Start noch nichts" under
    /// every such row said it twice more, on twenty-odd rows.
    var isQuiet: Bool {
        status() == .idle && stats.samplesReadTotal == 0 && registeredSkipCount == 0
            && stats.samplesParkedTotal == 0 && timeFact == .none
    }

    /// The most recent of both, for sorting.
    var lastTouchedAt: Date? {
        [lastNewValueAt, lastCheckedAt].compactMap { $0 }.max()
    }

    var timeLabel: String {
        switch timeFact {
        case .none:
            return String(localized: "settings.hkdiag.kind_time.none")
        case let .checkedOnly(checked):
            return String(localized: "settings.hkdiag.kind_time.checked \(ServerFreshnessFacts.relative(checked))")
        case let .newValue(new, nil):
            return String(localized: "settings.hkdiag.kind_time.new \(ServerFreshnessFacts.relative(new))")
        case let .newValue(new, checked?):
            let newText = ServerFreshnessFacts.relative(new)
            let checkedText = ServerFreshnessFacts.relative(checked)
            return String(localized: "settings.hkdiag.kind_time.new_and_checked \(newText) \(checkedText)")
        }
    }
}
