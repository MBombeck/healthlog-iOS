import SwiftUI

/// GH-iOS #27 — the presets and the header rows, without any save button.
///
/// Settings › Server shows it in `ServerAccessHeadersScreen`; onboarding unfolds
/// it under "Advanced" below the address card (`ServerURLStep`), sends it with
/// the address check and stores it with the address once the user confirms the
/// host. Both hosts keep the rows in `OnboardingDraftStore` (#153).
struct ServerAccessHeadersEditor: View {
    @Binding var rows: [Row]
    /// Called whenever the list changes, so the host can clear a stale error.
    var onChange: () -> Void = {}

    @State private var showsValues = false

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            presetCard
            headersCard
        }
        .onChange(of: rows) { _, _ in onChange() }
    }

    // MARK: - Cards

    private var presetCard: some View {
        HLSettingsCard(
            icon: "lock.shield",
            title: "Presets",
            subtitle: "Fills in the header names. Paste the values from your proxy."
        ) {
            HLSettingsActionRow(title: "Cloudflare Access", presents: .create) {
                add(.cloudflareAccess)
            }
            .accessibilityIdentifier("serverAccessHeaders.preset.cloudflare")
            HLSettingsActionRow(title: "Pangolin", presents: .create) {
                add(.pangolin)
            }
            .accessibilityIdentifier("serverAccessHeaders.preset.pangolin")
            HLSettingsActionRow(title: "Other header", presents: .create) {
                rows.append(Row(name: "", value: ""))
            }
            .accessibilityIdentifier("serverAccessHeaders.addCustom")
        }
    }

    private var headersCard: some View {
        HLSettingsCard(
            icon: "list.bullet.rectangle",
            title: "Headers",
            footer: "server.accessHeaders.footer"
        ) {
            if rows.isEmpty {
                Text("No headers. Requests go to the server unchanged.")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach($rows) { $row in
                    rowEditor(row: $row)
                }
                HLSettingsToggleRow(
                    title: "Show values",
                    description: nil,
                    isOn: $showsValues,
                    accessibilityID: "serverAccessHeaders.showValues"
                )
            }
        }
    }

    private func rowEditor(row: Binding<Row>) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.sm) {
                TextField("Name", text: row.name)
                    .font(.hlHeadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverAccessHeaders.name")
                Button {
                    rows.removeAll { $0.id == row.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(HLColor.statusBad)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove"))
            }
            Group {
                if showsValues {
                    TextField("Value", text: row.value)
                } else {
                    SecureField("Value", text: row.value)
                        .hlSecretEntry()
                }
            }
            .font(.hlBody)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("serverAccessHeaders.value")
        }
        .padding(HLSpace.md)
        .background(HLSurface.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }

    /// Adds the preset's names that are not there yet, with empty values.
    private func add(_ preset: ServerAccessHeaders.Preset) {
        for name in preset.headerNames
            where !rows.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        {
            rows.append(Row(name: name, value: ""))
        }
    }

    // MARK: - Conversion and messages

    static func rows(from headers: [ServerAccessHeader]) -> [Row] {
        headers.map { Row(name: $0.name, value: $0.value) }
    }

    static func headers(from rows: [Row]) -> [ServerAccessHeader] {
        rows.map { ServerAccessHeader(name: $0.name, value: $0.value) }
    }

    /// Text for a failed `ServerAccessHeaders.save`: the validation reason, or
    /// the Keychain error.
    nonisolated static func saveFailureMessage(for error: Error) -> String {
        if let validation = error as? ServerAccessHeaders.ValidationError {
            return message(for: validation)
        }
        return String(localized: "Couldn't save the headers: \(error.localizedDescription)")
    }

    nonisolated static func message(for error: ServerAccessHeaders.ValidationError) -> String {
        switch error {
        case let .emptyName(index):
            String(localized: "Header \(index + 1) needs a name.")
        case let .invalidName(index):
            String(localized: "Header \(index + 1): use only letters, digits, hyphens, dots and underscores in the name.")
        case let .reservedName(index):
            String(localized: "Header \(index + 1): HealthLog sets this header itself.")
        case let .duplicateName(index):
            String(localized: "Header \(index + 1) appears twice.")
        case let .emptyValue(index):
            String(localized: "Header \(index + 1) needs a value.")
        case let .invalidValue(index):
            String(localized: "Header \(index + 1): the value contains characters that cannot be sent.")
        case .tooMany:
            String(localized: "At most \(ServerAccessHeaders.maximumCount) headers.")
        }
    }
}
