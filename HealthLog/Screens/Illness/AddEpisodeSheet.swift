import SwiftUI

/// Open a new illness episode. Captures the full episode form, including an
/// optional end date and parent relationship for flares/recurrences.
struct AddEpisodeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: IllnessStore

    @State private var label = ""
    @State private var type: IllnessType = .infection
    @State private var lifecycle: IllnessLifecycle = .acute
    @State private var onsetAt = Date.now
    @State private var hasResolvedAt = false
    @State private var resolvedAt = Date.now
    @State private var parentConditionId: String?
    @State private var note = ""
    @State private var isSaving = false
    @State private var saveError: String?

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
            onsetAt <= Date.now &&
            (!hasResolvedAt || (resolvedAt >= onsetAt && resolvedAt <= Date.now)) &&
            !isSaving
    }

    private var parentCandidates: [IllnessEpisodeDTO] {
        store.episodes
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
            .navigationTitle(Text("illness.add.title"))
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
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let body = IllnessEpisodeCreate(
            label: label.trimmingCharacters(in: .whitespaces),
            type: type,
            lifecycle: lifecycle,
            onsetAt: iso.string(from: onsetAt),
            resolvedAt: hasResolvedAt ? iso.string(from: resolvedAt) : nil,
            parentConditionId: lifecycle.allowsParent ? parentConditionId : nil,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        if await store.createEpisode(body) != nil {
            dismiss()
        } else {
            saveError = store.lastError ?? String(localized: "illness.save.failed")
        }
    }
}
