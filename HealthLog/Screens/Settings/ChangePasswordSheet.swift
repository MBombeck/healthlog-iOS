import SwiftUI

/// Change-password sheet — the iOS counterpart of the web dialog
/// (`settings/account-section/index.tsx:503-581`).
///
/// Mirrors the web's message model deliberately: **one** inline row, replaced on
/// every submit, rendered in place. Success keeps the sheet open with the fields
/// emptied rather than dismissing, because the server ends every other session
/// on success and the user should read that consequence before leaving.
struct ChangePasswordSheet: View {
    @Environment(AccountSecurityStore.self) private var store
    @Environment(\.appContainer) private var container
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var current: String = ""
    @State private var newPassword: String = ""
    @State private var confirm: String = ""
    @FocusState private var currentFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    fields
                    outcomeRow
                    submitButton
                }
                .padding(HLSpace.lg)
            }
            .navigationTitle("settings.security.password.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("settings.passkeys.cancel") { dismiss() }
                }
            }
            .onAppear { currentFocused = true }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            labelledField("settings.security.password.current", text: $current, isNew: false)
                .focused($currentFocused)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                labelledField("settings.security.password.new", text: $newPassword, isNew: true)
                Text("settings.security.password.hint")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            labelledField("settings.security.password.confirm", text: $confirm, isNew: true)
        }
    }

    /// `isNew` selects the content type without naming `UITextContentType` in a
    /// signature — keeps the file free of a UIKit import (PROJECT_GUIDE.md: no UIKit
    /// unless Apple forces it) while still giving the keychain the right hint.
    private func labelledField(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        isNew: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(label)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            SecureField("", text: text)
                .textContentType(isNew ? .newPassword : .password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.hlBody)
                .padding(HLSpace.md)
                .background(HLColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                // Editing after a failure clears the stale message so the user
                // is never reading an error about the text they just replaced.
                .onChange(of: text.wrappedValue) { _, _ in
                    if store.outcome != nil { store.clearOutcome() }
                }
        }
    }

    @ViewBuilder
    private var outcomeRow: some View {
        if let outcome = store.outcome {
            outcomeBody(outcome)
        }
    }

    @ViewBuilder
    private func outcomeBody(_ outcome: ChangePasswordOutcome) -> some View {
        switch outcome {
        case .success:
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("settings.security.password.updated")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLColor.statusOK)
                Text("settings.security.password.otherSessionsEnded")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
            .accessibilityIdentifier("security.password.success")
        case let .validation(failure):
            message(failure == .mismatch
                ? "settings.security.password.mismatch"
                : "settings.security.password.incomplete")
        case .stepUpRequired:
            // The honest wall: the server needs a fresh second-factor
            // confirmation that a Bearer client structurally cannot produce.
            // R4 (privacy-review) — der Text nannte bisher den Ort, an dem es
            // geht, ohne hinzuführen. Die Aussage bleibt, der letzte Halbsatz
            // wird die Zeile darunter.
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("settings.security.stepUp.title")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Text("settings.security.stepUp.body")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
            .accessibilityIdentifier("security.password.stepUp")
            HLSettingsActionRow(
                title: "settings.security.stepUp.openWeb",
                presents: .external
            ) {
                // Ohne eingerichteten Server gibt es keine Kontoflaeche zu oeffnen.
                if let url = AccountSecurityWebLink.url(keychain: container?.keychain) {
                    openURL(url)
                }
            }
            .accessibilityIdentifier("security.password.stepUpLink")
        case let .failure(text):
            // Server prose, verbatim — it is written for the end user and is
            // more specific than any substitute we could offer.
            Text(verbatim: text)
                .font(.hlSubhead)
                .foregroundStyle(HLColor.statusBad)
                .accessibilityIdentifier("security.password.error")
        }
    }

    private func message(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.hlSubhead)
            .foregroundStyle(HLColor.statusBad)
            .accessibilityIdentifier("security.password.error")
    }

    private var submitButton: some View {
        HLButton(
            String(localized: "settings.security.password.submit"),
            variant: .primary,
            isLoading: store.isSaving,
            action: { Task { await submit() } }
        )
        .disabled(store.isSaving)
        .accessibilityIdentifier("security.password.submit")
    }

    private func submit() async {
        await store.changePassword(current: current, new: newPassword, confirm: confirm)
        if store.outcome == .success {
            current = ""
            newPassword = ""
            confirm = ""
        }
    }
}
