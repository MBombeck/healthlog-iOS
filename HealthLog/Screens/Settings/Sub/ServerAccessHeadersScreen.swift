import SwiftUI

/// Settings › Server › Access headers: edits the extra headers for
/// a server behind a zero-trust proxy (Cloudflare Access, Pangolin or anything
/// that checks a fixed header). The editor itself is
/// `ServerAccessHeadersEditor`, which onboarding shows inline.
///
/// A pushed screen, not a sheet: the row pushes `SettingsRoute.serverAccessHeaders`
/// through `HLSettingsActionRow(presents: .push, value:)`, so it adds no
/// presenter to the frozen Phase-06 presentation census, and the page comes
/// back after the privacy shield. Back discards, Save stores and pops.
///
/// The rows being edited live in the container's
/// `OnboardingDraftStore`, not in view state: the privacy shield rebuilds the
/// window when the user switches to a password manager, and the values typed
/// so far are waiting when the page comes back (SET-ROUTE restores it from the
/// More stack). Back and Save drop the draft.
///
/// Saving validates the list (`ServerAccessHeaders.normalized`), writes it to
/// the Keychain and hands it to the running `APIClient`
/// (`AppContainer.saveAccessHeaders`), so the next request carries it, signed
/// in or not, without a relaunch. The values never leave the device except as
/// headers to the configured server.
struct ServerAccessHeadersScreen: View {
    @Environment(\.appContainer) private var container

    /// Only without a container (previews); otherwise the draft holds the rows.
    @State private var localRows: [ServerAccessHeadersEditor.Row] = []
    @State private var errorText: String?
    /// Depth of the More stack with this page on top, so a disappearance can
    /// tell Back (the stack got shorter) from the privacy shield (it did not).
    @State private var stackDepth: Int?

    private var rows: Binding<[ServerAccessHeadersEditor.Row]> {
        Binding(
            get: { container?.onboardingDraft.settingsAccessHeaderRows ?? localRows },
            set: { newRows in
                if let draft = container?.onboardingDraft {
                    draft.settingsAccessHeaderRows = newRows
                } else {
                    localRows = newRows
                }
            }
        )
    }

    var body: some View {
        HLPage {
            ServerAccessHeadersEditor(rows: rows, onChange: { errorText = nil })
            if let errorText {
                HLFormErrorText(errorText)
                    .accessibilityIdentifier(ServerAccessHeadersEditor.errorIdentifier)
            }
        }
        .navigationTitle("Access headers")
        .navigationBarTitleDisplayMode(.inline)
        // The check mark, as in a sheet: saving goes back on success.
        .hlConfirmBar(.save { await save() }, identifier: "serverAccessHeaders.save")
        .onAppear {
            stackDepth = container?.appRouter.morePath.count
            loadOnce()
        }
        .onDisappear {
            // Back pops the page off the More stack and discards. The privacy
            // shield tears the window down with the stack in the router left
            // as it was, and the draft waits for the restored page (SET-ROUTE:
            // the scene phase is no guide here, the restored stack can drop a
            // stale copy of this page after the scene is active again).
            guard let container, let stackDepth, container.appRouter.morePath.count < stackDepth else { return }
            container.onboardingDraft.settingsAccessHeaderRows = nil
        }
    }

    /// Fills the editor from the Keychain unless a draft is waiting.
    private func loadOnce() {
        guard let container, container.onboardingDraft.settingsAccessHeaderRows == nil else { return }
        container.onboardingDraft.settingsAccessHeaderRows = ServerAccessHeadersEditor.rows(
            from: ServerAccessHeaders.load(keychain: container.keychain)
        )
    }

    /// `true` when the headers are stored and the page may go back.
    @MainActor
    private func save() async -> Bool {
        guard let container else { return false }
        do {
            try await container.saveAccessHeaders(ServerAccessHeadersEditor.headers(from: rows.wrappedValue))
            container.onboardingDraft.settingsAccessHeaderRows = nil
            return true
        } catch {
            errorText = ServerAccessHeadersEditor.saveFailureMessage(for: error)
            return false
        }
    }
}
