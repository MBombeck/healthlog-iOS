import SwiftUI

/// **1.3 (#127) — how far back the history walk has reached, per type.**
///
/// New readings travel on their own live stream and are not shown here. This
/// card answers the other question: is the older history on the server yet,
/// and if not, back to which day it has got. Several HealthKit types that
/// make up one metric (both blood-pressure halves, for example) share a row;
/// the row is complete only when all of them are.
extension SettingsHKSyncDiagnosticsScreen {
    var historyPerTypeCard: some View {
        HistoryPerTypeCard(store: HealthHistoryCatchUpStore.shared, hourlyStatus: hourlyStatus)
    }

    /// INT-Q (X4, #138) — the hourly backfill of the summed types for the
    /// signed-in account, or `nil` while the server does not take hourly rows
    /// (then the card shows no hourly row at all).
    func hourlyStatus() -> HourlyStatsStatus? {
        guard KnownServerVersion.supports(.cumulativeHourBuckets),
              let userID = container?.keychain.getString(forKey: KeychainKey.userID) else { return nil }
        return HourlyStatsLedgerStore.status(ownerID: userID)
    }
}

/// One metric's history state, folded from its HealthKit types.
struct HistoryKindRow: Equatable {
    let kind: MetricKind
    let statuses: [HealthSampleHistoryStatus]

    /// The row the operator reads: complete, still owed below a date, or not
    /// started yet.
    enum State: Equatable {
        case complete
        case finishing
        case reachedBack(Date)
        case notStarted
    }

    var state: State {
        if statuses.allSatisfy(\.isFinished) { return .complete }
        let reached = statuses.compactMap(\.reachedBack)
        guard reached.count == statuses.count, let laggard = reached.max() else { return .notStarted }
        if statuses.allSatisfy(\.isComplete) { return .finishing }
        return .reachedBack(laggard)
    }

    static func rows(_ overview: HealthHistoryOverview) -> [HistoryKindRow] {
        var byKind: [MetricKind: [HealthSampleHistoryStatus]] = [:]
        for status in overview.types {
            guard let kind = HKSyncDiagnostics.identifierToKind[status.typeIdentifier] else { continue }
            byKind[kind, default: []].append(status)
        }
        return byKind
            .map { HistoryKindRow(kind: $0.key, statuses: $0.value) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }
}

struct HistoryPerTypeCard: View {
    let store: HealthHistoryCatchUpStore
    let hourlyStatus: () -> HourlyStatsStatus?
    @State private var hourly: HourlyStatsStatus?

    var body: some View {
        // 1.4 B2-c — no subtitle: the Apple Health page already says the
        // older history follows on its own.
        HLSettingsCard(
            icon: "clock.arrow.circlepath",
            title: "settings.hkdiag.history_title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if let overview = store.overview, !overview.types.isEmpty {
                    let rows = HistoryKindRow.rows(overview)
                    // 1.4 B4 — twenty-five rows that all read "Bis 19.10.2026"
                    // are one row for all types.
                    if let shared = Self.sharedState(rows) {
                        historyRow(title: Text("settings.hkdiag.history_allTypes"), state: shared)
                            .accessibilityIdentifier("settings.hkdiag.history.allTypes")
                    } else {
                        ForEach(rows, id: \.kind) { row in
                            historyRow(title: Text(row.kind.descriptor.title), state: row.state)
                        }
                    }
                } else {
                    Text("settings.hkdiag.history_pending")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
                // B5 (1.4, R4 2.1) — "complete" above means as far as Apple
                // Health lets HealthLog read; A3's one line says from when.
                if let start = store.overview?.limitedFrom {
                    Text("settings.applehealth.limitedHistory \(start.formatted(.dateTime.day().month(.wide).year()))")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.hkdiag.limitedHistory")
                }
                if let hourly {
                    HStack(alignment: .firstTextBaseline) {
                        Text("settings.hkdiag.history_hourly_title")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                        Spacer(minLength: HLSpace.md)
                        Text(Self.hourlyLabel(hourly))
                            .font(.hlCaption.monospacedDigit())
                            .foregroundStyle(HLText.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .task {
            hourly = hourlyStatus()
            await store.refresh()
        }
    }

    private func historyRow(title: Text, state: HistoryKindRow.State) -> some View {
        HStack(alignment: .firstTextBaseline) {
            title
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: HLSpace.md)
            Text(Self.label(state))
                .font(.hlCaption.monospacedDigit())
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 1.4 B4 — the one state every row shares, or `nil` when they differ
    /// (or there is only one row, which needs no summary).
    static func sharedState(_ rows: [HistoryKindRow]) -> HistoryKindRow.State? {
        guard rows.count > 1, let first = rows.first?.state else { return nil }
        return rows.allSatisfy { label($0.state) == label(first) } ? first : nil
    }

    /// INT-Q — the hourly row: complete, or how many of the owed days are on
    /// the server.
    static func hourlyLabel(_ status: HourlyStatsStatus) -> String {
        if status.isBackfillComplete {
            return String(localized: "settings.hkdiag.history_complete")
        }
        return String(
            localized: "settings.hkdiag.history_hourly_days \(status.backfillDaysCompleted) \(status.backfillDaysTotal)"
        )
    }

    static func label(_ state: HistoryKindRow.State) -> String {
        switch state {
        case .complete:
            String(localized: "settings.hkdiag.history_complete")
        case .finishing:
            String(localized: "settings.hkdiag.history_finishing")
        case .notStarted:
            String(localized: "settings.hkdiag.history_pending")
        case let .reachedBack(date):
            String(localized: "settings.hkdiag.history_reached \(date.formatted(date: .numeric, time: .omitted))")
        }
    }
}
