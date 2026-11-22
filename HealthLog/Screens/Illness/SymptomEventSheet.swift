import SwiftUI

/// One symptom occurrence, to log or to edit:
/// the symptom (only when logging), the intensity out of ten, the time, the
/// illness it belongs to, a note, and in the edit form "Eintrag löschen".
///
/// Pushed on the episode's own navigation stack instead of presented as a
/// sheet: the frozen privacy census of presentations admits no new presenter
/// (`validate-phase06-presentation-inventory.sh`), and a pushed page needs
/// none. The delete question is asked in place for the same reason.
///
/// Leaving with input asks first, as an editor sheet does: while the page
/// holds unsaved input the system back button and its swipe give way to a
/// back button that asks through ``View/hlDiscardGuard(isDirty:isSaving:isPresented:onDiscard:)``.
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
    /// The episode the page was opened from; `nil` from Today's quick entry
    /// (#186), where nothing is linked until the person picks an episode.
    let episode: IllnessEpisodeDTO?
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
    @State private var errorText: String?
    @State private var showDiscardConfirm = false
    /// Each symptom's last intensity, read once when logging (#191 QoL).
    @State private var lastIntensities: [String: Int] = [:]
    /// The symptom whose last intensity the field holds; `nil` once the
    /// person chose one themselves.
    @State private var presetFor: String?
    private let initialDraft: Draft

    static let noteLimit = 500

    /// What the page holds that leaving would lose.
    struct Draft: Equatable {
        var definitionId: String?
        var intensity: Int?
        var occurredAt: Date
        var episodeId: String?
        var note: String
    }

    /// What a tap on back does: the same rule as the leading button of an
    /// editor sheet.
    nonisolated static func backStep(initial: Draft, current: Draft, isWorking: Bool) -> HLSheetBar.CloseStep {
        HLSheetBar.closeStep(isDirty: initial != current, isBusy: isWorking)
    }

    /// Whether the system back button and its swipe give way to the asking one.
    nonisolated static func holdsBack(initial: Draft, current: Draft, isWorking: Bool) -> Bool {
        backStep(initial: initial, current: current, isWorking: isWorking) != .leaves
    }

    init(
        mode: Mode,
        episode: IllnessEpisodeDTO?,
        episodes: [IllnessEpisodeDTO],
        repository: SymptomEventsRepository?,
        onDone: @escaping @MainActor () async -> Void
    ) {
        self.mode = mode
        self.episode = episode
        self.episodes = episodes
        self.repository = repository
        self.onDone = onDone
        let draft = switch mode {
        case .create:
            Draft(definitionId: nil, intensity: nil, occurredAt: Date.now, episodeId: episode?.id, note: "")
        case let .edit(event, _):
            Draft(
                definitionId: event.definitionId,
                intensity: event.intensity,
                occurredAt: event.occurredDate ?? Date.now,
                episodeId: event.episodeId,
                note: event.note ?? ""
            )
        }
        initialDraft = draft
        _definitionId = State(initialValue: draft.definitionId)
        _intensity = State(initialValue: draft.intensity)
        _occurredAt = State(initialValue: draft.occurredAt)
        _chosenEpisodeId = State(initialValue: draft.episodeId)
        _note = State(initialValue: draft.note)
    }

    private var currentDraft: Draft {
        Draft(
            definitionId: definitionId,
            intensity: intensity,
            occurredAt: occurredAt,
            episodeId: chosenEpisodeId,
            note: note
        )
    }

    private var holdsBack: Bool {
        Self.holdsBack(initial: initialDraft, current: currentDraft, isWorking: isWorking)
    }

    private var editedEvent: SymptomEvent? {
        if case let .edit(event, _) = mode { return event }
        return nil
    }

    /// The episodes to pick from: the store's list, and this episode even
    /// when the list was not loaded (the page was opened from elsewhere).
    private var episodeOptions: [IllnessEpisodeDTO] {
        let source = Self.episodeSource(opening: episode, episodes: episodes)
        return SymptomEpisodeLink.options(from: source, at: occurredAt, keep: editedEvent?.episodeId)
    }

    /// The store's list, with the opening episode in front when the list
    /// does not hold it.
    nonisolated static func episodeSource(
        opening episode: IllnessEpisodeDTO?,
        episodes: [IllnessEpisodeDTO]
    ) -> [IllnessEpisodeDTO] {
        guard let episode, !episodes.contains(where: { $0.id == episode.id }) else { return episodes }
        return [episode] + episodes
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
            // Rows on the app's surface and page margins, like every other
            // form; without them the page stood on plain black.
            Group {
                Section {
                    symptomField.modifier(SymptomPickerStyle())
                    intensityPicker.modifier(SymptomPickerStyle())
                } footer: {
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        if presetFor != nil {
                            Text("symptoms.intensity.preset")
                                .accessibilityIdentifier("symptoms.edit.intensityPreset")
                        }
                        Text("symptoms.intensity.scale")
                    }
                }
                Section {
                    DatePicker(
                        selection: $occurredAt,
                        in: ...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    ) {
                        HLRowTitle("symptoms.field.when")
                    }
                    .accessibilityIdentifier("symptoms.edit.when")
                    if !episodeOptions.isEmpty {
                        episodePicker.modifier(SymptomPickerStyle())
                    }
                }
                Section {
                    TextField("symptoms.field.notePlaceholder", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .onChange(of: note) { _, newValue in
                            if newValue.count > Self.noteLimit { note = String(newValue.prefix(Self.noteLimit)) }
                        }
                        .accessibilityIdentifier("symptoms.edit.note")
                } header: {
                    HLSectionHeader("symptoms.field.note", rank: .group)
                }
                if let errorText {
                    Section { HLFormErrorText(errorText) }
                }
                if editedEvent != nil {
                    deleteSection
                }
            }
            .hlFormRowSurface()
        }
        .hlPageMargins()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(holdsBack)
        .hlDiscardGuard(
            isDirty: initialDraft != currentDraft,
            isSaving: isWorking,
            isPresented: $showDiscardConfirm,
            onDiscard: { dismiss() }
        )
        .toolbar {
            if holdsBack {
                ToolbarItem(placement: .topBarLeading) {
                    // The system back cannot ask first. While input is open the
                    // page is left like a form, with the cross, which asks; it
                    // is gone once there is nothing to lose.
                    Button(HLControlWord.cancel.key, systemImage: "xmark", action: goBack)
                        .disabled(isWorking)
                        .accessibilityIdentifier("symptoms.edit.back")
                }
            }
        }
        // A pushed page has no sheet bar of its own: the check mark of every
        // sheet stands at the trailing edge and the page goes back once saved.
        .hlConfirmBar(Self.confirmAction(isEnabled: canSave) { await save() }, identifier: Self.saveIdentifier)
        .onChange(of: definitionId) { _, picked in
            let next = SymptomUsage.afterPick(picked, intensity: intensity, presetFor: presetFor, last: lastIntensities)
            presetFor = next.presetFor
            intensity = next.intensity
        }
        .onChange(of: intensity) { _, chosen in
            // A value the person set is theirs, no longer the preset.
            if let preset = presetFor, chosen != lastIntensities[preset] { presetFor = nil }
        }
        .task { await loadLastIntensities() }
    }

    /// Logging only: the last intensity of each symptom, the value a pick
    /// starts on. An aid, so a failed read leaves the field empty as before.
    private func loadLastIntensities() async {
        guard editedEvent == nil, let repository else { return }
        do {
            lastIntensities = try await repository.latestIntensities()
        } catch {
            HLLog.ui.debug("Symptom last intensities unavailable")
        }
    }

    /// The identifier of the check mark; UI tests find the save by it.
    static let saveIdentifier = "symptoms.edit.save"

    /// The confirm of the page: a save, enabled only with a complete entry.
    static func confirmAction(
        isEnabled: Bool,
        perform: @escaping @MainActor () async -> Bool
    ) -> HLSheetAction {
        .save(isEnabled: isEnabled, perform: perform)
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
            // Chips, one tap each, as on the web; a filter from 13 on. The
            // ones felt most lately come first (#191 QoL).
            SymptomChipPicker(definitions: SymptomUsage.orderedByUse(definitions), selection: $definitionId)
        case let .edit(_, label):
            LabeledContent {
                Text(verbatim: SymptomEventFormat.label(label))
            } label: {
                HLRowTitle("symptoms.field.symptom")
            }
        }
    }

    private var intensityPicker: some View {
        Picker(selection: $intensity) {
            if editedEvent == nil {
                Text("symptoms.field.choose").tag(nil as Int?)
            }
            ForEach(Array(SymptomEvent.intensityRange), id: \.self) { value in
                Text(value, format: .number).tag(Optional(value))
            }
        } label: {
            HLRowTitle("symptoms.field.intensity")
        }
        .accessibilityIdentifier("symptoms.edit.intensity")
    }

    private var episodePicker: some View {
        Picker(selection: $chosenEpisodeId) {
            Text("symptoms.field.episodeNone").tag(nil as String?)
            ForEach(episodeOptions) { option in
                Text(verbatim: option.label).tag(Optional(option.id))
            }
        } label: {
            HLRowTitle("symptoms.field.episode")
        }
        .accessibilityIdentifier("symptoms.edit.episode")
    }

    private var deleteSection: some View {
        Section {
            HLDeleteButton(
                "symptoms.delete.action",
                form: .row,
                action: .confirmed(title: "symptoms.delete.question") { await delete() }
            )
            .disabled(isWorking)
            .accessibilityIdentifier("symptoms.edit.delete")
        }
    }

    private func goBack() {
        switch Self.backStep(initial: initialDraft, current: currentDraft, isWorking: isWorking) {
        case .locked: break
        case .asksFirst: showDiscardConfirm = true
        case .leaves: dismiss()
        }
    }

    // MARK: - Writes

    /// `true` once the entry is kept and the list knows it; the confirm bar
    /// then takes the page back.
    private func save() async -> Bool {
        guard let repository, let definitionId, let intensity else { return false }
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
            await onDone()
            return true
        } catch {
            errorText = Self.message(for: error)
            return false
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

/// At an accessibility text size the menu picker's
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
