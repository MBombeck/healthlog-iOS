import SwiftUI

/// Authoritative mood-tag management for groups, layout, visibility, archive,
/// restore, and purge. Every mutation reloads both management endpoints.
struct MoodTagManagementScreen: View {
    @Environment(MoodTagManagementStore.self) private var store

    @State private var showCreateTag = false
    @State private var editingTag: MoodTagDTO?
    @State private var showCreateGroup = false
    @State private var editingGroup: MoodTagCategoryDTO?

    var body: some View {
        HLPage {
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
    }

    private func loadErrorCard(_ error: HLError) -> some View {
        HLCard("mood.tags.manage.title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text(error.userFacingDescription)
                    .hlText(.factLabel)
                HLButton(HLControlWord.retry.key, variant: .secondary) {
                    Task { await store.load() }
                }
            }
        }
    }

    private func mutationErrorCard(_ error: HLError) -> some View {
        HLCard("Error") {
            Text(error.userFacingDescription)
                .font(.hlSubhead)
                .foregroundStyle(HLColor.statusBad)
        }
    }

    /// UI-Standard R2 (U6, Audit-Gruppe N7) — der Footer („Lege die Reihenfolge
    /// fest oder erstelle eigene Gruppen.") benannte genau die Bedienelemente
    /// daneben: die Zeile „Gruppe hinzufügen" und das Hoch/Runter-Menü.
    private var groupsCard: some View {
        HLCard("mood.tags.manage.groups.title") {
            VStack(spacing: 0) {
                ForEach(Array(store.groups.enumerated()), id: \.element.key) { index, group in
                    groupRow(group, index: index)
                }
                HLSettingsActionRow(title: "mood.tags.manage.group.add", presents: .create) {
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
                    .hlText(.prose)
                Text(String(
                    format: String(localized: "mood.tags.manage.group.tagCount"),
                    group.tags.filter { !$0.archived }.count
                ))
                .hlText(.footnote)
            }
            Spacer(minLength: HLSpace.sm)
            HLIconButton(systemImage: "ellipsis", label: LocalizedStringKey(group.localizedLabel), menu: {
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
                    // A group takes its tags along: asked first.
                    HLDeleteMenuItem(.confirmed(
                        title: "mood.tags.manage.group.delete.title",
                        message: LocalizedStringKey(String(
                            format: String(localized: "mood.tags.manage.group.delete.body"),
                            group.tags.filter(\.custom).count
                        ))
                    ) {
                        await store.deleteGroup(key: group.key)
                    })
                }
            })
        }
        .padding(.vertical, HLSpace.sm)
        .hlDeleteConfirmation()
    }

    private var tagsCard: some View {
        // UI-Standard R2 — wie oben: „Sortiere Tags, verschiebe sie
        // zwischen Gruppen oder blende sie aus." zählte die Menüpunkte auf, die
        // das Kontextmenü jeder Zeile ohnehin zeigt.
        HLCard("mood.tags.manage.tags.title") {
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                // A group without a visible tag is left out instead of
                // a label over "Noch keine Tags in dieser Gruppe."
                ForEach(store.groups.filter { $0.tags.contains { !$0.archived } }) { group in
                    let tags = group.tags.filter { !$0.archived }
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        HLCardLabel(verbatim: group.localizedLabel)
                        ForEach(Array(tags.enumerated()), id: \.element.key) { index, tag in
                            tagRow(tag, group: group, index: index, count: tags.count)
                        }
                    }
                }
                HLSettingsActionRow(title: "mood.tags.manage.custom.add", presents: .create) {
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
                    Text(verbatim: HLNumberFormat.range("\(tag.scaleMin)", "\(tag.scaleMax)"))
                        .hlText(.footnote)
                }
            }
            Spacer(minLength: HLSpace.xs)
            if let usageCount = tag.usageCount {
                HLBadge(HLValueFormat.number(Double(usageCount), fractionDigits: 0 ... 0))
                    .accessibilityLabel(Text(String(
                        format: String(localized: "mood.tags.manage.usage"),
                        usageCount
                    )))
            }
            HLIconButton(systemImage: "ellipsis", label: LocalizedStringKey(tag.localizedLabel), menu: {
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
            })
        }
        .padding(.vertical, HLSpace.sm)
    }

    @ViewBuilder
    private var archivedCard: some View {
        if !store.archivedCustomTags.isEmpty {
            // The menu on each row shows restore and delete; no
            // footer explains them.
            HLCard("mood.tags.manage.archived.title") {
                VStack(spacing: 0) {
                    ForEach(store.archivedCustomTags, id: \.key) { tag in
                        HStack(spacing: HLSpace.md) {
                            Image(systemName: MoodTagSFSymbol.symbol(forTag: tag))
                                .foregroundStyle(HLText.secondary)
                                .frame(width: 24)
                            Text(tag.localizedLabel)
                                .font(.hlSubhead)
                            Spacer()
                            if let usageCount = tag.usageCount {
                                HLBadge(HLValueFormat.number(Double(usageCount), fractionDigits: 0 ... 0))
                                    .accessibilityLabel(Text(String(
                                        format: String(localized: "mood.tags.manage.usage"),
                                        usageCount
                                    )))
                            }
                            HLIconButton(systemImage: "ellipsis", label: LocalizedStringKey(tag.localizedLabel), menu: {
                                Button {
                                    Task { await store.setCustomActive(key: tag.key, isActive: true) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                // Deleting for good takes the tag off every entry: asked first.
                                HLDeleteMenuItem(purgeAction(for: tag))
                            })
                        }
                        .padding(.vertical, HLSpace.sm)
                        .hlDeleteConfirmation()
                    }
                }
            }
        }
    }

    private func purgeAction(for tag: MoodTagDTO) -> HLDeleteAction {
        let message = tag.usageCount.map {
            String(format: String(localized: "mood.tags.manage.purge.body"), $0)
        } ?? String(localized: "mood.tags.manage.purge.bodyNoCount")
        return .confirmed(
            verbatim: String(localized: "mood.tags.manage.purge.title"),
            message: message,
            word: "mood.tags.manage.purge.confirm"
        ) {
            _ = await store.deleteCustom(key: tag.key, purge: true)
        }
    }
}

private struct MoodTagGroupEditSheet: View {
    enum Mode {
        case create
        case edit(MoodTagCategoryDTO)
    }

    let mode: Mode

    @Environment(MoodTagManagementStore.self) private var store
    @State private var label = ""
    @State private var icon = "Tag"
    /// Name and icon as the sheet opened, for the question before discarding.
    @State private var seeded: (label: String, icon: String) = ("", "Tag")
    @FocusState private var labelFocused: Bool

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HLSheetScaffold(
            isEditing ? "mood.tags.manage.group.edit" : "mood.tags.manage.group.create",
            size: .standard,
            action: .save(isEnabled: !trimmedLabel.isEmpty && trimmedLabel.count <= 40) {
                await save()
            },
            isDirty: label != seeded.label || icon != seeded.icon
        ) {
            Form {
                Section("mood.tags.manage.group.details") {
                    TextField("mood.tags.edit.label.placeholder", text: $label)
                        .focused($labelFocused)
                    Picker(selection: $icon) {
                        ForEach(MoodTagCatalog.customIconAllowList, id: \.self) { option in
                            Label(
                                MoodTagIconName.label(for: option),
                                systemImage: MoodTagSFSymbol.symbolForAllowListIcon(option)
                            )
                            .tag(option)
                        }
                    } label: {
                        HLRowTitle("mood.tags.edit.icon.title")
                    }
                }
                .hlFormRowSurface()
                if let error = store.mutationError {
                    Section { HLFormErrorText(error.userFacingDescription) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            .onAppear(perform: seed)
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                labelFocused = true
            }
        }
    }

    private func seed() {
        guard case let .edit(group) = mode else { return }
        label = group.localizedLabel
        if let currentIcon = group.icon {
            icon = currentIcon
        }
        seeded = (label, icon)
    }

    /// `true` closes the sheet; on a failure the error stays in the form.
    private func save() async -> Bool {
        switch mode {
        case .create:
            await store.createGroup(label: trimmedLabel, icon: icon)
        case let .edit(group):
            await store.updateGroup(key: group.key, label: trimmedLabel, icon: icon)
        }
    }
}
