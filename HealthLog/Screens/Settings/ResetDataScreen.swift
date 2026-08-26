import SwiftUI

/// Settings → Account → "Reset health data" (parity item 2.5). Web ref
/// `advanced-section.tsx:277-325`.
///
/// The gap this closes: iOS offered only full account deletion, so "wipe my
/// health data but keep my login" was impossible from the app. This is the
/// non-terminal destructive action — the account, credentials, passkeys and
/// sessions survive; the health record does not.
///
/// **Why the confirm is stricter than the web's.** The web ships a single
/// AlertDialog and hardcodes `confirm: "DELETE"` in its own handler
/// (`advanced-section.tsx:230-234`) — the user never types anything. iOS
/// deliberately reuses the two-stage `DeleteAccountScreen` pattern (explain +
/// consent toggle, then type-to-confirm) instead: it is the stricter idiom, it
/// is already the app's established vocabulary for irreversible destruction, and
/// a one-tap wipe of a user's entire health record on a device that lives in a
/// pocket is a materially different risk than the same tap on a desktop. This is
/// an intentional non-parity, not an oversight.
///
/// The typed phrase is the LOCALIZED word; the wire value is always the ASCII
/// `"DELETE"` the server demands (see `AccountDataResetBody`).
struct ResetDataScreen: View {
    private enum Step {
        case explain
        case typeConfirm
    }

    @Environment(\.appContainer) private var container
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .explain
    @State private var consentChecked: Bool = false
    @State private var typedConfirmation: String = ""
    @State private var isResetting: Bool = false
    @State private var resetError: String?
    @State private var didSucceed: Bool = false
    /// Non-nil ⇒ the server demanded a fresh-MFA step-up this native session
    /// structurally cannot satisfy. Renders the web-routing card instead of a
    /// retry banner, mirroring `DeleteAccountScreen.stepUpWebURL`.
    @State private var stepUpWebURL: URL?

    /// Per-locale fixed: `LÖSCHEN` (DE) / `DELETE` (EN). Same key the account
    /// deletion screen uses, so the app has exactly one type-confirm vocabulary.
    private var requiredConfirmation: String {
        String(localized: "DELETE", comment: "Type-confirm phrase the user must enter literally to delete their account")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                header
                if didSucceed {
                    successCard
                } else if let webURL = stepUpWebURL {
                    stepUpCard(webURL)
                } else if step == .explain {
                    explainStep
                } else {
                    typeConfirmStep
                }
                if !didSucceed, stepUpWebURL == nil, let error = resetError {
                    errorBanner(error)
                }
            }
            .padding(HLSpace.lg)
        }
        .background(HLColor.background)
        .hlScrollEdgeSoft()
        .navigationTitle("resetData.navTitle")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isResetting)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.hlIcon(HLIconSize.display, weight: .bold))
                .foregroundStyle(HLColor.statusBad)
            Text("resetData.title")
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step 1

    private var explainStep: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            Text("resetData.explain.intro")
                .font(.hlBody)
                .foregroundStyle(HLText.primary)

            VStack(alignment: .leading, spacing: HLSpace.sm) {
                bullet("resetData.explain.bullet.health")
                bullet("resetData.explain.bullet.tokens")
                bullet("resetData.explain.bullet.irreversible")
            }

            // The distinguishing promise of this screen vs. account deletion.
            // Stated positively and separately so it cannot be missed.
            Text("resetData.explain.keepsAccount")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $consentChecked) {
                Text("resetData.explain.consent")
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
            }
            .toggleStyle(.switch)
            .tint(HLColor.statusBad)
            .accessibilityIdentifier(Self.consentToggleIdentifier)

            VStack(spacing: HLSpace.sm) {
                HLButton(
                    String(localized: "Continue"),
                    icon: "chevron.right",
                    variant: .destructive,
                    size: .compact
                ) {
                    step = .typeConfirm
                }
                .disabled(!consentChecked)
                .accessibilityIdentifier(Self.continueButtonIdentifier)

                HLButton(String(localized: "Cancel"), variant: .secondary, size: .regular) {
                    dismiss()
                }
            }
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "circle.fill")
                // 6pt list-marker dot — same micro-geometry as DeleteAccountScreen.
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 6))
                .foregroundStyle(HLText.secondary)
                .padding(.top, HLSpace.sm)
            Text(text)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
        }
    }

    // MARK: - Step 2

    private var typeConfirmStep: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            Text("Type \(requiredConfirmation) to confirm.")
                .font(.hlBody)
                .foregroundStyle(HLText.primary)

            TextField(requiredConfirmation, text: $typedConfirmation)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .disabled(isResetting)
                .accessibilityIdentifier(Self.confirmFieldIdentifier)

            VStack(spacing: HLSpace.sm) {
                HLButton(
                    String(localized: "resetData.confirmAction"),
                    icon: "trash.fill",
                    variant: .destructive,
                    size: .compact,
                    isLoading: isResetting
                ) {
                    Task { await performReset() }
                }
                .disabled(isResetting || typedConfirmation != requiredConfirmation)
                .accessibilityIdentifier(Self.resetButtonIdentifier)

                HLButton(String(localized: "Back"), variant: .secondary, size: .regular) {
                    resetError = nil
                    typedConfirmation = ""
                    step = .explain
                }
                .disabled(isResetting)
            }
        }
    }

    // MARK: - Success

    /// The account survives, so unlike account deletion there is no shell swap
    /// to signal completion — the screen must confirm the outcome itself.
    private var successCard: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.hlIcon(HLIconSize.md, weight: .semibold))
                    .foregroundStyle(HLColor.statusOK)
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("resetData.success.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("resetData.success.body")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HLButton(String(localized: "Done"), variant: .primary, size: .compact) {
                dismiss()
            }
            .accessibilityIdentifier(Self.doneButtonIdentifier)
        }
        .padding(HLSpace.md)
        .background(HLColor.statusOK.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }

    // MARK: - Step-up (web) routing card

    /// Shown when the account is MFA-enrolled and the server requires a
    /// fresh-MFA step-up the native Bearer session cannot satisfy. Same
    /// structure and rationale as `DeleteAccountScreen.stepUpCard`; the
    /// destination is the web *data* surface rather than the account page.
    ///
    /// No `markPendingWebDeletion()` here — that probe exists to detect an
    /// account that vanished while the user was in Safari. This action leaves
    /// the account intact, so there is nothing to reconcile; the user simply
    /// pulls to refresh when they come back.
    private func stepUpCard(_ webURL: URL) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "lock.shield.fill")
                    // 20pt informational shield — calm, not the danger hero.
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HLAccent.userBrandTint)
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("resetData.stepUp.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("resetData.stepUp.body")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: HLSpace.sm) {
                HLButton(
                    String(localized: "resetData.stepUp.openButton"),
                    icon: "safari",
                    variant: .primary,
                    size: .compact
                ) {
                    openURL(webURL)
                }
                .accessibilityIdentifier(Self.stepUpOpenButtonIdentifier)

                HLButton(String(localized: "Cancel"), variant: .secondary, size: .regular) {
                    dismiss()
                }
            }
        }
        .padding(HLSpace.md)
        .background(HLAccent.userBrandTint.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(HLColor.statusBad)
            Text("resetData.failed \(message)")
                .font(.hlCaption)
                .foregroundStyle(HLText.primary)
        }
        .padding(HLSpace.md)
        .background(HLColor.statusBad.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }

    // MARK: - Action

    private func performReset() async {
        guard typedConfirmation == requiredConfirmation, !isResetting else { return }
        guard let container else { return }
        isResetting = true
        resetError = nil
        defer { isResetting = false }
        do {
            try await container.accountDataResetRepo.resetAllData()
            // The server wiped the record; drop every in-process cache so the
            // app does not keep painting data that no longer exists. Reuses the
            // account-deletion cleanup hook — same local-wipe semantics, minus
            // the sign-out (the account survives).
            await container.wipeLocalDataAfterServerReset()
            didSucceed = true
        } catch let err as HLError {
            if err.isMfaStepUpRequired {
                stepUpWebURL = container.environment.baseURL?.appendingPathComponent("/settings/data")
                return
            }
            resetError = err.localizedDescription
        } catch {
            resetError = String(localized: "Unknown error")
        }
    }

    // MARK: - AccessibilityIdentifiers

    static let consentToggleIdentifier = "resetData.consentToggle"
    static let continueButtonIdentifier = "resetData.continueButton"
    static let confirmFieldIdentifier = "resetData.confirmField"
    static let resetButtonIdentifier = "resetData.resetButton"
    static let doneButtonIdentifier = "resetData.doneButton"
    static let stepUpOpenButtonIdentifier = "resetData.stepUpOpenButton"
}
