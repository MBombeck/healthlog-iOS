import Foundation

/// **W5 (1.3.0, #126 1.4) — "Bericht kopieren", a precursor to #134.**
///
/// A plain-text summary of the Sync Diagnostics screen that a tester can paste
/// into an issue. It carries the same story the screen tells, grouped by
/// source, in fixed English words so it reads the same whatever the phone's
/// language is and can be compared line by line between two reports.
///
/// **What it never carries.** No health value, no measurement time (the
/// server's `lastSeenAt` is when a reading was taken, so it stays out), no
/// server address, no account id, no name or e-mail. Only build and server
/// version, per-type arrival times and triggers, counts, hold reasons and
/// history depth. The builder takes exactly those inputs and nothing else, so
/// nothing personal can leak in from a field it never sees;
/// `SyncDiagnosticsReportTests` pins that with a fixture that has all of them.
struct SyncDiagnosticsReport: Equatable {
    struct Input {
        var generatedAt: Date
        var build: AppBuildMetadata
        var osVersion: String
        /// The last answer of `GET /api/version`, if any.
        var serverVersion: String?
        /// `nil` with `serverLoadFailed == false`: still loading.
        var server: HKServerSyncHealthSummary?
        var serverLoadFailed: Bool
        var heldGroups: [OutboxHeldGroup]
        var statsLog: HealthKitStatsUploadLog?
        var history: [HistoryKindRow]
        var lastCollectionTriggerAt: Date?
        var lastCollectionTriggerSource: String?
        var kinds: [KindRow]
        /// INT-Q (X1, #134) — the last failures the server answered this
        /// session, newest first (``RecentFailureLog/snapshot()``): route
        /// template, status, error code, request id. No body, no value.
        var recentFailures: [RecentFailure] = []
        /// INT-Q (X4, #138) — the hourly backfill's progress for this
        /// account; `nil` when the server does not take hourly rows.
        var hourly: HourlyStatsStatus?
        /// 1.4 B4 — the heart-rate bucket path (#12). The screen shows its
        /// gates in words only; the identifiers a tester quotes back live
        /// here. `nil` leaves the block out.
        var hrBuckets: HRBucketDiagnosticsSnapshot?
    }

    let text: String

    init(_ input: Input) {
        var lines: [String] = []
        lines.append("HealthLog sync diagnostics")
        lines.append("generated: \(Self.stamp(input.generatedAt))")
        lines.append("app: \(input.build.marketingVersion ?? "unknown") (\(input.build.build ?? "unknown"))")
        lines.append("os: iOS \(input.osVersion)")
        lines.append("server version: \(input.serverVersion ?? "unknown")")
        lines.append("")
        lines += Self.serverSection(input)
        lines.append("")
        lines += Self.storedSection(input)
        lines.append("")
        lines += Self.sessionSection(input)
        // INT-Q — X1's error ids, in the same words as "Support-Info kopieren".
        lines.append("")
        lines += RecentFailureLines.lines(input.recentFailures)
        text = lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Sections

    private static func serverSection(_ input: Input) -> [String] {
        appleHealthLines(input.server, loadFailed: input.serverLoadFailed)
    }

    /// The Apple Health block of `GET /api/integrations/healthkit`: state,
    /// reason and since, delivery, background sync, then per type the arrival
    /// facts (no values, no reading times). Shared with "Support-Info
    /// kopieren" (#134), so both reports say it in the same words.
    static func appleHealthLines(_ server: HKServerSyncHealthSummary?, loadFailed: Bool) -> [String] {
        var lines = ["[server] GET /api/integrations/healthkit"]
        guard let server else {
            lines.append(loadFailed ? "not reachable" : "not loaded")
            return lines
        }
        guard server.hasServerData else {
            lines.append("no sync data yet")
            return lines
        }
        let since = server.since.map { " since \(stamp($0))" } ?? ""
        if let health = server.health {
            lines.append("state: \(health.state.wireValue) (\(health.reason.wireValue))\(since)")
        } else if let verdict = server.verdict {
            lines.append("legacy verdict: \(verdict.rawValue)\(since)")
        }
        lines.append("delivers on its own: \(autonomyWord(server.autonomy))")
        lines.append("last background sync: \(stampOrNever(server.lastBackgroundSyncAt))")
        lines.append("last trigger: \(server.lastSyncTrigger ?? "none")")
        guard let freshness = server.freshness else {
            lines.append("types: not reported by this server")
            return lines
        }
        lines.append(freshness.isEmpty ? "types: none yet" : "types:")
        for row in freshness.sorted(by: { $0.type < $1.type }) {
            lines.append("  \(typeLine(row))")
        }
        return lines
    }

    private static func storedSection(_ input: Input) -> [String] {
        var lines = ["[this iPhone, kept across launches]"]
        if input.heldGroups.isEmpty {
            lines.append("held entries: none")
        } else {
            lines.append("held entries:")
            for group in input.heldGroups {
                lines.append("  \(holdWord(group.reason)): \(group.count)")
            }
        }
        if let log = input.statsLog {
            lines.append("day totals last checked: \(event(log.lastSweep))")
            for identifier in log.uploads.keys.sorted() {
                if let entry = log.uploads[identifier] {
                    lines.append("  \(identifier): new value sent \(event(entry))")
                }
            }
        }
        if let hourly = input.hourly {
            lines.append("hourly backfill: \(hourly.backfillDaysCompleted) of \(hourly.backfillDaysTotal) days")
        }
        if let buckets = input.hrBuckets {
            lines += heartRateBucketLines(buckets)
        }
        if !input.history.isEmpty {
            lines.append("history:")
            for row in input.history {
                lines.append("  \(row.kind.rawValue): \(historyWord(row.state))")
            }
        }
        return lines
    }

    private static func sessionSection(_ input: Input) -> [String] {
        var lines = ["[this iPhone, since launch]"]
        var trigger = stampOrNever(input.lastCollectionTriggerAt)
        if let source = input.lastCollectionTriggerSource, input.lastCollectionTriggerAt != nil {
            trigger += " (\(source))"
        }
        lines.append("last collection trigger: \(trigger)")
        let active = input.kinds.filter { $0.timeFact != .none || $0.stats.samplesReadTotal > 0 }
        for row in active.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            let stats = row.stats
            var line = "  \(row.kind.rawValue): read \(stats.samplesReadTotal), uploaded \(stats.samplesUploadedTotal)"
            line += ", skipped \(max(stats.samplesSkippedTotal, row.registeredSkipCount)), parked \(stats.samplesParkedTotal)"
            line += ", \(timeWords(row.timeFact))"
            lines.append(line)
        }
        if active.isEmpty { lines.append("  no activity since launch") }
        return lines
    }

    /// 1.4 B4 — the heart-rate bucket path with its gate identifiers
    /// (`cutoverPending`, `uploaded`, …), the words Console prints after
    /// `gate=`. No reading, only dates, gates and counts.
    static func heartRateBucketLines(_ snapshot: HRBucketDiagnosticsSnapshot) -> [String] {
        let cutover = snapshot.cutover.map { day($0) } ?? "not armed"
        return [
            "heart rate buckets: cutover \(cutover)",
            "  last accepted: \(stampOrNever(snapshot.ledger.lastAcceptedBucket))",
            "  last run: \(gateEvent(snapshot.ledger.lastEvent))",
            "  last held by: \(gateEvent(snapshot.ledger.lastSuppression))",
            "  raw fallback days: \(snapshot.rawFallbackDayCount)"
        ]
    }

    private static func gateEvent(_ event: HRBucketSyncLedger.Event?) -> String {
        guard let event else { return "never" }
        return "\(event.gate.rawValue) at \(stamp(event.at)), \(event.count) rows"
    }

    // MARK: - Words

    /// Receipt, new value, background arrival and the stale flag. Never
    /// `lastSeenAt`: that is when a reading was taken.
    static func typeLine(_ row: MetricFreshness) -> String {
        let facts = ServerFreshnessFacts(row: row)
        var parts = ["\(row.type): checked \(stampOrNever(facts.lastChecked))"]
        if let trigger = row.lastTrigger, facts.lastChecked != nil { parts[0] += " (\(trigger))" }
        parts.append("new value \(stampOrNever(facts.lastNewValue))")
        parts.append("background \(stampOrNever(row.lastBackgroundAt))")
        // INT-Q — v1.43's backfill stamp, only where the server sends one.
        if let backfill = row.lastBackfillAt { parts.append("backfill \(stamp(backfill))") }
        if row.stale { parts.append("stale") }
        return parts.joined(separator: ", ")
    }

    static func holdWord(_ reason: OutboxHoldReason) -> String {
        switch reason {
        case let .serverRefused(status): "server refused (\(status))"
        case let .moduleDisabled(module): "module off (\(module))"
        case .unmappable: "type unknown to server"
        case .refusalNotRecorded: "refusal not recorded"
        case .retryBudgetExhausted: "retry budget exhausted"
        }
    }

    private static func autonomyWord(_ autonomy: HKServerSyncHealthSummary.Autonomy) -> String {
        switch autonomy {
        case .confirmed: "confirmed"
        case .foregroundOnly: "foreground only so far"
        case .unknown: "unknown"
        }
    }

    private static func historyWord(_ state: HistoryKindRow.State) -> String {
        switch state {
        case .complete: "complete"
        case .finishing: "older part following"
        case .notStarted: "not started"
        case let .reachedBack(date): "back to \(day(date))"
        }
    }

    private static func timeWords(_ fact: KindRow.TimeFact) -> String {
        switch fact {
        case .none: "nothing yet"
        case let .checkedOnly(checked): "checked \(stamp(checked)), nothing new"
        case let .newValue(new, nil): "new value \(stamp(new))"
        case let .newValue(new, checked?): "new value \(stamp(new)), checked \(stamp(checked))"
        }
    }

    private static func event(_ entry: HealthKitStatsUploadLog.Entry?) -> String {
        guard let entry else { return "never" }
        return "\(stamp(entry.at)) (\(entry.trigger)), \(entry.count) rows"
    }

    // MARK: - Dates

    /// UTC, to the second: "2026-10-16T08:00:00Z".
    static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static func stampOrNever(_ date: Date?) -> String {
        date.map(stamp) ?? "never"
    }

    /// A history depth is a calendar day on this phone.
    private static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}
