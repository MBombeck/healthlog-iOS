import SwiftUI

/// GH-iOS #27 — Settings › Server › Access headers: edits the extra headers for
/// a server behind a zero-trust proxy (Cloudflare Access, Pangolin or anything
/// that checks a fixed header). The editor itself is
/// `ServerAccessHeadersEditor`, which onboarding shows inline.
///
/// A pushed screen, not a sheet: the row pushes `SettingsRoute.serverAccessHeaders`
/// through `HLSettingsActionRow(presents: .push, value:)`, so it adds no
/// presenter to the frozen Phase-06 presentation census, and the page comes
/// back after the privacy shield (SET-ROUTE). Back discards, Save stores and pops.
///
/// #153 — the rows being edited live in the container's
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
    @Environment(\.dismiss) private var dismiss

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
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                ServerAccessHeadersEditor(rows: rows, onChange: { errorText = nil })
                if let errorText {
                    ServerAccessHeadersErrorLine(text: errorText)
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.md)
            .padding(.bottom, HLSpace.xxxl)
        }
        .background(HLSurface.primary)
        .navigationTitle("Access headers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("serverAccessHeaders.save")
            }
        }
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

    @MainActor
    private func save() async {
        guard let container else { return }
        do {
            try await container.saveAccessHeaders(ServerAccessHeadersEditor.headers(from: rows.wrappedValue))
            container.onboardingDraft.settingsAccessHeaderRows = nil
            dismiss()
        } catch {
            errorText = ServerAccessHeadersEditor.saveFailureMessage(for: error)
        }
    }
}

/// The one-line validation error under the editor, shared by the Settings screen
/// and onboarding.
struct ServerAccessHeadersErrorLine: View {
    let text: String

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HLColor.statusBad)
            Text(text)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("serverAccessHeaders.error")
    }
}
