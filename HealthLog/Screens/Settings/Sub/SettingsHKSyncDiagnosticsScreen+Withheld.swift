import SwiftUI

// What the phone holds back without a server ever refusing it: Apple Health
// doses the ledger is still waiting to account for, and data types whose
// cursor stayed locked after a failed write. Both used to be numbers only a
// debugger could see.

/// The card's content, read from the persisted pass snapshot.
struct SyncDiagnosticsWithheld: Equatable {
    /// Locked types that share one reason, by display name, sorted.
    struct LockGroup: Equatable {
        let reason: HealthSyncPartitionLockReason
        let typeNames: [String]
    }

    let pendingDoses: Int
    /// Background passes that found no signed-in session.
    let backgroundWithoutSession: Int
    /// One group per reason, in a fixed order: what heals itself first.
    let lockGroups: [LockGroup]

    init(_ snapshot: HKSyncDiagnostics.HealthSyncSnapshot) {
        pendingDoses = max(0, snapshot.pendingAppleDoseCount)
        backgroundWithoutSession = max(0, snapshot.backgroundPassesWithoutSession ?? 0)
        let locked = snapshot.lockedPartitions ?? [:]
        lockGroups = [HealthSyncPartitionLockReason.failedWrite, .notMigrated, .closed].compactMap { reason in
            let names = locked.filter { $0.value == reason }
                .map { HealthAccessTypeNaming.displayName(for: $0.key) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return names.isEmpty ? nil : LockGroup(reason: reason, typeNames: names)
        }
    }

    var lockedCount: Int {
        lockGroups.reduce(0) { $0 + $1.typeNames.count }
    }

    var isEmpty: Bool {
        pendingDoses == 0 && lockGroups.isEmpty && backgroundWithoutSession == 0
    }

    /// What the person is told about one group: only a failed write heals on
    /// the next sync; the other two wait for the next launch.
    static func note(for reason: HealthSyncPartitionLockReason) -> String {
        switch reason {
        case .failedWrite: String(localized: "settings.hkdiag.withheld_locked_note")
        case .notMigrated: String(localized: "settings.hkdiag.withheld_locked_note_setup")
        case .closed: String(localized: "settings.hkdiag.withheld_locked_note_closed")
        }
    }
}

extension SettingsHKSyncDiagnosticsScreen {
    @ViewBuilder
    var withheldCard: some View {
        let withheld = SyncDiagnosticsWithheld(diagnostics.healthSync)
        if !withheld.isEmpty {
            HLCard("settings.hkdiag.withheld_title") {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    if withheld.pendingDoses > 0 {
                        statRow(label: "settings.hkdiag.withheld_doses", value: "\(withheld.pendingDoses)")
                    }
                    if withheld.backgroundWithoutSession > 0 {
                        statRow(
                            label: "settings.hkdiag.withheld_background_unadmitted",
                            value: "\(withheld.backgroundWithoutSession)"
                        )
                    }
                    if withheld.lockedCount > 0 {
                        statRow(label: "settings.hkdiag.withheld_locked", value: "\(withheld.lockedCount)")
                        ForEach(withheld.lockGroups, id: \.reason) { group in
                            VStack(alignment: .leading, spacing: HLSpace.xs) {
                                Text(verbatim: group.typeNames.formatted(.list(type: .and)))
                                    .hlText(.rowSubtitle)
                                Text(verbatim: SyncDiagnosticsWithheld.note(for: group.reason))
                                    .hlText(.rowSubtitle)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .accessibilityIdentifier("settings.hkdiag.withheld")
        }
    }
}
