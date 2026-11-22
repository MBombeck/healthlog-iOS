import SwiftUI

/// Open a new illness episode. Captures the full episode form, including an
/// optional end date and parent relationship for flares/recurrences.
struct AddEpisodeSheet: View {
    let store: IllnessStore

    @State private var label = ""
    @State private var type: IllnessType = .infection
    @State private var lifecycle: IllnessLifecycle = .acute
    @State private var onsetAt = Date.now
    @State private var hasResolvedAt = false
    @State private var resolvedAt = Date.now
    @State private var parentConditionId: String?
    @State private var note = ""
    @State private var saveError: String?
    /// The form as it opened, for the discard guard.
    @State private var baseline: [AnyHashable]?

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
            onsetAt <= Date.now &&
            (!hasResolvedAt || (resolvedAt >= onsetAt && resolvedAt <= Date.now))
    }

    private var parentCandidates: [IllnessEpisodeDTO] {
        store.episodes
    }

    var body: some View {
        HLSheetScaffold(
            "illness.add.title",
            action: .add(isEnabled: canSave) { await save() },
            isDirty: isDirty
        ) {
            Form {
                Group {
                    Section("illness.add.section.about") {
                        TextField("illness.add.label", text: $label)
                        Picker(selection: $type) {
                            ForEach(IllnessType.allCases) { type in
                                Text(type.localizedLabel).tag(type)
                            }
                        } label: {
                            HLRowTitle("illness.add.type")
                        }
                        Picker(selection: $lifecycle) {
                            ForEach(IllnessLifecycle.allCases) { lifecycle in
                                Text(lifecycle.localizedLabel).tag(lifecycle)
                            }
                        } label: {
                            HLRowTitle("illness.add.lifecycle")
                        }
                        .onChange(of: lifecycle) { _, newValue in
                            if !newValue.allowsParent {
                                parentConditionId = nil
                            }
                        }
                        if lifecycle.allowsParent {
                            Picker(selection: $parentConditionId) {
                                Text("illness.add.parent.none").tag(nil as String?)
                                ForEach(parentCandidates) { candidate in
                                    Text(candidate.label).tag(Optional(candidate.id))
                                }
                            } label: {
                                HLRowTitle("illness.add.parent")
                            }
                        }
                    }
                    Section("illness.add.section.onset") {
                        DatePicker(
                            selection: $onsetAt,
                            in: ...Date.now,
                            displayedComponents: [.date, .hourAndMinute]
                        ) {
                            HLRowTitle("illness.add.onsetAt")
                        }
                        .onChange(of: onsetAt) { _, newValue in
                            if resolvedAt < newValue {
                                resolvedAt = newValue
                            }
                        }
                        Toggle(isOn: $hasResolvedAt) {
                            HLRowTitle("illness.add.resolved.toggle")
                        }
                        if hasResolvedAt {
                            DatePicker(
                                selection: $resolvedAt,
                                in: onsetAt ... Date.now,
                                displayedComponents: [.date, .hourAndMinute]
                            ) {
                                HLRowTitle("illness.add.resolvedAt")
                            }
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
                .hlFormRowSurface()
            }
            .hlPageMargins()
        }
        .onAppear { if baseline == nil { baseline = formFingerprint } }
    }

    /// Every field the person can change, in one comparable value.
    private var formFingerprint: [AnyHashable] {
        [label, type, lifecycle, onsetAt, hasResolvedAt, resolvedAt, parentConditionId, note]
    }

    private var isDirty: Bool {
        guard let baseline else { return false }
        return baseline != formFingerprint
    }

    /// `true` when the sheet may close.
    private func save() async -> Bool {
        saveError = nil
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
        if await store.createEpisode(body) != nil { return true }
        saveError = store.lastError ?? String(localized: "illness.save.failed")
        return false
    }
}
