import SwiftUI

/// Edit an existing illness episode. Scalar fields remain partial in the PATCH;
/// clearable end-date, parent and note values are always sent explicitly.
struct EditEpisodeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: IllnessStore
    let episode: IllnessEpisodeDTO
    var onSaved: ((IllnessEpisodeDTO) -> Void)?

    @State private var label: String
    @State private var type: IllnessType
    @State private var lifecycle: IllnessLifecycle
    @State private var onsetAt: Date
    @State private var hasResolvedAt: Bool
    @State private var resolvedAt: Date
    @State private var parentConditionId: String?
    @State private var note: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        store: IllnessStore,
        episode: IllnessEpisodeDTO,
        onSaved: ((IllnessEpisodeDTO) -> Void)? = nil
    ) {
        self.store = store
        self.episode = episode
        self.onSaved = onSaved
        _label = State(initialValue: episode.label)
        _type = State(initialValue: episode.type)
        _lifecycle = State(initialValue: episode.lifecycle)
        let onset = Self.parseDate(episode.onsetAt) ?? Date.now
        _onsetAt = State(initialValue: onset)
        let resolved = episode.resolvedAt.flatMap(Self.parseDate)
        _hasResolvedAt = State(initialValue: resolved != nil)
        _resolvedAt = State(initialValue: resolved ?? max(onset, Date.now))
        _parentConditionId = State(initialValue: episode.parentConditionId)
        _note = State(initialValue: episode.note ?? "")
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
            onsetAt <= Date.now &&
            (!hasResolvedAt || (resolvedAt >= onsetAt && resolvedAt <= Date.now)) &&
            !isSaving
    }

    private var parentCandidates: [IllnessEpisodeDTO] {
        store.episodes.filter { $0.id != episode.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("illness.add.section.about") {
                    TextField("illness.add.label", text: $label)
                    Picker("illness.add.type", selection: $type) {
                        ForEach(IllnessType.allCases) { type in
                            Text(type.localizedLabel).tag(type)
                        }
                    }
                    Picker("illness.add.lifecycle", selection: $lifecycle) {
                        ForEach(IllnessLifecycle.allCases) { lifecycle in
                            Text(lifecycle.localizedLabel).tag(lifecycle)
                        }
                    }
                    .onChange(of: lifecycle) { _, newValue in
                        if !newValue.allowsParent {
                            parentConditionId = nil
                        }
                    }
                    if lifecycle.allowsParent {
                        Picker("illness.add.parent", selection: $parentConditionId) {
                            Text("illness.add.parent.none").tag(nil as String?)
                            ForEach(parentCandidates) { candidate in
                                Text(candidate.label).tag(Optional(candidate.id))
                            }
                        }
                    }
                }
                Section("illness.add.section.onset") {
                    DatePicker(
                        "illness.add.onsetAt",
                        selection: $onsetAt,
                        in: ...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .onChange(of: onsetAt) { _, newValue in
                        if resolvedAt < newValue {
                            resolvedAt = newValue
                        }
                    }
                    Toggle("illness.add.resolved.toggle", isOn: $hasResolvedAt)
                    if hasResolvedAt {
                        DatePicker(
                            "illness.add.resolvedAt",
                            selection: $resolvedAt,
                            in: onsetAt ... Date.now,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
                Section("illness.add.section.note") {
                    TextField("illness.add.note", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                }
                if let saveError {
                    Section { HLFormErrorText(saveError) }
                }
            }
            .navigationTitle(Text("illness.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("illness.action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("illness.action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let iso = ISO8601DateFormatter()
        let originalOnset = Self.parseDate(episode.onsetAt)
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let patch = IllnessEpisodePatch(
            label: trimmedLabel == episode.label ? nil : trimmedLabel,
            type: type == episode.type ? nil : type,
            lifecycle: lifecycle == episode.lifecycle ? nil : lifecycle,
            onsetAt: onsetAt == originalOnset ? nil : iso.string(from: onsetAt),
            resolvedAt: hasResolvedAt ? iso.string(from: resolvedAt) : nil,
            parentConditionId: lifecycle.allowsParent ? parentConditionId : nil,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        if await store.updateEpisode(id: episode.id, patch) {
            if let updated = store.selectedEpisode, updated.id == episode.id {
                onSaved?(updated)
            }
            dismiss()
        } else {
            saveError = store.lastError ?? String(localized: "illness.save.failed")
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: raw) ??
            ISO8601DateFormatter.plain.date(from: raw)
    }
}
