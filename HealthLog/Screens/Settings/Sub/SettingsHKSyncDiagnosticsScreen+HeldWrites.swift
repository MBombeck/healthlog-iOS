import SwiftUI

// W1 (1.3.0, #126 1.1, HealthLog#1173) — the rows the outbox holds back.
//
// "N Einträge warten auf Verbindung" counts only rows the replay still sends
// on its own (`OutboxQueue.waitingCount(in:)`). The rest is listed here, one
// line per reason, so a parked page or a row over its retry budget is never
// mistaken for a connection problem, and one button sends them all again.

extension SettingsHKSyncDiagnosticsScreen {
    @ViewBuilder
    var heldWritesCard: some View {
        if !heldGroups.isEmpty || rearmedCount != nil {
            // 1.4 B2-c — why these rows wait is in the (i).
            HLSettingsCard(
                icon: "tray.full",
                title: "settings.hkdiag.held_title"
            ) {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(heldGroups, id: \.self) { group in
                        heldRow(group)
                    }
                    if !heldGroups.isEmpty {
                        HLSettingsActionRow(
                            icon: "arrow.clockwise",
                            title: "settings.hkdiag.held_resend",
                            presents: .confirm
                        ) {
                            Task { await rearmHeldWrites() }
                        }
                        .disabled(isRearming)
                        .accessibilityIdentifier("settings.hkdiag.heldResend")
                    }
                    if let rearmedCount {
                        Text(String(localized: "settings.hkdiag.held_resend_result \(rearmedCount)"))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityIdentifier("settings.hkdiag.heldWrites")
        }
    }

    private func heldRow(_ group: OutboxHeldGroup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.heldReasonText(group.reason))
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: HLSpace.md)
            Text("\(group.count)")
                .font(.hlBody.monospacedDigit())
                .foregroundStyle(HLText.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func heldReasonText(_ reason: OutboxHoldReason) -> String {
        switch reason {
        case let .serverRefused(status):
            String(localized: "settings.hkdiag.held_reason_refused \(status)")
        case let .moduleDisabled(module):
            String(localized: "settings.hkdiag.held_reason_module \(module)")
        case .unmappable:
            String(localized: "settings.hkdiag.held_reason_unmappable")
        case .refusalNotRecorded:
            String(localized: "settings.hkdiag.held_reason_not_recorded")
        case .retryBudgetExhausted:
            String(localized: "settings.hkdiag.held_reason_budget")
        }
    }

    func loadHeldWrites() async {
        guard let outbox = container?.outbox else { return }
        heldGroups = await outbox.heldGroups()
    }

    /// Re-arms every held row, then starts one replay pass so they go out now
    /// rather than on the next trigger.
    func rearmHeldWrites() async {
        guard !isRearming, let container else { return }
        isRearming = true
        defer { isRearming = false }
        rearmedCount = await (try? container.outbox.rearmHeld()) ?? 0
        await container.outboxReplay.runOnce()
        await loadHeldWrites()
    }
}
