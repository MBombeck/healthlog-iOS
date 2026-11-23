import SwiftUI

/// Create or edit a custom mood tag. Label, icon, and group map directly to
/// the v1.17 custom-tag POST/PATCH contracts. The server remains authoritative
/// for ownership, limits, and validation errors.
struct MoodTagEditSheet: View {
    enum Mode {
        case create
        case edit(MoodTagDTO)
    }

    let mode: Mode

    @Environment(MoodTagManagementStore.self) private var store

    @State private var label: String = ""
    @State private var selectedIcon: String = MoodTagCatalog.customIconAllowList.first ?? "Tag"
    @State private var selectedGroupKey: String = ""
    /// Initial focus onto the label field.
    @FocusState private var labelFocused: Bool
    /// The fields as the sheet opened, for the question before discarding.
    @State private var seeded = (label: "", icon: "", group: "")

    /// 1–40 char client guard (mirrors the server) — disables submit early so a
    /// trivially-invalid label never round-trips. The 50-cap / bad-icon checks
    /// are server-authoritative and surface as a 422.
    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isLabelValid: Bool {
        let count = trimmedLabel.count
        return count >= 1 && count <= 40
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private let iconColumns = [GridItem(.adaptive(minimum: 52, maximum: 64), spacing: HLSpace.sm)]

    var body: some View {
        HLSheetScaffold(
            isEditing ? "mood.tags.edit.titleEdit" : "mood.tags.edit.titleCreate",
            size: .standard,
            action: confirmAction,
            isDirty: label != seeded.label || selectedIcon != seeded.icon || selectedGroupKey != seeded.group
        ) {
            HLPage {
                labelCard
                iconCard
                if let error = store.mutationError {
                    Text(error.userFacingDescription)
                        .font(.hlSubhead)
                        .foregroundStyle(HLColor.statusBad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mood.tags.edit.error")
                }
            }
            .onAppear(perform: seed)
            // Seed focus onto the label field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                labelFocused = true
            }
        }
    }

    /// Creating a tag adds it; editing one keeps the change.
    private var confirmAction: HLSheetAction {
        let isEnabled = isLabelValid && !selectedGroupKey.isEmpty
        return isEditing
            ? .save(isEnabled: isEnabled) { await save() }
            : .add(isEnabled: isEnabled) { await save() }
    }

    private var labelCard: some View {
        // The length rule shows only when the name breaks it (the
        // save button is disabled then); an empty field needs no sentence.
        HLCard(
            "mood.tags.edit.label.title",
            footer: trimmedLabel.count > 40 ? "mood.tags.edit.label.footer" : nil
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                TextField(String(localized: "mood.tags.edit.label.placeholder"), text: $label)
                    .textFieldStyle(.plain)
                    .focused($labelFocused)
                    .submitLabel(.done)
                    .font(.hlBody)
                    .padding(HLSpace.md)
                    .background(HLSurface.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                    .onChange(of: label) { _, _ in store.clearMutationError() }
                    .accessibilityIdentifier("mood.tags.edit.label.field")

                Picker(selection: $selectedGroupKey) {
                    ForEach(store.groups) { group in
                        Text(group.localizedLabel).tag(group.key)
                    }
                } label: {
                    HLRowTitle("mood.tags.edit.group")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("mood.tags.edit.group")
            }
        }
    }

    private var iconCard: some View {
        HLCard("mood.tags.edit.icon.title") {
            LazyVGrid(columns: iconColumns, spacing: HLSpace.sm) {
                ForEach(MoodTagCatalog.customIconAllowList, id: \.self) { icon in
                    iconTile(icon)
                }
            }
        }
    }

    private func iconTile(_ icon: String) -> some View {
        let isSelected = selectedIcon == icon
        return Button {
            selectedIcon = icon
        } label: {
            Image(systemName: MoodTagSFSymbol.symbolForAllowListIcon(icon))
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.primary))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(HLSurface.tertiary))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                        .stroke(
                            isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.tertiary.opacity(0.18)),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.hlRow)
        .accessibilityLabel(Text(verbatim: MoodTagIconName.label(for: icon)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("mood.tags.edit.icon.\(icon)")
    }

    private func seed() {
        switch mode {
        case .create:
            selectedGroupKey = store.groups.first(where: {
                $0.key == MoodTagCatalog.customCategoryKey
            })?.key ?? store.groups.first?.key ?? ""
        case let .edit(tag):
            label = tag.localizedLabel
            if let icon = tag.icon, MoodTagCatalog.customIconAllowList.contains(icon) {
                selectedIcon = icon
            }
            selectedGroupKey = store.groups.first(where: {
                $0.tags.contains { $0.key == tag.key }
            })?.key ?? store.groups.first?.key ?? ""
        }
        seeded = (label, selectedIcon, selectedGroupKey)
    }

    /// `true` closes the sheet; a server error stays on the page.
    private func save() async -> Bool {
        guard !selectedGroupKey.isEmpty else { return false }
        return switch mode {
        case .create:
            await store.createCustom(
                label: trimmedLabel,
                icon: selectedIcon,
                categoryKey: selectedGroupKey
            )
        case let .edit(tag):
            await store.updateCustom(
                key: tag.key,
                label: trimmedLabel,
                icon: selectedIcon,
                categoryKey: selectedGroupKey
            )
        }
    }
}
