import SwiftUI

/// Record a seizure that was not timed, or add the details to one (web
/// `seizure-sheet.tsx`). Only the start is needed; everything else is what
/// the person or the carer knows. On an edit every field shown is sent, a
/// cleared one as cleared; the fields the app does not show stay as they are.
struct SeizureEventSheet: View {
    let store: SeizuresStore
    let editing: SeizureEventDTO?

    @State private var draft: SeizureEventDraft
    @State private var saveError: String?
    @State private var baseline: SeizureEventDraft?
    /// One key per new seizure, kept across retries, so a second tap lands once.
    @State private var idempotencyKey = IdempotencyKey()

    init(store: SeizuresStore, editing: SeizureEventDTO?) {
        self.store = store
        self.editing = editing
        _draft = State(initialValue: SeizureEventDraft(editing: editing, pickedTypeId: store.pickedTypeId))
    }

    var body: some View {
        HLSheetScaffold(
            editing == nil ? "seizures.sheet.newTitle" : "seizures.sheet.editTitle",
            action: editing == nil
                ? .add(isEnabled: draft.isValid, perform: { await save() })
                : .save(isEnabled: draft.isValid, perform: { await save() }),
            isDirty: baseline.map { $0 != draft } ?? false
        ) {
            Form {
                Group {
                    whenSection
                    durationSection
                    kindSection
                    chipSection("seizures.sheet.semiology", values: SeizureSemiology.choices, label: \.label, selection: $draft.semiology)
                    afterSection
                    contextSection
                    Section("seizures.sheet.note") {
                        TextField("seizures.sheet.note", text: $draft.note, axis: .vertical)
                            .lineLimit(2 ... 5)
                            .accessibilityIdentifier("seizures.sheet.note")
                    }
                    if let saveError {
                        Section { HLFormErrorText(saveError) }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
        }
        .onAppear { if baseline == nil { baseline = draft } }
    }

    private var whenSection: some View {
        Section {
            Picker(selection: $draft.typeProfileId) {
                Text("seizures.untyped").tag(nil as String?)
                ForEach(typeChoices) { type in
                    Text(verbatim: type.displayName).tag(Optional(type.id))
                }
            } label: {
                HLRowTitle("seizures.sheet.type")
            }
            .accessibilityIdentifier("seizures.sheet.type")
            DatePicker(selection: $draft.onset, in: ...Date.now.addingTimeInterval(300), displayedComponents: [.date, .hourAndMinute]) {
                HLRowTitle("seizures.sheet.onset")
            }
            Picker(selection: $draft.onsetPrecision) {
                ForEach(SeizureOnsetPrecision.choices, id: \.self) { Text($0.label).tag($0) }
            } label: {
                HLRowTitle("seizures.sheet.onsetPrecision")
            }
        } footer: {
            if editing == nil { Text("seizures.sheet.description") }
        }
    }

    private var durationSection: some View {
        Section {
            HStack(spacing: HLSpace.md) {
                TextField("seizures.sheet.minutes", text: $draft.minutes)
                    .keyboardType(.numberPad)
                    .accessibilityLabel(Text("seizures.sheet.minutes"))
                    .accessibilityIdentifier("seizures.sheet.minutes")
                Text(verbatim: ":").hlText(.rowSubtitle).accessibilityHidden(true)
                TextField("seizures.sheet.seconds", text: $draft.seconds)
                    .keyboardType(.numberPad)
                    .accessibilityLabel(Text("seizures.sheet.seconds"))
                    .accessibilityIdentifier("seizures.sheet.seconds")
            }
            if draft.durationSec != nil {
                Picker(selection: $draft.durationSource) {
                    ForEach([SeizureDurationSource.timed, .estimated], id: \.self) { Text($0.label).tag($0) }
                } label: {
                    HLRowTitle("seizures.sheet.durationSource")
                }
            }
        } header: {
            Text("seizures.sheet.duration")
        } footer: {
            Text("seizures.sheet.durationHint")
        }
    }

    private var kindSection: some View {
        Section {
            Picker(selection: $draft.certainty) {
                ForEach(SeizureCertainty.choices, id: \.self) { Text($0.label).tag($0) }
            } label: {
                HLRowTitle("seizures.sheet.certainty")
            }
            Stepper(value: $draft.count, in: SeizureEventWrite.countRange) {
                HStack {
                    HLRowTitle("seizures.sheet.count")
                    Spacer(minLength: HLSpace.sm)
                    Text(verbatim: draft.count.formatted()).hlText(.rowValue)
                }
            }
            Picker(selection: $draft.sleepState) {
                ForEach(SeizureSleepState.choices, id: \.self) { Text($0.label).tag($0) }
            } label: {
                HLRowTitle("seizures.sheet.sleepState")
            }
        } footer: {
            Text("seizures.sheet.countHint")
        }
    }

    @ViewBuilder
    private var afterSection: some View {
        chipSection("seizures.sheet.postictal", values: SeizurePostictal.choices, label: \.label, selection: $draft.postictal)
        chipSection("seizures.sheet.injuries", values: SeizureInjury.choices, label: \.label, selection: $draft.injuries)
        Section {
            Picker(selection: $draft.emergency) {
                ForEach(SeizureEmergency.choices, id: \.self) { Text($0.label).tag($0) }
            } label: {
                HLRowTitle("seizures.sheet.emergency")
            }
        }
    }

    @ViewBuilder
    private var contextSection: some View {
        chipSection(
            "seizures.sheet.triggers",
            footer: "seizures.sheet.triggersHint",
            values: SeizureTrigger.choices,
            label: \.label,
            selection: $draft.triggers
        )
        Section {
            Picker(selection: $draft.witnessed) {
                Text("seizures.notRecorded").tag(nil as Bool?)
                Text("seizures.answer.yes").tag(Optional(true))
                Text("seizures.answer.no").tag(Optional(false))
            } label: {
                HLRowTitle("seizures.sheet.witnessed")
            }
            if draft.witnessed == true {
                Picker(selection: $draft.witnessRole) {
                    Text("seizures.notRecorded").tag(nil as SeizureObserverRole?)
                    ForEach(SeizureObserverRole.choices, id: \.self) { Text($0.label).tag(Optional($0)) }
                } label: {
                    HLRowTitle("seizures.sheet.witnessRole")
                }
            }
        }
    }

    private func chipSection<Value: Hashable>(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        values: [Value],
        label: KeyPath<Value, String>,
        selection: Binding<[Value]>
    ) -> some View {
        Section {
            SeizureChoiceChips(values: values, label: label, selection: selection)
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    /// The active types, plus the one the seizure names even when archived.
    private var typeChoices: [SeizureTypeDTO] {
        var types = store.types
        if let id = editing?.typeProfileId, !types.contains(where: { $0.id == id }), let archived = store.diary?.type(id: id) {
            types.append(archived)
        }
        return types
    }

    /// `true` when the sheet may close.
    private func save() async -> Bool {
        saveError = nil
        let saved: SeizureEventDTO? = if let editing {
            await store.update(id: editing.id, draft.write(mode: .update))
        } else {
            await store.create(draft.write(mode: .create), idempotencyKey: idempotencyKey)
        }
        if saved != nil { return true }
        saveError = store.lastError ?? String(localized: "seizures.saveError")
        return false
    }
}

/// Several values out of a vocabulary, as chips.
struct SeizureChoiceChips<Value: Hashable>: View {
    let values: [Value]
    let label: KeyPath<Value, String>
    @Binding var selection: [Value]

    var body: some View {
        HLFlowLayout {
            ForEach(values, id: \.self) { value in
                let isOn = selection.contains(value)
                HLChip(verbatim: value[keyPath: label], isSelected: isOn) {
                    if isOn {
                        selection.removeAll { $0 == value }
                    } else {
                        selection.append(value)
                    }
                }
            }
        }
    }
}

/// The form's state, comparable for the discard guard. Pure.
struct SeizureEventDraft: Equatable {
    var typeProfileId: String?
    var onset: Date
    var onsetPrecision: SeizureOnsetPrecision
    var minutes: String
    var seconds: String
    var durationSource: SeizureDurationSource
    var count: Int
    var certainty: SeizureCertainty
    var sleepState: SeizureSleepState
    var semiology: [SeizureSemiology]
    var triggers: [SeizureTrigger]
    var postictal: [SeizurePostictal]
    var injuries: [SeizureInjury]
    var emergency: SeizureEmergency
    var witnessed: Bool?
    var witnessRole: SeizureObserverRole?
    var note: String

    init(editing event: SeizureEventDTO?, pickedTypeId: String?, now: Date = .now) {
        typeProfileId = event?.typeProfileId ?? (event == nil ? pickedTypeId : nil)
        onset = event?.onsetDate ?? now
        onsetPrecision = event?.onsetPrecision ?? .approx
        let split = SeizurePresentation.split(event?.durationSec)
        minutes = split.minutes
        seconds = split.seconds
        let source = event?.durationSource ?? .estimated
        durationSource = source == .timed ? .timed : .estimated
        count = event?.count ?? 1
        certainty = event?.certainty ?? .confirmed
        sleepState = event?.sleepState ?? .unknown
        semiology = event?.semiology ?? []
        triggers = event?.triggers ?? []
        postictal = event?.postictal ?? []
        injuries = event?.injuries ?? []
        emergency = event?.emergency ?? .noneNoted
        witnessed = event?.witnessed
        witnessRole = event?.witnessRole
        note = event?.note ?? ""
    }

    var durationSec: Int? {
        SeizurePresentation.seconds(minutes: minutes, seconds: seconds)
    }

    /// The two duration fields are empty or a whole duration of at most a day.
    var isValid: Bool {
        let typed = !(minutes.trimmingCharacters(in: .whitespaces).isEmpty && seconds.trimmingCharacters(in: .whitespaces).isEmpty)
        return !typed || durationSec != nil
    }

    func write(mode: SeizureEventWrite.Mode) -> SeizureEventWrite {
        SeizureEventWrite(
            mode: mode,
            typeProfileId: typeProfileId,
            onsetAt: SeizureDateFormat.wire(onset),
            onsetPrecision: onsetPrecision,
            durationSec: durationSec,
            durationSource: durationSec == nil ? .unknown : durationSource,
            count: count,
            certainty: certainty,
            sleepState: sleepState,
            semiology: semiology,
            triggers: triggers,
            postictal: postictal,
            injuries: injuries,
            emergency: emergency,
            witnessed: witnessed,
            witnessRole: witnessed == true ? witnessRole : nil,
            note: note
        )
    }
}
