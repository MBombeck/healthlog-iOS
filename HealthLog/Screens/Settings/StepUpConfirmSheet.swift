import SwiftUI

/// R2 / #115 A3 — "Confirm it's you" for a record action the server refused
/// with a proof-family 401 (share link, connector token, full or encrypted
/// backup). Hosts the existing ``StepUpArmPicker``; the strength it asks for
/// follows the account, as the server's `requireRecentProof` does: with a
/// second factor only that factor or a passkey, without one any proof.
///
/// The second-factor status is read here when the store has none yet — the
/// record screens never open the 2FA screen that normally loads it. An older
/// or unreachable server leaves every arm on offer; a too-weak proof is then
/// refused by the server and the sheet comes back.
struct StepUpConfirmSheet: View {
    /// Receives the raw elevation token exactly once.
    let onConfirmed: (String) -> Void

    @Environment(AccountSecurityStore.self) private var security
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    Text("stepUp.record.body")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    switch security.twoFactor {
                    case .idle, .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    case .unavailable, .failed, .loaded:
                        StepUpArmPicker(
                            requiresFresh: security.hasSecondFactor,
                            hasTotp: security.isTotpEnabled
                        ) { elevation in
                            guard let proof = elevation.consume() else { return }
                            onConfirmed(proof.token)
                            dismiss()
                        }
                    }
                }
                .padding(HLSpace.lg)
            }
            .navigationTitle("settings.security.twoFactor.stepUp.prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("settings.passkeys.cancel") { dismiss() }
                }
            }
            .task {
                if case .loaded = security.twoFactor { return }
                await security.loadTwoFactor()
            }
        }
        .accessibilityIdentifier("stepUp.record.sheet")
    }
}

extension View {
    /// Presents ``StepUpConfirmSheet`` while `retry` asks for proof, hands the
    /// minted elevation to it, and re-runs the refused action. A `nil` retry
    /// (its store not built yet) presents nothing.
    func stepUpConfirmation(
        _ retry: StepUpRetry?,
        onConfirmed: @escaping @MainActor () async -> Void
    ) -> some View {
        sheet(
            isPresented: Binding(
                get: { retry?.isRequested ?? false },
                set: { presented in
                    if !presented, retry?.isRequested == true { retry?.cancel() }
                }
            )
        ) {
            StepUpConfirmSheet { token in
                retry?.supply(token)
                Task { await onConfirmed() }
            }
        }
    }
}
