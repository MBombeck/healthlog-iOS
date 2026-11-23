import SwiftUI

/// The person's seizure types (web `seizure-type-sheet.tsx`): set up once,
/// ideally with the care team. The name, the ILAE 2025 type and the usual
/// duration are edited here; the emergency plan and its rescue drug are shown
/// and set on the web. A type that seizures name can only be archived.
struct SeizureTypesScreen: View {
    let store: SeizuresStore

    @State private var editing: SeizureTypeEditTarget?

    var body: some View {
        List {
            let types = store.diary?.types ?? []
            let active = types.filter { !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }
            let archived = types.filter(\.archived)
            if types.isEmpty {
                Section {
                    HLEmptyState(
                        icon: SeizureSymbols.module,
                        title: "seizures.types.emptyTitle",
                        message: "seizures.types.emptyDescription"
                    ) {
                        HLButton("seizures.types.newTitle", systemImage: "plus", variant: .secondary) { editing = .new }
                            .accessibilityIdentifier("seizures.types.empty.add")
                    }
                    .hlFreeAreaListRow()
                }
            }
            if !active.isEmpty {
                Section {
                    ForEach(active) { type in row(type) }
                } footer: {
                    Text("seizures.types.description")
                }
                .hlFormRowSurface()
            }
            if !archived.isEmpty {
                Section {
                    ForEach(archived) { type in row(type) }
                } header: {
                    HLSectionHeader("seizures.types.archived")
                }
                .hlFormRowSurface()
            }
            if let error = store.lastError {
                Section { HLFormErrorText(error) }
                    .hlFormRowSurface()
            }
        }
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        .hlPageMargins()
        .navigationTitle(Text("seizures.types.title"))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions([.add(label: "seizures.types.newTitle", identifier: "seizures.types.add") { editing = .new }])
        .accessibilityIdentifier("seizures.types")
        .sheet(item: $editing) { target in
            SeizureTypeSheet(store: store, editing: target.type)
        }
    }

    private func row(_ type: SeizureTypeDTO) -> some View {
        HLRowButton { editing = .edit(type) } label: {
            HLRow(
                title: Text(verbatim: type.displayName),
                detail: Text(verbatim: SeizureTypeCopy.detail(type)),
                status: SeizurePresentation.rescueName(type).map { HLRowStatus(String(localized: "seizures.types.rescueLine \($0)")) },
                accessory: .chevron
            ) {
                HLRowGlyph(symbol: SeizureSymbols.module)
            }
        }
        .accessibilityIdentifier("seizures.types.row")
        .hlSwipeDelete(.confirmed(title: "seizures.types.deleteTitle", message: "seizures.types.deleteBody") {
            await store.deleteType(type)
        }) {
            Button(
                type.archived ? "seizures.types.unarchive" : "seizures.types.archive",
                systemImage: type.archived ? "tray.and.arrow.up" : "archivebox"
            ) {
                Task { await store.updateType(id: type.id, SeizureTypeWrite(archived: !type.archived)) }
            }
            .tint(HLAccent.userBrandTint)
        }
    }
}

/// Which type the sheet edits.
enum SeizureTypeEditTarget: Identifiable {
    case new
    case edit(SeizureTypeDTO)

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(type): type.id
        }
    }

    var type: SeizureTypeDTO? {
        if case let .edit(type) = self { return type }
        return nil
    }
}

/// Pure wording of the types list.
enum SeizureTypeCopy {
    /// The ILAE name, with the usual duration when one is saved.
    static func detail(_ type: SeizureTypeDTO) -> String {
        let usual = type.usualDurationSec.map { "\(String(localized: "seizures.types.usualDuration")) \(SeizureDateFormat.clock($0))" }
        return HLRowDetail.joined([type.ilaeType.label, usual]) ?? type.ilaeType.label
    }

    /// The picker's name of a type: the parent entry reads "Not sure: …".
    static func pickerName(_ type: SeizureIlaeType) -> String {
        type.isParent ? String(localized: "seizures.types.notSure \(type.ilaeClass.label)") : type.label
    }
}

/// Add or edit one seizure type.
struct SeizureTypeSheet: View {
    let store: SeizuresStore
    let editing: SeizureTypeDTO?

    @State private var label: String
    @State private var ilaeClass: SeizureIlaeClass
    @State private var ilaeType: SeizureIlaeType
    @State private var minutes: String
    @State private var seconds: String
    @State private var saveError: String?

    init(store: SeizuresStore, editing: SeizureTypeDTO?) {
        self.store = store
        self.editing = editing
        _label = State(initialValue: editing?.label ?? "")
        let type = editing?.ilaeType.ilaeClass == .unrecognized ? .focalUndetermined : (editing?.ilaeType ?? .focalUndetermined)
        _ilaeType = State(initialValue: type)
        _ilaeClass = State(initialValue: type.ilaeClass)
        let split = SeizurePresentation.split(editing?.usualDurationSec)
        _minutes = State(initialValue: split.minutes)
        _seconds = State(initialValue: split.seconds)
    }

    private var usualSeconds: Int? {
        SeizurePresentation.seconds(minutes: minutes, seconds: seconds)
    }

    private var canSave: Bool {
        let name = label.trimmingCharacters(in: .whitespaces)
        let typedDuration = !(minutes.isEmpty && seconds.isEmpty)
        return !name.isEmpty && name.count <= SeizureTypeWrite.labelMax && (!typedDuration || (usualSeconds ?? 0) > 0)
    }

    var body: some View {
        HLSheetScaffold(
            editing == nil ? "seizures.types.newTitle" : "seizures.types.editTitle",
            action: editing == nil ? .add(isEnabled: canSave, perform: { await save() }) : .save(
                isEnabled: canSave,
                perform: { await save() }
            ),
            isDirty: true
        ) {
            Form {
                Group {
                    Section {
                        TextField("seizures.types.label", text: $label)
                            .accessibilityIdentifier("seizures.types.label")
                    } footer: {
                        Text("seizures.types.labelHint")
                    }
                    Section {
                        Picker(selection: $ilaeClass) {
                            ForEach(SeizureIlaeClass.choices, id: \.self) { Text($0.label).tag($0) }
                        } label: {
                            HLRowTitle("seizures.types.class")
                        }
                        .onChange(of: ilaeClass) { _, newClass in
                            if ilaeType.ilaeClass != newClass {
                                ilaeType = SeizureIlaeType.types(in: newClass).first ?? .unclassified
                            }
                        }
                        Picker(selection: $ilaeType) {
                            ForEach(SeizureIlaeType.types(in: ilaeClass), id: \.self) { type in
                                Text(verbatim: SeizureTypeCopy.pickerName(type)).tag(type)
                            }
                        } label: {
                            HLRowTitle("seizures.types.ilaeType")
                        }
                    } footer: {
                        Text("seizures.types.description")
                    }
                    Section {
                        HStack(spacing: HLSpace.md) {
                            TextField("seizures.sheet.minutes", text: $minutes).keyboardType(.numberPad)
                            Text(verbatim: ":").hlText(.rowSubtitle).accessibilityHidden(true)
                            TextField("seizures.sheet.seconds", text: $seconds).keyboardType(.numberPad)
                        }
                    } header: {
                        Text("seizures.types.usualDuration")
                    } footer: {
                        Text("seizures.types.usualHint")
                    }
                    if let editing {
                        planSection(editing)
                    }
                    if let saveError {
                        Section { HLFormErrorText(saveError) }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
        }
    }

    /// The plan and its drug, read-only: both are set on the web.
    private func planSection(_ type: SeizureTypeDTO) -> some View {
        Section {
            if let plan = type.plan {
                Text(verbatim: plan)
                    .hlText(.prose)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("seizures.types.plan")
            } else {
                Text("seizures.types.noPlan").hlText(.note)
            }
            if let name = SeizurePresentation.rescueName(type) {
                Text("seizures.types.rescueLine \(name)").hlText(.rowSubtitle)
            }
        } header: {
            Text("seizures.types.plan")
        } footer: {
            Text("seizures.plan.webHint")
        }
    }

    private func save() async -> Bool {
        saveError = nil
        let write = SeizureTypeWrite(
            label: label,
            ilaeType: ilaeType,
            usualDurationSec: usualSeconds.map { RecordPatchField<Int>.set($0) }
                ?? (editing?.usualDurationSec == nil ? RecordPatchField<Int>.unchanged : .clear)
        )
        let saved: SeizureTypeDTO? = if let editing {
            await store.updateType(id: editing.id, write)
        } else {
            await store.createType(write)
        }
        if saved != nil { return true }
        saveError = store.lastError ?? String(localized: "seizures.saveError")
        return false
    }
}

/// The record's cluster rule beside NICE's (web `cluster-rule-card.tsx`).
struct SeizureRuleSheet: View {
    let store: SeizuresStore

    @State private var count: Int
    @State private var hours: Int
    @State private var saveError: String?

    init(store: SeizuresStore) {
        self.store = store
        let rule = store.diary?.settings.rule ?? .standard
        _count = State(initialValue: rule.count)
        _hours = State(initialValue: rule.windowHours)
    }

    var body: some View {
        let nice = store.diary?.settings.niceRule ?? .nice
        HLSheetScaffold("seizures.rule.title", action: .save { await save() }, isDirty: true) {
            Form {
                Group {
                    Section {
                        Stepper(value: $count, in: SeizureClusterRule.countRange) {
                            stepperLabel("seizures.rule.count", value: count)
                        }
                        .accessibilityIdentifier("seizures.rule.count")
                        Stepper(value: $hours, in: SeizureClusterRule.windowRange) {
                            stepperLabel("seizures.rule.hours", value: hours)
                        }
                        .accessibilityIdentifier("seizures.rule.hours")
                    } header: {
                        Text(verbatim: SeizurePresentation.ruleText(SeizureClusterRule(count: count, windowHours: hours)))
                    } footer: {
                        Text("seizures.rule.explainer \(nice.count) \(nice.windowHours)")
                    }
                    if let saveError {
                        Section { HLFormErrorText(saveError) }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
        }
    }

    private func stepperLabel(_ title: LocalizedStringKey, value: Int) -> some View {
        HStack {
            HLRowTitle(title)
            Spacer(minLength: HLSpace.sm)
            Text(verbatim: value.formatted()).hlText(.rowValue)
        }
    }

    private func save() async -> Bool {
        saveError = nil
        if await store.updateRule(SeizureClusterRule(count: count, windowHours: hours)) { return true }
        saveError = store.lastError ?? String(localized: "seizures.rule.invalid")
        return false
    }
}
