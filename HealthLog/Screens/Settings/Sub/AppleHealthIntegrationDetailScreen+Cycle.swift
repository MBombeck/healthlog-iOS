import SwiftUI

/// Cycle opt-in surface for `AppleHealthIntegrationDetailScreen`, split out of the
/// main file to keep the type under the body-length budget (mirrors the sibling
/// `AppleHealthIntegrationDetailScreen+Import.swift` split). The three-state
/// presentation decision lives in the SwiftUI-free `CycleOptInPresentation`; this
/// extension only renders each mode.
extension AppleHealthIntegrationDetailScreen {
    /// **v0.14.8 C4** — the explicit cycle-tracking opt-in. Flipping it on
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
                        // Build 9 (9.3) — server-synced opt-in: optimistic local +
                        // PATCH cycle-prefs (server mode), then refresh the gate.
                        Task {
                            await container.settingsStore.setCycleTrackingOptIn(newValue)
                            await container.cycleStore.refreshGateLifecycle()
                        }
                    }
                )
            ) {
                Text("settings.cycle.optin.label")
                    .font(.hlSubhead.weight(.semibold))
            }
            .accessibilityIdentifier("HealthAccess.cycleTrackingToggle")
            Text("settings.cycle.optin.footer")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Server-parity v1.16 — one-tap hard purge
            // (`DELETE /api/cycle/all`, the web privacy promise).
            // Server-only: hidden in standalone; visible only while
            // the cycle gate is open (something can exist to purge).
            if backend.hasServer, container.cycleGate.isCycleTrackingAvailable {
                Divider()
                HLSettingsActionRow(
                    icon: "trash",
                    title: "settings.cycle.purge.title",
                    role: .destructive,
                    presents: .confirm
                ) {
                    showCyclePurgeConfirmation = true
                }
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
        .hlConfirmDestructive(
            Text(String(localized: "settings.cycle.purge.confirm.title")),
            isPresented: $showCyclePurgeConfirmation,
            message: Text("settings.cycle.purge.confirm.message"),
            confirm: Text("settings.cycle.purge.title"),
            cancel: Text("Cancel"),
            onCancel: { showCyclePurgeConfirmation = false },
            action: {
                Task { await runCyclePurge() }
            }
        )
    }

    /// **A2 — the neutral cycle-tracking OFFER row** shown when the flag is on but
    /// the gate isn't available. It reads as a question, not a live module, and
    /// only on tap reveals the explainer + the actual opt-in action (which flips
    /// `cycleTrackingOptIn` and refreshes the gate — the SAME store call as the
    /// toggle, so the next render promotes this into the real toggle). Wording +
    /// form are operator-approved (b244 follow-up).
    func cycleOfferRow(container: AppContainer) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Button {
                withAnimation { showCycleOfferExplainer.toggle() }
            } label: {
                HStack(spacing: HLSpace.sm) {
                    Text("settings.cycle.optin.offer.title")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: HLSpace.sm)
                    Image(systemName: showCycleOfferExplainer ? "chevron.up" : "chevron.down")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("HealthAccess.cycleTrackingOffer")

            if showCycleOfferExplainer {
                Text("settings.cycle.optin.offer.body")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                // R9 — nachgeordnete Vollbreiten-Aktion; das `.primary` dieses
                // Screens ist „Mit Apple Health verbinden".
                HLButton(String(localized: "settings.cycle.optin.offer.confirm"), variant: .secondary) {
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
