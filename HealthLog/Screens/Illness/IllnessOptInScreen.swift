import SwiftUI

/// Re-enable surface for the illness / condition journal. As of v1.18.3 the
/// journal is default-ON, so this screen is reached only when a user explicitly
/// disabled the module and then navigates back in (the journal self-gates).
/// Explains the journal and offers an "Enable" CTA that flips the module back
/// ON via the per-key `PATCH /api/auth/me/modules {illness:true}` (the response
/// echoes the modules map, which `ModuleGate.setEnabled` reconciles into local
/// state).
///
/// There's no reusable `OptInCard` yet, so the explainer is composed inline from
/// `HLCard`.
struct IllnessOptInScreen: View {
    @Environment(\.appContainer) private var container

    /// Called once the module is enabled so the parent can route into the
    /// journal (the `MoreScreen` reconcile row will show after the gate flips,
    /// but this lets the opt-in entry point push straight through).
    var onEnabled: (() -> Void)?

    @State private var isEnabling = false
    @State private var enableError: String?

    /// Bullet glyph column width that grows with the text scale so the icon
    /// doesn't read tiny against the label at large Dynamic Type / AX sizes
    /// (QA D-M3). Scales from the 24pt base.
    @ScaledMetric(relativeTo: .subheadline) private var bulletWidth: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                explainerCard
                bulletsCard
                // UI-Standard R17 (U1) — die Disclaimer-Karte („keine
                // medizinische Beratung") ist entfallen. Sie stand zwölf Zeilen
                // unter dem Bullet „Blickt zurück auf das Geschehene …" und
                // sagte zur Hälfte dasselbe; der Bullet trägt die nützlichere
                // Information und bleibt.
                if let enableError {
                    HLFormErrorText(enableError)
                }
                HLButton("illness.optIn.enable", icon: "checkmark.circle", variant: .primary, isLoading: isEnabling) {
                    Task { await enable() }
                }
                .disabled(isEnabling)
                .accessibilityIdentifier("illness.optIn.enable")
            }
            .padding(HLSpace.lg)
        }
        .hlScreenBackground()
        .navigationTitle(Text("illness.optIn.title"))
        .navigationBarTitleDisplayMode(.large)
    }

    private var explainerCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.md) {
                    Image(systemName: "heart.text.square")
                        .font(.hlTitle1)
                        .foregroundStyle(HLAccent.userBrandTint)
                        .accessibilityHidden(true)
                    Text("illness.optIn.headline")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                }
                Text("illness.optIn.body")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bulletsCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                bullet(icon: "list.bullet.clipboard", text: "illness.optIn.bullet.journal")
                bullet(icon: "waveform.path.ecg", text: "illness.optIn.bullet.correlation")
                bullet(icon: "clock.arrow.circlepath", text: "illness.optIn.bullet.retrospective")
            }
        }
    }

    private func bullet(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: icon)
                .font(.hlSubhead)
                .foregroundStyle(HLAccent.userBrandTint)
                .frame(width: bulletWidth)
                .accessibilityHidden(true)
            Text(text)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func enable() async {
        guard let container else { return }
        isEnabling = true
        enableError = nil
        defer { isEnabling = false }
        let ok = await container.moduleGate.setEnabled(.illness, enabled: true)
        if ok {
            onEnabled?()
        } else {
            enableError = String(localized: "illness.optIn.enableFailed")
        }
    }
}
