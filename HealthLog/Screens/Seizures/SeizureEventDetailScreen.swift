import SwiftUI

/// One recorded seizure: what was recorded about it, the rescue doses given
/// with how each worked, and who logged it. Edit and delete in the page's
/// menu, like an illness episode.
struct SeizureEventDetailScreen: View {
    @Environment(\.dismiss) private var dismiss

    let store: SeizuresStore
    let eventID: String

    @State private var showEdit = false
    @State private var showAddDose = false

    private var event: SeizureEventDTO? {
        store.event(id: eventID)
    }

    var body: some View {
        HLPage {
            if let event {
                headerCard(event)
                factsCard(event)
                if let note = event.note, !note.isEmpty {
                    noteCard(note)
                }
                rescueSection(event)
                if let error = store.lastError {
                    HLFormErrorText(error)
                }
                if let logged = SeizurePresentation.loggedBy(event) {
                    Text(verbatim: logged)
                        .hlText(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(Text(verbatim: event.map { SeizurePresentation.typeName(of: $0, in: store.diary) }
                ?? String(localized: "seizures.detail.title")))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions(pageActions)
        .hlDeleteConfirmation()
        .accessibilityIdentifier("seizures.detail")
        .sheet(isPresented: $showEdit) {
            if let event { SeizureEventSheet(store: store, editing: event) }
        }
        .sheet(isPresented: $showAddDose) {
            if let event { SeizureRescueDoseSheet(store: store, event: event) }
        }
    }

    private var pageActions: HLTabHeaderActions {
        guard let event else { return .none }
        return [
            .more(identifier: "seizures.detail.menu") {
                Button("seizures.detail.edit", systemImage: "pencil") { showEdit = true }
                HLDeleteMenuItem(.confirmed(title: "seizures.sheet.deleteTitle", message: "seizures.sheet.deleteBody") {
                    if await store.delete(event) { dismiss() }
                })
            }
        ]
    }

    private func headerCard(_ event: SeizureEventDTO) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLFactGroup {
                    HLFactRow("seizures.sheet.onset", value: SeizurePresentation.onset(event))
                    HLFactRow("seizures.sheet.duration", value: durationValue(event))
                    if event.count > 1 {
                        HLFactRow("seizures.sheet.count", value: event.count.formatted())
                    }
                    HLFactRow("seizures.sheet.certainty", value: event.certainty.label)
                    HLFactRow("seizures.sheet.sleepState", value: event.sleepState.label)
                    if let ilae = event.effectiveIlaeType, ilae != .unrecognized {
                        HLFactRow("seizures.types.ilaeType", value: ilae.label)
                    }
                }
                flagBadges(event)
            }
        }
    }

    private func durationValue(_ event: SeizureEventDTO) -> String {
        guard event.durationSec != nil else { return SeizurePresentation.duration(nil) }
        return [SeizurePresentation.duration(event.durationSec), event.durationSource.label].joined(separator: ", ")
    }

    @ViewBuilder
    private func flagBadges(_ event: SeizureEventDTO) -> some View {
        let overT1 = event.flags.overT1 == true
        let prolonged = event.flags.prolonged == true
        if overT1 || prolonged {
            HLFlowLayout {
                if overT1 { HLBadge(String(localized: "seizures.event.flag.overT1"), tone: .warning) }
                if prolonged { HLBadge(String(localized: "seizures.event.flag.prolonged"), tone: .warning) }
            }
            HLSourcesLink(topic: .seizures)
        }
    }

    @ViewBuilder
    private func factsCard(_ event: SeizureEventDTO) -> some View {
        let facts = Self.facts(event)
        if !facts.isEmpty {
            HLCard {
                HLFactGroup {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        HLFactRow(label: Text(fact.label), value: Text(verbatim: fact.value))
                    }
                }
            }
        }
    }

    /// The optional details, each only when recorded.
    static func facts(_ event: SeizureEventDTO) -> [(label: LocalizedStringKey, value: String)] {
        var out: [(label: LocalizedStringKey, value: String)] = []
        func list(_ words: [String]) -> String {
            words.formatted(.list(type: .and))
        }
        if !event.semiology.isEmpty { out.append(("seizures.sheet.semiology", list(event.semiology.map(\.label)))) }
        if !event.postictal.isEmpty { out.append(("seizures.sheet.postictal", list(event.postictal.map(\.label)))) }
        if !event.injuries.isEmpty { out.append(("seizures.sheet.injuries", list(event.injuries.map(\.label)))) }
        if event.emergency != .noneNoted, event.emergency != .unrecognized {
            out.append(("seizures.sheet.emergency", event.emergency.label))
        }
        if !event.triggers.isEmpty { out.append(("seizures.sheet.triggers", list(event.triggers.map(\.label)))) }
        if let witnessed = event.witnessed {
            let answer = witnessed ? String(localized: "seizures.answer.yes") : String(localized: "seizures.answer.no")
            let role = witnessed ? event.witnessRole.map(\.label) : nil
            out.append(("seizures.sheet.witnessed", [answer, role].compactMap { $0 }.joined(separator: ", ")))
        }
        return out
    }

    private func noteCard(_ note: String) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HLCardLabel("seizures.sheet.note")
                Text(verbatim: note)
                    .hlText(.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func rescueSection(_ event: SeizureEventDTO) -> some View {
        HLSectionHeader("seizures.rescue.title", rank: .area)
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                if event.rescueDoses.isEmpty {
                    Text("seizures.rescue.none").hlText(.note)
                }
                ForEach(event.rescueDoses) { dose in
                    SeizureRescueDoseRow(store: store, dose: dose)
                }
                HLButton("seizures.rescue.add", systemImage: "plus", variant: .secondary) { showAddDose = true }
                    .accessibilityIdentifier("seizures.rescue.add")
                Text("seizures.rescue.intakeHint")
                    .hlText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One rescue dose: drug, dose and route, when it was given, and how it
/// worked, changeable in place; removing it asks first.
struct SeizureRescueDoseRow: View {
    let store: SeizuresStore
    let dose: SeizureRescueDoseDTO

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: dose.medicationName.isEmpty ? String(localized: "seizures.rescue.medication") : dose.medicationName)
                    .hlText(.rowTitle)
                Spacer(minLength: HLSpace.sm)
                if let given = SeizureDateFormat.parse(dose.givenAt) {
                    Text(verbatim: HLTimeFormat.time(given)).hlText(.rowSubtitle)
                }
            }
            if let line = SeizurePresentation.doseLine(dose) {
                Text(verbatim: line).hlText(.rowSubtitle)
            }
            HStack {
                Menu {
                    Picker(selection: Binding(get: { dose.effect }, set: { effect in
                        Task { await store.setRescueEffect(effect, dose: dose) }
                    })) {
                        ForEach(SeizureRescueEffect.choices, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        Text("seizures.rescue.effect")
                    }
                } label: {
                    Label {
                        Text(verbatim: "\(String(localized: "seizures.rescue.effect")): \(dose.effect.label)")
                    } icon: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .hlText(.rowSubtitle)
                }
                .accessibilityIdentifier("seizures.rescue.effect")
                Spacer(minLength: HLSpace.sm)
                HLDeleteButton(
                    "seizures.rescue.remove",
                    form: .icon,
                    action: .confirmed(
                        title: "seizures.rescue.removeTitle",
                        message: "seizures.rescue.removeBody",
                        word: "seizures.rescue.remove"
                    ) {
                        await store.deleteRescueDose(dose)
                    }
                )
                .accessibilityIdentifier("seizures.rescue.remove")
            }
        }
    }
}
