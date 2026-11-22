import SwiftUI

/// Apple-Compliance-Surface für Guideline 5.1.1(v): Konto-Löschung muss
/// in-app, easy-to-find und tatsächlich destruktiv sein. Zwei-Stufen-Pattern
/// nach GitHub-Vorlage:
///   1. Erklärungs-Stufe mit Warn-Bullets + Consent-Toggle.
///   2. Type-Confirm-Stufe (User muss `LÖSCHEN` / `DELETE` exakt eintippen).
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
    /// Whether the server erases at once or locks first and
    /// erases after its grace window (1.46.0+). Decides every sentence that
    /// says "irreversible", so the copy is true for both server generations.
    @State private var policy: AccountDeletionPolicy = .initial()

    /// Pro Locale fest: `LÖSCHEN` (DE) bzw. `DELETE` (EN). Exakt und
    /// Case-Sensitive; B5 (1.4): „LOESCHEN“ aus 1.3 gilt weiter
    /// (``DeleteConfirmationPhrase``).
    private var requiredConfirmation: String {
        String(localized: "DELETE", comment: "Type-confirm phrase the user must enter literally to delete their account")
    }

    var body: some View {
        HLPage {
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
        // One title: the bar's, worded by the deletion policy.
        .navigationTitle(headerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isDeleting)
        .task { policy = await authStore.accountDeletionPolicy() }
    }

    // MARK: - Copy by deletion policy

    private var headerTitle: LocalizedStringKey {
        policy.isImmediate ? "Delete account permanently" : "Delete account"
    }

    private var introText: LocalizedStringKey {
        policy.isImmediate ? "If you continue, all your data will be permanently removed from the server:" : "deleteAccount.grace.intro"
    }

    private var consentText: LocalizedStringKey {
        policy.isImmediate ? "I understand that all data will be permanently deleted." : "deleteAccount.grace.consent"
    }

    // MARK: - Step 1

    private var explainStep: some View {
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            Text(introText)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)

            VStack(alignment: .leading, spacing: HLSpace.sm) {
                bullet("All your measurements, insights and medications.")
                bullet("Local caches, tokens and device identifiers will be wiped too.")
                bullet(Text(verbatim: AccountDeletionCopy.deleteFinalLine(policy)))
            }

            // The settings switch row keeps the switch inside the row's edge;
            // the red tint marks the consent to a deletion.
            HLSettingsToggleRow(
                title: consentText,
                description: nil,
                isOn: $consentChecked,
                accessibilityID: Self.consentToggleIdentifier
            )
            .tint(HLColor.statusBad)

            // Destructive stays destructive-coloured: the danger must not
            // read like a benign action.
            HLButton(
                "Continue",
                systemImage: "chevron.right",
                variant: .destructive
            ) {
                step = .typeConfirm
            }
            .disabled(!consentChecked)
            .accessibilityIdentifier(Self.continueButtonIdentifier)
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        bullet(Text(text))
    }

    private func bullet(_ text: Text) -> some View {
        // The dot is set in the text's own font and sits on the first line's
        // baseline, so it stays beside the first line at every text size.
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Text(verbatim: "\u{2022}")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            text
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
        }
    }

    // MARK: - Step 2

    private var typeConfirmStep: some View {
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            Text("Type \(requiredConfirmation) to confirm.")
                .font(.hlBody)
                .foregroundStyle(HLText.primary)

            TextField(requiredConfirmation, text: $typedConfirmation)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .disabled(isDeleting)
                .accessibilityIdentifier(Self.confirmFieldIdentifier)

            HLButtonPair {
                HLButton(
                    "Delete account forever",
                    systemImage: "trash.fill",
                    variant: .destructive,
                    isLoading: isDeleting
                ) {
                    Task { await performDeletion() }
                }
                .disabled(isDeleting || !DeleteConfirmationPhrase.matches(typedConfirmation, required: requiredConfirmation))
                .accessibilityIdentifier(Self.deleteButtonIdentifier)
            } secondary: {
                HLButton(
                    "Back",
                    variant: .secondary
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
        HLCard("deleteAccount.stepUp.title") {
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                Text("deleteAccount.stepUp.body")
                    .hlText(.factLabel)
                    .fixedSize(horizontal: false, vertical: true)
                HLButton(
                    "deleteAccount.stepUp.openButton",
                    systemImage: HLRowIndicator.externalSymbol,
                    variant: .primary
                ) {
                    // Privacy H3 — arm the return-detection probe
                    // BEFORE handing off to the browser. On the next app
                    // foreground `AuthStore.reconcilePendingWebDeletion()` probes
                    // `/api/auth/me`; once the deletion completes on the web the
                    // 401/404 fires the full local `.accountDeleted` wipe so no
                    // PHI survives the MFA web-deletion route.
                    authStore.markPendingWebDeletion()
                    openURL(webURL)
                }
                .accessibilityIdentifier(Self.stepUpOpenButtonIdentifier)
            }
        }
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HLFormErrorText(String(localized: "Deletion failed: \(message)"))
            .font(.hlCaption)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action

    private func performDeletion() async {
        guard DeleteConfirmationPhrase.matches(typedConfirmation, required: requiredConfirmation), !isDeleting else { return }
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
