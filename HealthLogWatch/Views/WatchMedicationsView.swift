import SwiftUI

/// Today's medication doses — confirm intake from the wrist. Each actionable
/// dose taps to a Genommen / Später / Übersprungen choice that the phone
/// records server-first. Taken doses dim with a check.
struct WatchMedicationsView: View {
    @Environment(WatchConnectivityClient.self) private var client
    @State private var pendingChoice: WatchSnapshot.Dose?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Today")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !client.hasReceived {
            WatchMessageState(title: "Syncing…", systemImage: "arrow.triangle.2.circlepath")
        } else if !client.signedIn {
            WatchMessageState(title: "Sign in on your iPhone", systemImage: "iphone")
        } else {
            List {
                complianceHeader
                if actionableDoses.isEmpty {
                    WatchMessageState(title: "All done", systemImage: "checkmark.circle")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(actionableDoses) { dose in
                        Button { pendingChoice = dose } label: {
                            DoseRow(dose: dose, actionState: client.intakeActions[dose.id])
                        }
                    }
                }
                if !takenDoses.isEmpty {
                    Section("Taken") {
                        ForEach(takenDoses) { dose in
                            DoseRow(dose: dose, takenStyle: true, actionState: client.intakeActions[dose.id])
                        }
                    }
                }
            }
            .confirmationDialog(
                pendingChoice?.medicationName ?? "",
                isPresented: choiceBinding,
                titleVisibility: .visible
            ) {
                if let dose = pendingChoice {
                    Button("Taken") { client.markIntake(dose, status: .taken) }
                    Button("Later") { client.markIntake(dose, status: .snoozed) }
                    Button("Skipped", role: .destructive) { client.markIntake(dose, status: .skipped) }
                }
            }
        }
    }

    /// Today's dose progress — deliberately NOT a compliance percentage. The
    /// phone Compliance Widget paints the multi-day SERVER ledger %; this is a
    /// "Today" surface, so showing a same-looking but today-only "%" here read as
    /// a second, diverging compliance number across glanceable surfaces
    /// (coherence audit C3). The honest today metric is "X von Y genommen"; it
    /// turns green when every dose for today is done (the all-done affordance the
    /// old percentage carried), with no compliance-% claim to drift from.
    private var complianceHeader: some View {
        HStack {
            Text("\(client.snapshot.takenCount) of \(client.snapshot.scheduledCount) taken")
                .font(.hlCaption)
                .foregroundStyle(
                    client.snapshot.scheduledCount > 0 && client.snapshot.complianceFraction >= 1
                        ? LAColor.success : LAColor.textSecondary
                )
            Spacer()
        }
        .listRowBackground(Color.clear)
    }

    /// Actionable = not yet taken/skipped, and not optimistically just-acted.
    private var actionableDoses: [WatchSnapshot.Dose] {
        client.snapshot.doses.filter { $0.isActionable && !client.pendingIntakeIDs.contains($0.id) }
    }

    private var takenDoses: [WatchSnapshot.Dose] {
        client.snapshot.doses.filter { $0.isTaken || client.pendingIntakeIDs.contains($0.id) }
    }

    private var choiceBinding: Binding<Bool> {
        Binding(
            get: { pendingChoice != nil },
            set: { if !$0 { pendingChoice = nil } }
        )
    }
}

private struct DoseRow: View {
    let dose: WatchSnapshot.Dose
    var takenStyle: Bool = false
    /// WW/F2,F6 — the honest state of a watch-originated mark for this dose,
    /// or `nil` if none is in flight.
    var actionState: WatchConnectivityClient.ActionState?

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: takenStyle ? "checkmark.circle.fill" : (dose.isInjection ? "syringe" : "pills"))
                .font(.body)
                .foregroundStyle(takenStyle ? LAColor.success : LAColor.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(dose.medicationName)
                    .font(.hlBody)
                    .foregroundStyle(LAColor.text)
                    .lineLimit(1)
                HStack(spacing: HLSpace.xs) {
                    if !dose.doseText.isEmpty {
                        Text(dose.doseText)
                    }
                    Text(dose.scheduledAt, format: .dateTime.hour().minute())
                    statusLabel
                }
                .font(.hlCaption)
                .foregroundStyle(LAColor.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            statusGlyph
        }
        .opacity(takenStyle ? 0.6 : 1)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch actionState {
        case .queued: Text("· will sync")
        case .failed: Text("· not saved")
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch actionState {
        case .pending:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(LAColor.textSecondary)
                .symbolEffect(.pulse, isActive: true)
        case .queued:
            Image(systemName: "clock.badge.checkmark")
                .font(.caption)
                .foregroundStyle(LAColor.warn)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(LAColor.warn)
        case .saved, .none:
            EmptyView()
        }
    }
}
