import SwiftUI

/// Apple-Compliance-Surface für Guideline 5.1.1(v): Konto-Löschung muss
/// in-app, easy-to-find und tatsächlich destruktiv sein. Zwei-Stufen-Pattern
/// nach GitHub-Vorlage:
///   1. Erklärungs-Stufe mit Warn-Bullets + Consent-Toggle.
///   2. Type-Confirm-Stufe (User muss `LOESCHEN` / `DELETE` exakt eintippen).
/// Der finale Tap löst `AuthStore.deleteAccount` aus, das den Server-DELETE,
/// den Keychain-Wipe und die Store-/Outbox-Cleanup-Cascade orchestriert.
///
/// Diese Surface ist bewusst NICHT Debug-only: Compliance-Verhalten ist
/// build-config-unabhängig (App Review testet Production-Build).
struct DeleteAccountScreen: View {
    private enum Step {
        case explain
        case typeConfirm
    }

    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .explain
    @State private var consentChecked: Bool = false
    @State private var typedConfirmation: String = ""
    @State private var isDeleting: Bool = false
    @State private var deletionError: String?
    /// #37/#38 — set when the server 401s with `auth.stepup.required`: an
    /// MFA-enrolled account can only be deleted after a fresh-MFA step-up, which
    /// is cookie-only and thus web-first. Non-nil ⇒ render the web-routing card
    /// (the destructive in-app path cannot complete) instead of a retry banner.
    @State private var stepUpWebURL: URL?

    /// Pro Locale fest: `LOESCHEN` (DE) bzw. `DELETE` (EN). Wir lesen die
    /// localized String einmal und vergleichen exakt — Case-Sensitive,
    /// damit der User nicht versehentlich durchklickt.
    private var requiredConfirmation: String {
        String(localized: "DELETE", comment: "Type-confirm phrase the user must enter literally to delete their account")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                header
                if let webURL = stepUpWebURL {
                    stepUpCard(webURL)
                } else if step == .explain {
                    explainStep
                } else {
                    typeConfirmStep
                }
                if stepUpWebURL == nil, let error = deletionError {
                    errorBanner(error)
                }
            }
            .padding(HLSpace.lg)
        }
        .background(HLColor.background)
        // W3b B3 — iOS 26+ soft scroll-edge (no-op on iOS 18-25).
        .hlScrollEdgeSoft()
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isDeleting)
    }

    // MARK: - Header

    private var header: some View {
        // T2-4: destructive header kept (red explicitly sanctioned by HIG
        // for irreversible actions — exception to Theme-2.0 accent-restraint).
        // Glyph 36→32pt so it sits closer to the title weight, removes a
        // touch of visual shouting without losing the danger signal.
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                // Danger hero glyph on the canonical display scale (audit-01 H2
                // pulled the one-off 32pt onto `HLIconSize.display`). Signal
                // colour is sanctioned — this IS a destructive-action warning.
                .font(.hlIcon(HLIconSize.display, weight: .bold))
                .foregroundStyle(HLColor.statusBad)
            Text("Delete account permanently")
                .font(.hlTitle2)
                .foregroundStyle(HLText.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step 1

    private var explainStep: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            Text("If you continue, all your data will be permanently removed from the server:")
                .font(.hlBody)
                .foregroundStyle(HLText.primary)

            VStack(alignment: .leading, spacing: HLSpace.sm) {
                bullet("All your measurements, insights and medications.")
                bullet("Local caches, tokens and device identifiers will be wiped too.")
                bullet("This action cannot be undone.")
            }

            Toggle(isOn: $consentChecked) {
                Text("I understand that all data will be permanently deleted.")
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
            }
            .toggleStyle(.switch)
            .tint(HLColor.statusBad)
            .accessibilityIdentifier(Self.consentToggleIdentifier)

            VStack(spacing: HLSpace.sm) {
                // W-BUTTONS: destructive STAYS destructive-coloured (danger
                // semantic must not flatten to a benign action) — only the
                // SIZE drops from the `.large` slab to the restrained compact
                // 44pt floor, matching the app-wide button-size pass.
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

                HLButton(
                    String(localized: "Cancel"),
                    variant: .secondary,
                    size: .regular
                ) {
                    dismiss()
                }
            }
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "circle.fill")
                // 6pt bullet dot — micro list-marker geometry, fixed by design.
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
                .disabled(isDeleting)
                .accessibilityIdentifier(Self.confirmFieldIdentifier)

            VStack(spacing: HLSpace.sm) {
                HLButton(
                    String(localized: "Delete account forever"),
                    icon: "trash.fill",
                    variant: .destructive,
                    size: .compact,
                    isLoading: isDeleting
                ) {
                    Task { await performDeletion() }
                }
                .disabled(isDeleting || typedConfirmation != requiredConfirmation)
                .accessibilityIdentifier(Self.deleteButtonIdentifier)

                HLButton(
                    String(localized: "Back"),
                    variant: .secondary,
                    size: .regular
                ) {
                    deletionError = nil
                    typedConfirmation = ""
                    step = .explain
                }
                .disabled(isDeleting)
            }
        }
    }

    // MARK: - Step-up (web deletion) routing card

    /// #37/#38 — shown when the account is MFA-enrolled and the server requires a
    /// fresh-MFA step-up the native session cannot satisfy. Explains why the
    /// deletion must finish on the web and deep-links to the web account page.
    private func stepUpCard(_ webURL: URL) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "lock.shield.fill")
                    // 20pt informational shield — calm, not the danger hero.
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HLAccent.userBrandTint)
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("deleteAccount.stepUp.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("deleteAccount.stepUp.body")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: HLSpace.sm) {
                HLButton(
                    String(localized: "deleteAccount.stepUp.openButton"),
                    icon: "safari",
                    variant: .primary,
                    size: .compact
                ) {
                    // Privacy H3 (audit-v0162) — arm the return-detection probe
                    // BEFORE handing off to the browser. On the next app
                    // foreground `AuthStore.reconcilePendingWebDeletion()` probes
                    // `/api/auth/me`; once the deletion completes on the web the
                    // 401/404 fires the full local `.accountDeleted` wipe so no
                    // PHI survives the MFA web-deletion route.
                    authStore.markPendingWebDeletion()
                    openURL(webURL)
                }
                .accessibilityIdentifier(Self.stepUpOpenButtonIdentifier)

                HLButton(
                    String(localized: "Cancel"),
                    variant: .secondary,
                    size: .regular
                ) {
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
            Text("Deletion failed: \(message)")
                .font(.hlCaption)
                .foregroundStyle(HLText.primary)
        }
        .padding(HLSpace.md)
        .background(HLColor.statusBad.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }

    // MARK: - Action

    private func performDeletion() async {
        guard typedConfirmation == requiredConfirmation, !isDeleting else { return }
        isDeleting = true
        deletionError = nil
        let ok = await authStore.deleteAccount()
        isDeleting = false
        if ok {
            // RootView reagiert auf den Phase-Wechsel und zeigt OnboardingFlow.
            // Wir müssen nichts dismiss-en — der gesamte Settings-Stack
            // verschwindet automatisch mit dem Shell-Wechsel.
            return
        }
        // #37/#38 — MFA-enrolled: the server demands a cookie-only fresh-MFA
        // step-up the native Bearer session cannot satisfy (`401
        // auth.stepup.required`). Route to the web deletion page instead of
        // showing a misleading generic error.
        if authStore.lastError?.isMfaStepUpRequired == true {
            stepUpWebURL = container?.environment.baseURL?.appendingPathComponent("/settings/account")
            return
        }
        let raw = authStore.lastError?.localizedDescription ?? String(localized: "Unknown error")
        deletionError = raw
    }

    // MARK: - AccessibilityIdentifiers

    static let consentToggleIdentifier = "deleteAccount.consentToggle"
    static let continueButtonIdentifier = "deleteAccount.continueButton"
    static let confirmFieldIdentifier = "deleteAccount.confirmField"
    static let deleteButtonIdentifier = "deleteAccount.deleteButton"
    static let stepUpOpenButtonIdentifier = "deleteAccount.stepUpOpenButton"
}
