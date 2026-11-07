import SwiftUI

/// **SYMPTOM (1.5.0, #144)** — one symptom occurrence, to log or to edit:
/// the symptom (only when logging), the intensity out of ten, the time, the
/// illness it belongs to, a note, and in the edit form "Eintrag löschen".
///
/// Pushed on the episode's own navigation stack instead of presented as a
/// sheet: the frozen privacy census of presentations admits no new presenter
/// (`validate-phase06-presentation-inventory.sh`), and a pushed page needs
/// none. The delete question is asked in place for the same reason.
///
/// The illness picker offers what the server admits at the chosen time
/// (``SymptomEpisodeLink``): every running episode and every ended one whose
/// span holds that time, plus the stored link of an edited occurrence. The
/// current episode is preselected when logging. If the time moves so the
/// chosen episode no longer fits, "Nicht verknüpft" is sent rather than a link
/// the server refuses; should it refuse anyway (`422 symptoms.episode.notOpen`),
/// the page says why.
struct SymptomEventSheet: View {
    enum Mode {
        case create([SymptomDefinition])
        case edit(SymptomEvent, label: String?)
    }

    let mode: Mode
    let episode: IllnessEpisodeDTO
    let episodes: [IllnessEpisodeDTO]
    let repository: SymptomEventsRepository?
    let onDone: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var definitionId: String?
    @State private var intensity: Int?
    @State private var occurredAt: Date
    @State private var chosenEpisodeId: String?
    @State private var note: String
    @State private var isWorking = false
    @State private var confirmingDelete = false
    @State private var errorText: String?

    static let noteLimit = 500

    init(
        mode: Mode,
        episode: IllnessEpisodeDTO,
        episodes: [IllnessEpisodeDTO],
        repository: SymptomEventsRepository?,
        onDone: @escaping @MainActor () async -> Void
    ) {
        self.mode = mode
        self.episode = episode
        self.episodes = episodes
        self.repository = repository
        self.onDone = onDone
        switch mode {
        case .create:
            _definitionId = State(initialValue: nil)
            _intensity = State(initialValue: nil)
            _occurredAt = State(initialValue: Date.now)
            _chosenEpisodeId = State(initialValue: episode.id)
            _note = State(initialValue: "")
        case let .edit(event, _):
            _definitionId = State(initialValue: event.definitionId)
            _intensity = State(initialValue: event.intensity)
            _occurredAt = State(initialValue: event.occurredDate ?? Date.now)
            _chosenEpisodeId = State(initialValue: event.episodeId)
            _note = State(initialValue: event.note ?? "")
        }
    }

    private var editedEvent: SymptomEvent? {
        if case let .edit(event, _) = mode { return event }
        return nil
    }

    /// The episodes to pick from: the store's list, and this episode even
    /// when the list was not loaded (the page was opened from elsewhere).
    private var episodeOptions: [IllnessEpisodeDTO] {
        let source = episodes.contains { $0.id == episode.id } ? episodes : [episode] + episodes
        return SymptomEpisodeLink.options(from: source, at: occurredAt, keep: editedEvent?.episodeId)
    }

    private var effectiveEpisodeId: String? {
        SymptomEpisodeLink.effective(chosen: chosenEpisodeId, options: episodeOptions)
    }

    private var canSave: Bool {
        !isWorking && repository != nil && definitionId != nil && intensity != nil
            && occurredAt <= Date.now.addingTimeInterval(300)
    }

    var body: some View {
        Form {
            Section {
                symptomField.modifier(SymptomPickerStyle())
                intensityPicker.modifier(SymptomPickerStyle())
            } footer: {
                Text("symptoms.intensity.scale")
            }
            Section {
                DatePicker(
                    "symptoms.field.when",
                    selection: $occurredAt,
                    in: ...Date.now,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("symptoms.edit.when")
                if !episodeOptions.isEmpty {
                    episodePicker.modifier(SymptomPickerStyle())
                }
            }
            Section("symptoms.field.note") {
                TextField("symptoms.field.notePlaceholder", text: $note, axis: .vertical)
                    .lineLimit(2 ... 5)
                    .onChange(of: note) { _, newValue in
                        if newValue.count > Self.noteLimit { note = String(newValue.prefix(Self.noteLimit)) }
                    }
                    .accessibilityIdentifier("symptoms.edit.note")
            }
            if let errorText {
                Section { HLFormErrorText(errorText) }
            }
            if editedEvent != nil {
                deleteSection
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("illness.action.save") {
                    Task { await save() }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("symptoms.edit.save")
            }
        }
    }

    private var title: Text {
        switch mode {
        case .create: Text("symptoms.add")
        case let .edit(_, label): Text(verbatim: SymptomEventFormat.label(label))
        }
    }

    @ViewBuilder
    private var symptomField: some View {
        switch mode {
        case let .create(definitions):
            Picker("symptoms.field.symptom", selection: $definitionId) {
                Text("symptoms.field.choose").tag(nil as String?)
                ForEach(definitions) { definition in
                    Text(verbatim: SymptomEventFormat.label(definition.label)).tag(Optional(definition.id))
                }
            }
            .accessibilityIdentifier("symptoms.edit.symptom")
        case let .edit(_, label):
            LabeledContent {
                Text(verbatim: SymptomEventFormat.label(label))
            } label: {
                Text("symptoms.field.symptom")
            }
        }
    }

    private var intensityPicker: some View {
        Picker("symptoms.field.intensity", selection: $intensity) {
            if editedEvent == nil {
                Text("symptoms.field.choose").tag(nil as Int?)
            }
            ForEach(Array(SymptomEvent.intensityRange), id: \.self) { value in
                Text(value, format: .number).tag(Optional(value))
            }
        }
        .accessibilityIdentifier("symptoms.edit.intensity")
    }

    private var episodePicker: some View {
        Picker("symptoms.field.episode", selection: $chosenEpisodeId) {
            Text("symptoms.field.episodeNone").tag(nil as String?)
            ForEach(episodeOptions) { option in
                Text(verbatim: option.label).tag(Optional(option.id))
            }
        }
        .accessibilityIdentifier("symptoms.edit.episode")
    }

    private var deleteSection: some View {
        Section {
            if confirmingDelete {
                Text("symptoms.delete.question")
                    .foregroundStyle(HLText.secondary)
                Button("symptoms.delete.confirm", role: .destructive) {
                    Task { await delete() }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("symptoms.edit.delete.confirm")
                Button("illness.action.cancel") {
                    confirmingDelete = false
                }
            } else {
                Button("symptoms.delete.action", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(isWorking)
                .accessibilityIdentifier("symptoms.edit.delete")
            }
        }
    }

    // MARK: - Writes

    private func save() async {
        guard let repository, let definitionId, let intensity else { return }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            if let event = editedEvent {
                let patch = SymptomEventPatch.between(
                    event,
                    occurredAt: occurredAt,
                    intensity: intensity,
                    note: note,
                    episodeId: effectiveEpisodeId
                )
                if !patch.isEmpty {
                    try await repository.update(id: event.id, patch)
                }
            } else {
                try await repository.create(SymptomEventCreate(
                    definitionId: definitionId,
                    occurredAt: occurredAt,
                    intensity: intensity,
                    note: note,
                    episodeId: effectiveEpisodeId
                ))
            }
            await finish()
        } catch {
            errorText = Self.message(for: error)
        }
    }

    private func delete() async {
        guard let repository, let event = editedEvent else { return }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await repository.delete(id: event.id)
            await finish()
        } catch where SymptomEventsRepository.isGone(error) {
            // Already gone: the list is what needs to change.
            await finish()
        } catch {
            confirmingDelete = false
            errorText = Self.message(for: error)
        }
    }

    private func finish() async {
        await onDone()
        dismiss()
    }

    /// What the page says when a write is refused. `nil` for a cancelled one.
    nonisolated static func message(for error: Error) -> String? {
        if SymptomEventsRepository.isEpisodeNotOpen(error) {
            return String(localized: "symptoms.error.episodeNotOpen")
        }
        if SymptomEventsRepository.isGone(error) {
            return String(localized: "symptoms.error.gone")
        }
        if error is CancellationError { return nil }
        guard let hl = error as? HLError else { return String(localized: "illness.save.failed") }
        switch hl {
        case .canceled:
            return nil
        case .moduleDisabled:
            return String(localized: "symptoms.error.notAllowed")
        case let .server(status, _, _) where status == 403:
            return String(localized: "symptoms.error.notAllowed")
        default:
            let text = hl.userFacingDescription
            return text.isEmpty ? String(localized: "illness.save.failed") : text
        }
    }
}

/// POLISH-C (F-AX-SYMPTOM) — at an accessibility text size the menu picker's
/// value is cut to "Nicht…setzt" beside its label; there the choice opens as
/// its own list, where every value reads in full.
private struct SymptomPickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            content.pickerStyle(.navigationLink)
        } else {
            content.pickerStyle(.menu)
        }
    }
}
