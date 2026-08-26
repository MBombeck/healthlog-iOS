import SwiftUI

/// Authoritative mood-tag management for groups, layout, visibility, archive,
/// restore, and purge. Every mutation reloads both management endpoints.
struct MoodTagManagementScreen: View {
    @Environment(MoodTagManagementStore.self) private var store

    @State private var showCreateTag = false
    @State private var editingTag: MoodTagDTO?
    @State private var showCreateGroup = false
    @State private var editingGroup: MoodTagCategoryDTO?
    @State private var pendingGroupDelete: MoodTagCategoryDTO?
    @State private var pendingPurge: MoodTagDTO?

    var body: some View {
        HLSettingsPage(title: "mood.tags.manage.title") {
            if let loadError = store.loadError, !store.didLoad {
                loadErrorCard(loadError)
            } else {
                if let error = store.mutationError {
                    mutationErrorCard(error)
                }
                groupsCard
                tagsCard
                archivedCard
            }
        }
        .navigationTitle(Text("mood.tags.manage.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .sheet(isPresented: $showCreateTag) {
            MoodTagEditSheet(mode: .create)
        }
        .sheet(item: $editingTag) { tag in
            MoodTagEditSheet(mode: .edit(tag))
        }
        .sheet(isPresented: $showCreateGroup) {
            MoodTagGroupEditSheet(mode: .create)
        }
        .sheet(item: $editingGroup) { group in
            MoodTagGroupEditSheet(mode: .edit(group))
        }
        .hlConfirmDestructive(
            Text("mood.tags.manage.group.delete.title"),
            presenting: $pendingGroupDelete,
            message: { group in
                let customCount = group.tags.filter(\.custom).count
                return Text(String(
                    format: String(localized: "mood.tags.manage.group.delete.body"),
                    customCount
                ))
            },
            confirm: Text("mood.tags.manage.group.delete.confirm"),
            cancel: Text("Cancel"),
            onCancel: { pendingGroupDelete = nil },
            action: { group in
                pendingGroupDelete = nil
                Task { await store.deleteGroup(key: group.key) }
            }
        )
        .hlConfirmDestructive(
            Text("mood.tags.manage.purge.title"),
            presenting: $pendingPurge,
            message: { tag in
                if let count = tag.usageCount {
                    Text(String(
                        format: String(localized: "mood.tags.manage.purge.body"),
                        count
                    ))
                } else {
                    Text("mood.tags.manage.purge.bodyNoCount")
                }
            },
            confirm: Text("mood.tags.manage.purge.confirm"),
            cancel: Text("Cancel"),
            onCancel: { pendingPurge = nil },
            action: { tag in
                pendingPurge = nil
                Task { await store.deleteCustom(key: tag.key, purge: true) }
            }
        )
    }

    private func loadErrorCard(_ error: HLError) -> some View {
        HLSettingsCard(icon: "exclamationmark.triangle", title: "mood.tags.manage.title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text(error.userFacingDescription)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                HLButton(String(localized: "Retry"), variant: .secondary) {
                    Task { await store.load() }
                }
            }
        }
    }

    private func mutationErrorCard(_ error: HLError) -> some View {
        HLSettingsCard(icon: "exclamationmark.triangle", title: "Error") {
            Text(error.userFacingDescription)
                .font(.hlSubhead)
                .foregroundStyle(HLColor.statusBad)
        }
    }

    /// UI-Standard R2 (U6, Audit-Gruppe N7) — der Footer („Lege die Reihenfolge
    /// fest oder erstelle eigene Gruppen.") benannte genau die Bedienelemente
    /// daneben: die Zeile „Gruppe hinzufügen" und das Hoch/Runter-Menü.
    private var groupsCard: some View {
        HLSettingsCard(
            icon: "rectangle.3.group",
            title: "mood.tags.manage.groups.title"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(store.groups.enumerated()), id: \.element.key) { index, group in
                    groupRow(group, index: index)
                    if index < store.groups.count - 1 {
                        Divider().opacity(0.6)
                    }
                }
                Divider().opacity(0.6)
                addRow("mood.tags.manage.group.add", systemImage: "plus.circle") {
                    store.clearMutationError()
                    showCreateGroup = true
                }
            }
        }
    }

    private func groupRow(_ group: MoodTagCategoryDTO, index: Int) -> some View {
        HStack(spacing: HLSpace.md) {
            Image(systemName: group.sfSymbol)
                .foregroundStyle(HLText.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(group.localizedLabel)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                Text(String(
                    format: String(localized: "mood.tags.manage.group.tagCount"),
                    group.tags.filter { !$0.archived }.count
                ))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            }
            Spacer(minLength: HLSpace.sm)
            Menu {
                Button {
                    Task { await store.moveGroup(key: group.key, by: -1) }
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                .disabled(index == 0)
                Button {
                    Task { await store.moveGroup(key: group.key, by: 1) }
                } label: {
                    Label("Move down", systemImage: "arrow.down")
                }
                .disabled(index == store.groups.count - 1)
                if group.custom {
                    Divider()
                    Button {
                        store.clearMutationError()
                        editingGroup = group
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingGroupDelete = group
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(group.localizedLabel))
        }
        .padding(.vertical, HLSpace.sm)
    }

    private var tagsCard: some View {
        // UI-Standard R2 (U6, N7) — wie oben: „Sortiere Tags, verschiebe sie
        // zwischen Gruppen oder blende sie aus." zählte die Menüpunkte auf, die
        // das Kontextmenü jeder Zeile ohnehin zeigt.
        HLSettingsCard(
            icon: "tag",
            title: "mood.tags.manage.tags.title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                ForEach(store.groups) { group in
                    let tags = group.tags.filter { !$0.archived }
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        HLSectionLabel(verbatim: group.localizedLabel)
                        if tags.isEmpty {
                            Text("mood.tags.manage.group.empty")
                                .font(.hlCaption)
                                .foregroundStyle(HLText.tertiary)
                                .padding(.vertical, HLSpace.sm)
                        } else {
                            ForEach(Array(tags.enumerated()), id: \.element.key) { index, tag in
                                tagRow(tag, group: group, index: index, count: tags.count)
                                if index < tags.count - 1 {
                                    Divider().opacity(0.6)
                                }
                            }
                        }
                    }
                }
                Divider().opacity(0.6)
                addRow("mood.tags.manage.custom.add", systemImage: "plus.circle") {
                    store.clearMutationError()
                    showCreateTag = true
                }
            }
        }
    }

    private func tagRow(
        _ tag: MoodTagDTO,
        group: MoodTagCategoryDTO,
        index: Int,
        count: Int
    ) -> some View {
        HStack(spacing: HLSpace.md) {
            Image(systemName: MoodTagSFSymbol.symbol(forTag: tag))
                .foregroundStyle(HLText.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(tag.localizedLabel)
                    .font(.hlSubhead)
                    .foregroundStyle(tag.hidden ? HLText.tertiary : HLText.primary)
                if tag.isRated {
                    Text("\(tag.scaleMin)–\(tag.scaleMax)")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            }
            Spacer(minLength: HLSpace.xs)
            if let usageCount = tag.usageCount {
                Text("\(usageCount)")
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.sm)
                    .padding(.vertical, HLSpace.xxs)
                    .background(HLSurface.tertiary, in: Capsule())
                    .accessibilityLabel(Text(String(
                        format: String(localized: "mood.tags.manage.usage"),
                        usageCount
                    )))
            }
            Menu {
                Button {
                    Task {
                        await store.moveTagWithinGroup(key: tag.key, groupKey: group.key, by: -1)
                    }
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                .disabled(index == 0)
                Button {
                    Task {
                        await store.moveTagWithinGroup(key: tag.key, groupKey: group.key, by: 1)
                    }
                } label: {
                    Label("Move down", systemImage: "arrow.down")
                }
                .disabled(index == count - 1)
                Menu("Move to group", systemImage: "folder") {
                    ForEach(store.groups.filter { $0.key != group.key }) { target in
                        Button(target.localizedLabel) {
                            Task { await store.moveTag(key: tag.key, to: target.key) }
                        }
                    }
                }
                Divider()
                if tag.custom {
                    Button {
                        store.clearMutationError()
                        editingTag = tag
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button {
                        Task { await store.setCustomActive(key: tag.key, isActive: false) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                } else {
                    Button {
                        Task { await store.setCatalogueHidden(key: tag.key, hidden: !tag.hidden) }
                    } label: {
                        Label(
                            tag.hidden ? "Show" : "Hide",
                            systemImage: tag.hidden ? "eye" : "eye.slash"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(tag.localizedLabel))
        }
        .padding(.vertical, HLSpace.sm)
    }

    @ViewBuilder
    private var archivedCard: some View {
        if !store.archivedCustomTags.isEmpty {
            HLSettingsCard(
                icon: "archivebox",
                title: "mood.tags.manage.archived.title",
                footer: "mood.tags.manage.archived.footer"
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(store.archivedCustomTags.enumerated()), id: \.element.key) { index, tag in
                        HStack(spacing: HLSpace.md) {
                            Image(systemName: MoodTagSFSymbol.symbol(forTag: tag))
                                .foregroundStyle(HLText.secondary)
                                .frame(width: 24)
                            Text(tag.localizedLabel)
                                .font(.hlSubhead)
                            Spacer()
                            if let usageCount = tag.usageCount {
                                Text("\(usageCount)")
                                    .font(.hlCaption)
                                    .foregroundStyle(HLText.tertiary)
                            }
                            Menu {
                                Button {
                                    Task { await store.setCustomActive(key: tag.key, isActive: true) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    pendingPurge = tag
                                } label: {
                                    Label("mood.tags.manage.deletePurge", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(width: 44, height: 44)
                            }
                        }
                        .padding(.vertical, HLSpace.sm)
                        if index < store.archivedCustomTags.count - 1 {
                            Divider().opacity(0.6)
                        }
                    }
                }
            }
        }
    }

    private func addRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.hlSubhead.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tint)
            .padding(.vertical, HLSpace.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MoodTagGroupEditSheet: View {
    enum Mode {
        case create
        case edit(MoodTagCategoryDTO)
    }

    let mode: Mode

    @Environment(MoodTagManagementStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var icon = "Tag"
    @FocusState private var labelFocused: Bool

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("mood.tags.manage.group.details") {
                    TextField("mood.tags.edit.label.placeholder", text: $label)
                        .focused($labelFocused)
                    Picker("mood.tags.edit.icon.title", selection: $icon) {
                        ForEach(MoodTagCatalog.customIconAllowList, id: \.self) { option in
                            Label(option, systemImage: MoodTagSFSymbol.symbolForAllowListIcon(option))
                                .tag(option)
                        }
                    }
                }
                if let error = store.mutationError {
                    Section { HLFormErrorText(error.userFacingDescription) }
                }
            }
            .navigationTitle(
                Text(isEditing ? "mood.tags.manage.group.edit" : "mood.tags.manage.group.create")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(trimmedLabel.isEmpty || trimmedLabel.count > 40 || store.isMutating)
                }
            }
            .onAppear(perform: seed)
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                labelFocused = true
            }
        }
        .hlSheetPresentation(.standard)
    }

    private func seed() {
        guard case let .edit(group) = mode else { return }
        label = group.localizedLabel
        if let currentIcon = group.icon {
            icon = currentIcon
        }
    }

    private func save() async {
        let success: Bool = switch mode {
        case .create:
            await store.createGroup(label: trimmedLabel, icon: icon)
        case let .edit(group):
            await store.updateGroup(key: group.key, label: trimmedLabel, icon: icon)
        }
        if success { dismiss() }
    }
}
