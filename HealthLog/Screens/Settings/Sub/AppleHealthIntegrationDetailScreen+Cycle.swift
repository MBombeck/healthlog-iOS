import SwiftUI

/// Cycle opt-in surface for `AppleHealthIntegrationDetailScreen`, split out of the
/// main file to keep the type under the body-length budget (mirrors the sibling
/// `AppleHealthIntegrationDetailScreen+Import.swift` split). The three-state
/// presentation decision lives in the SwiftUI-free `CycleOptInPresentation`; this
/// extension only renders each mode.
extension AppleHealthIntegrationDetailScreen {
    /// The explicit cycle-tracking opt-in. Flipping it on
    /// force-enables the `CycleGate` (covers trans / non-binary / "other"
    /// users AND lets the operator self-test on a non-female account), starts
    /// the C2 HealthKit importer, and surfaces the gated `.cycle` row under
    /// "Erfassen".
    func cycleTrackingToggle(container: AppContainer) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Toggle(
                isOn: Binding(
                    get: { container.settingsStore.cycleTrackingOptIn },
                    set: { newValue in
                        // Server-synced opt-in: optimistic local +
                        // PATCH cycle-prefs (server mode), then refresh the gate.
                        Task {
                            await container.settingsStore.setCycleTrackingOptIn(newValue)
                            await container.cycleStore.refreshGateLifecycle()
                        }
                    }
                )
            ) {
                HLRowTitle("settings.cycle.optin.label")
            }
            .accessibilityIdentifier("HealthAccess.cycleTrackingToggle")
            Text("settings.cycle.optin.footer")
                .hlText(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            // Server-parity v1.16 — one-tap hard purge
            // (`DELETE /api/cycle/all`, the web privacy promise).
            // Visible only while the cycle gate is open (something can exist to purge).
            if container.cycleGate.isCycleTrackingAvailable {
                HLDeleteButton(
                    "settings.cycle.purge.title",
                    form: .row,
                    action: .confirmed(
                        title: "settings.cycle.purge.confirm.title",
                        message: "settings.cycle.purge.confirm.message"
                    ) {
                        await runCyclePurge()
                    }
                )
                .disabled(cyclePurgeState == .running)
                .accessibilityIdentifier("HealthAccess.cyclePurgeRow")

                switch cyclePurgeState {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView().controlSize(.mini)
                case .done:
                    Label(String(localized: "settings.cycle.purge.done"), systemImage: "checkmark.circle.fill")
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusOK)
                case .failed:
                    Label(
                        String(localized: "settings.cycle.purge.failed"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.hlFootnote)
                    .foregroundStyle(HLColor.statusBad)
                }
            }
        }
    }

    /// **The neutral cycle-tracking OFFER row** shown when the flag is on but
    /// the gate isn't available. It reads as a question, not a live module, and
    /// only on tap reveals the explainer + the actual opt-in action (which flips
    /// `cycleTrackingOptIn` and refreshes the gate — the SAME store call as the
    /// toggle, so the next render promotes this into the real toggle). Wording +
    /// form are operator-approved (b244 follow-up).
    func cycleOfferRow(container: AppContainer) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLRowButton {
                withAnimation { showCycleOfferExplainer.toggle() }
            } label: {
                HLRow("settings.cycle.optin.offer.title", accessory: .expand(showCycleOfferExplainer))
            }
            .accessibilityIdentifier("HealthAccess.cycleTrackingOffer")

            if showCycleOfferExplainer {
                // What turning it on does, the toggle's own line;
                // "optional, switch it off anytime" is gone.
                Text("settings.cycle.optin.footer")
                    .hlText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                // Nachgeordnete Vollbreiten-Aktion; das `.primary` dieses
                // Screens ist „Mit Apple Health verbinden".
                HLButton("settings.cycle.optin.offer.confirm", variant: .secondary) {
                    Task {
                        await container.settingsStore.setCycleTrackingOptIn(true)
                        await container.cycleStore.refreshGateLifecycle()
                    }
                }
                .accessibilityIdentifier("HealthAccess.cycleTrackingOfferConfirm")
            }
        }
    }

    /// Runs the server purge through the cycle store; drives the inline
    /// progress/result footnote.
    func runCyclePurge() async {
        guard let container else { return }
        cyclePurgeState = .running
        let ok = await container.cycleStore.purgeAll()
        cyclePurgeState = ok ? .done : .failed
    }
}
