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
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var selectedIcon: String = MoodTagCatalog.customIconAllowList.first ?? "Tag"
    @State private var selectedGroupKey: String = ""
    /// FORM-2 (Audit v0162) — initial focus onto the label field.
    @FocusState private var labelFocused: Bool

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
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HLSpace.lg) {
                    labelCard
                    iconCard
                    if let error = store.mutationError {
                        Text(error.userFacingDescription)
                            .font(.hlSubhead)
                            .foregroundStyle(HLColor.statusBad)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("mood.tags.edit.error")
                    }
                    HLButton(
                        String(localized: isEditing ? "Save" : "mood.tags.edit.create"),
                        variant: .primary,
                        isLoading: store.isMutating
                    ) {
                        Task { await save() }
                    }
                    .disabled(!isLabelValid || selectedGroupKey.isEmpty || store.isMutating)
                    .accessibilityIdentifier("mood.tags.edit.save")
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.md)
                .padding(.bottom, HLSpace.xxxl)
            }
            .scrollContentBackground(.hidden)
            .background(HLSurface.primary)
            .navigationTitle(Text(isEditing ? "mood.tags.edit.titleEdit" : "mood.tags.edit.titleCreate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .onAppear(perform: seed)
            // FORM-2 — seed focus onto the label field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                labelFocused = true
            }
        }
        .hlSheetPresentation(.standard)
    }

    private var labelCard: some View {
        HLSettingsCard(
            icon: "tag",
            title: "mood.tags.edit.label.title",
            footer: "mood.tags.edit.label.footer"
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

                Picker("mood.tags.edit.group", selection: $selectedGroupKey) {
                    ForEach(store.groups) { group in
                        Text(group.localizedLabel).tag(group.key)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("mood.tags.edit.group")
            }
        }
    }

    private var iconCard: some View {
        HLSettingsCard(icon: "square.grid.2x2", title: "mood.tags.edit.icon.title") {
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
        .buttonStyle(.plain)
        .accessibilityLabel(Text(icon))
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
    }

    private func save() async {
        guard !selectedGroupKey.isEmpty else { return }
        let success: Bool = switch mode {
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
        if success { dismiss() }
    }
}
