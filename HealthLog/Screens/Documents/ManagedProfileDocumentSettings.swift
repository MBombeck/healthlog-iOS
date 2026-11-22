import SwiftUI

/// **Automatic reading for a managed profile** (server v1.48.0, #1403,
/// #182 A5). The profile's own switch, `PATCH
/// /api/record-settings/documents` `{ autoAiRead }`: only the guardian acting
/// on a managed profile sees it. Turning it on is the guardian's standing
/// consent for the profile's document reads; the server mints the receipt and
/// reads stored documents in the background where the profile's AI is open.
/// The AI runs on the operator's provider, never on the guardian's own key.
struct ManagedProfileDocumentSettingsSection: View {
    let repository: RecordSettingsRepository

    @State private var isOn = false
    @State private var loaded = false
    @State private var isSaving = false
    @State private var failure: String?

    var body: some View {
        Section {
            HLSettingsToggleRow(
                title: "documents.managed.autoRead.title",
                description: "documents.managed.autoRead.description",
                isOn: Binding(get: { isOn }, set: { newValue in Task { await save(newValue) } }),
                isBusy: isSaving,
                isEnabled: loaded && !isSaving,
                accessibilityID: "documents.managed.autoRead"
            )
            if let failure {
                HLFormErrorText(failure)
            }
        } header: {
            HLSectionHeader("documents.managed.header", rank: .group)
        }
        .hlFormRowSurface()
        .task { await load() }
    }

    private func load() async {
        do {
            isOn = try await repository.documentSettings().autoAiRead
            loaded = true
            failure = nil
        } catch {
            failure = HLError.userFacingText(for: error)
        }
    }

    private func save(_ value: Bool) async {
        let previous = isOn
        isOn = value
        isSaving = true
        defer { isSaving = false }
        do {
            isOn = try await repository.setAutoAiRead(value).autoAiRead
            failure = nil
        } catch {
            isOn = previous
            failure = HLError.userFacingText(for: error)
        }
    }
}

/// Whether the viewer acts as the guardian of a managed profile. Pure.
enum ManagedProfileContext {
    static func isGuardian(_ access: AccountAccess) -> Bool {
        access.active?.isGuardianOfManagedProfile == true
    }
}
