import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The "after" side of the migration guide, written once in code so every
/// excerpt there compiles. Each view below is a real screen's excerpt with the
/// building block in place; the stores are stand-ins. The tests read what the
/// excerpts promise: a row card on the row grid, a pair that stacks before a
/// word breaks, formats through the helpers.
@MainActor
@Suite("Migration guide excerpts keep their promises")
struct MigrationGuideSnippetTests {
    // MARK: - Cards

    @Test("a card of one full row is one row pitch high with .rows and a card inset more without")
    func rowCardOnTheGrid() throws {
        let rows = try DesignContractMeasure.size(of: GuideCardAfter.LayoutCard())
        let free = try DesignContractMeasure.size(of: GuideCardAfter.LayoutCard(layout: .free))
        #expect(rows.height == HLLayout.rowPitch)
        #expect(free.height == HLLayout.rowMinHeight + 2 * HLLayout.cardInset)
    }

    @Test("three preset rows under a title stand on the grid")
    func titledRowCard() throws {
        let untitled = try DesignContractMeasure.size(of: GuideCardAfter.PresetCard(titled: false))
        let titled = try DesignContractMeasure.size(of: GuideCardAfter.PresetCard(titled: true))
        #expect(untitled.height == 3 * HLLayout.rowPitch)
        // The head (title, line under it, rule) stands above the same three rows.
        #expect(titled.height > untitled.height + HLLayout.rowGap)
    }

    // MARK: - Buttons

    @Test("the two document buttons share the width and stack in large type")
    func documentButtonPair() throws {
        let regular = try DesignContractMeasure.size(of: GuideButtonsAfter(hasDocuments: true))
        let large = try DesignContractMeasure.size(of: GuideButtonsAfter(hasDocuments: true), typeSize: .accessibility3)
        #expect(regular.height == HLLayout.buttonHeight)
        #expect(large.height >= 2 * HLLayout.buttonHeight + HLLayout.buttonGap)
    }

    @Test("without documents one button stands alone, at full width")
    func documentButtonAlone() throws {
        let alone = try DesignContractMeasure.size(of: GuideButtonsAfter(hasDocuments: false))
        #expect(alone.height == HLLayout.buttonHeight)
    }

    @Test("a set filter is a selected icon button, not another symbol")
    func filterIconButton() {
        let off = HLIconButton.appearance(style: .plain, isSelected: false)
        let on = HLIconButton.appearance(style: .plain, isSelected: true)
        #expect(off.filledSymbol == false)
        #expect(on.filledSymbol)
        #expect(on.ink == .full)
    }

    // MARK: - Formats

    @Test("date, number and span come from the helpers, in the language given")
    func formats() throws {
        let german = Locale(identifier: "de_DE")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9)))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 8)))

        #expect(HLDateFormat.dayMonth(date, relativeTo: now, locale: german, calendar: calendar) == "3. Nov.")
        #expect(HLValueFormat.number(3.5, fractionDigits: 0 ... 2, locale: german) == "3,5")
        #expect(HLValueFormat.range(3.5, 5.0, unit: .millimolesPerLiter, locale: german).contains("3,5"))
        #expect(HLValueFormat.pair(128, 82, unit: .millimetersOfMercury, locale: german).hasPrefix("128/82"))
        #expect(HLValueFormat.delta(-1.2, unit: .kilograms, locale: german).hasPrefix("-1,2"))
    }
}

// MARK: - Page frame and margins

/// `Insights/Sub/InsightsRecoveryPage.swift`: the hand-set scroll page.
private struct GuidePageAfter: View {
    var body: some View {
        HLPage {
            HLTabHeader("Recovery", titleIdentifier: "insights.page.header.title.recovery") {
                HLIconButton(systemImage: "info.circle", label: "Info", style: .bar) {}
            }
            HLCard {
                Text(verbatim: "…")
            }
        }
    }
}

/// `Settings/MoreScreen.swift`: a list with the page's margins and the card
/// surface on its rows.
private struct GuideListAfter: View {
    var body: some View {
        List {
            HLTabHeader("More") {
                HLIconButton(systemImage: "gearshape", label: "Settings", style: .bar) {}
            }
            .hlTabHeaderListRow()
            Section {
                HLSettingsActionRow(title: "Measurements", presents: .push) { Text(verbatim: "…") }
                HLSettingsActionRow(title: "Documents", presents: .push) { Text(verbatim: "…") }
            }
            .hlFormRowSurface()
        }
        .hlPageMargins()
    }
}

// MARK: - Cards

private enum GuideCardAfter {
    /// `Settings/Sub/SettingsDashboardScreen.swift`: one full row, so `.rows`.
    struct LayoutCard: View {
        var layout: HLCardLayout = .rows

        var body: some View {
            HLCard(layout: layout) {
                HLSettingsActionRow(title: "Customize tiles", presents: .create) {}
                    .accessibilityIdentifier("settings.dashboard.customizeRow")
            }
        }
    }

    /// `Settings/Sub/ServerAccessHeadersEditor.swift`: three full rows under a
    /// title and a line, so `.rows` too.
    struct PresetCard: View {
        var titled = true

        var body: some View {
            if titled {
                HLCard("Presets", subtitle: "Fills in the header names. Paste the values from your proxy.", layout: .rows) {
                    rows
                }
            } else {
                HLCard(layout: .rows) { rows }
            }
        }

        @ViewBuilder private var rows: some View {
            HLSettingsActionRow(title: "Cloudflare Access", presents: .create) {}
            HLSettingsActionRow(title: "Pangolin", presents: .create) {}
            HLSettingsActionRow(title: "Other header", presents: .create) {}
        }
    }

    /// `Insights/Sub/InsightsHealthStatusCard.swift`: `.elevated` is gone, the
    /// kicker inside is a card label.
    struct StatusCard: View {
        var body: some View {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLCardLabel("clinicalSignals.healthStatus.title")
                    Text(verbatim: "…")
                }
            }
        }
    }

    /// `PersonalRecords/RecordCard.swift`: the hand-built plate with its own
    /// padding, fill, hairline and shadow becomes a card.
    struct RecordCardAfter: View {
        var body: some View {
            Button {} label: {
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        Text(verbatim: "…")
                    }
                    .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
                }
            }
            .buttonStyle(HLPressableButtonStyle())
        }
    }
}

// MARK: - Headers

/// `Labs/BiomarkerDetailScreen.swift`: the header stands in the page, the
/// wrapping stack and its spacing go.
private struct GuideSectionAfter: View {
    var body: some View {
        HLPage {
            HLSectionHeader("biomarker.detail.lastMeasurement", rank: .area)
            HLCard {
                Text(verbatim: "…")
            }
            HLSectionHeader("biomarker.detail.allMeasurements", rank: .area)
            HLCard(layout: .rows) {
                HLRowLayout(title: Text(verbatim: "…"), indicator: .disclosure)
            }
        }
    }
}

// MARK: - Rows

/// `Charts/ChartDetailDrillDownRow.swift`: the card with a hand-made row and
/// chevron becomes a row card.
private struct GuideRowAfter: View {
    let subtitle: LocalizedStringKey = "No entries"

    var body: some View {
        HLCard(layout: .rows) {
            HLSettingsActionRow(title: "Show all measurements", subtitle: subtitle, presents: .push) {
                Text(verbatim: "…")
            }
        }
    }
}

/// `Cycle/CycleAdvancedSettingsSheet.swift`: a system switch with the row's
/// title.
private struct GuideToggleAfter: View {
    @State private var predictionEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $predictionEnabled) {
                    HLRowTitle("cycle.settings.prediction.label")
                }
            }
            .hlFormRowSurface()
        }
        .hlPageMargins()
    }
}

// MARK: - Buttons

/// `Documents/EpisodeDocumentsCard.swift`: two buttons side by side are a
/// pair; alone, one button.
private struct GuideButtonsAfter: View {
    let hasDocuments: Bool

    var body: some View {
        if hasDocuments {
            HLButtonPair {
                HLButton("documents.episodeCard.upload", systemImage: "arrow.up.doc", variant: .secondary) {}
            } secondary: {
                HLButton("documents.episodeCard.link", systemImage: "link", variant: .secondary) {}
            }
        } else {
            HLButton("documents.episodeCard.upload", systemImage: "arrow.up.doc", variant: .secondary) {}
        }
    }
}

/// `Documents/DocumentDetailScreen+Assist.swift`: the quiet second action is a
/// text link; `Documents/DocumentComponents.swift`: a set filter is a state.
private struct GuideQuietActionsAfter: View {
    let applyKey: LocalizedStringKey = "documents.assist.apply"
    @State private var isFiltered = true

    var body: some View {
        VStack {
            HLLinkButton(applyKey) {}
            HLIconButton(
                systemImage: "line.3.horizontal.decrease.circle",
                label: "documents.filter.groupLabel",
                isSelected: isFiltered,
                menu: {
                    Button("documents.filter.clear") { isFiltered = false }
                }
            )
            .accessibilityIdentifier("documents.toolbar.filter")
        }
    }
}

// MARK: - Sheets

/// `Cycle/CycleCustomSymptomEditor.swift`: the sheet head, the detents, the
/// guard against losing input come from the scaffold.
private struct GuideSheetAfter: View {
    let isNew: Bool
    @State private var label = ""
    @State private var error: String?

    var body: some View {
        HLSheetScaffold(
            isNew ? "cycle.custom.create.title" : "cycle.custom.edit.title",
            action: .save(isEnabled: !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                await save()
            },
            isDirty: !label.isEmpty
        ) {
            Form {
                Section {
                    TextField("cycle.custom.label.placeholder", text: $label)
                        .textInputAutocapitalization(.sentences)
                }
                .hlFormRowSurface()
                if let error {
                    Section { HLFormErrorText(error) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
        }
    }

    /// `true` when the sheet may close.
    private func save() async -> Bool {
        error = nil
        return true
    }
}

// MARK: - States

/// `Medications/MedicationsScreen+EmptyStates.swift` and the loading and
/// failure branches around it: one container decides what is shown.
private struct GuideStateAfter: View {
    let phase: HLLoadPhase

    var body: some View {
        HLPage {
            HLStateContainer(phase) {
                HLSkeleton(.capsule, width: 160, height: 16)
            } empty: {
                HLEmptyState(icon: "pills", title: "No medications yet") {
                    HLButton("Add medication", systemImage: "plus", variant: .secondary) {}
                }
                .accessibilityIdentifier("medications.empty")
            } content: {
                HLCard {
                    Text(verbatim: "…")
                }
            }
        }
    }
}

// MARK: - Delete ladder

/// `Mood/MoodHistoryScreen.swift`: a single entry whose store gives a way
/// back is deleted at once; editing stays beside it. The row stays the
/// screen's own row.
private struct GuideSwipeAfter: View {
    /// Stands in for `MoodEntryRow`.
    private struct MoodEntryRow: View {
        let entry: String
        var body: some View {
            Text(verbatim: entry)
        }
    }

    /// Stands in for `MoodStore`, whose `delete` reports success.
    private struct Store {
        func delete(_: String) async -> Bool {
            true
        }
    }

    let entries = ["a", "b"]
    private let store = Store()
    @State private var editing: String?

    var body: some View {
        List {
            Section {
                ForEach(entries, id: \.self) { entry in
                    MoodEntryRow(entry: entry)
                        .hlSwipeDelete(.undoable { _ = await store.delete(entry) }) {
                            Button { editing = entry } label: {
                                Label(HLControlWord.edit.key, systemImage: "pencil")
                            }
                        }
                }
            }
            .hlFormRowSurface()
        }
        .hlPageMargins()
    }
}

/// `Medications/MedicationSupplyEditorSheet.swift`: the delete button at the
/// end of a scrolling sheet asks first, through the ladder.
private struct GuideDeleteButtonAfter: View {
    @State private var isBusy = false

    var body: some View {
        ScrollView {
            VStack(spacing: HLLayout.cardGap) {
                HLDeleteButton(
                    "med.inventory.editor.delete.cta",
                    form: .page,
                    action: .confirmed(title: "med.inventory.editor.delete.confirm.title") { await delete() }
                )
                .disabled(isBusy)
                .accessibilityIdentifier("med.inventory.editor.delete")
            }
            .padding(HLLayout.pageInsets)
        }
    }

    private func delete() async {}
}

// MARK: - Formats

/// `Labs/AddLabResultSheet.swift`: the reference bounds as numbers with a
/// unit, a state and a message under the field.
private struct GuideNumberAfter: View {
    @State private var referenceLow: Double?
    @State private var referenceLowState: HLNumberEntry.State = .empty

    var body: some View {
        Form {
            Section("labs.add.freeText.section") {
                HLNumberField(
                    "labs.add.referenceLow",
                    value: $referenceLow,
                    state: $referenceLowState,
                    unit: .millimolesPerLiter,
                    fractionDigits: 0 ... 2
                )
            }
            .hlFormRowSurface()
        }
        .hlPageMargins()
    }
}

// MARK: - Headers, round two

/// `Labs/BiomarkerDetailScreen.swift`: a title from data, named for the UI tests.
private struct GuideBiomarkerHeadAfter: View {
    let displayName: String

    var body: some View {
        HLTabHeader(
            LocalizedStringResource(String.LocalizationValue(displayName)),
            titleIdentifier: "insights.page.header.title.biomarker"
        ) {
            HLIconButton(systemImage: "slider.horizontal.3", label: "biomarker.detail.editRange", style: .bar, menu: {
                Button("biomarker.detail.editRange") {}
                Button("labs.aliases.edit") {}
            })
            .accessibilityIdentifier("biomarker.detail.gear")
        }
    }
}

// MARK: - Icon buttons, chips, segments, input

/// `Insights/Sub/IntradayPulseBlock.swift`: the raw 44 pt frame becomes an
/// icon button.
private struct GuideIconButtonAfter: View {
    var body: some View {
        HLIconButton(systemImage: "chevron.left", label: "insights.intraday.previousDay") {
            Task { await goToPreviousDay() }
        }
        .accessibilityIdentifier("insights.metric.pulse.intraday.previous")
    }

    private func goToPreviousDay() async {}
}

/// `Labs/LabResultEntryMode.swift`: hand-built choice chips become chips.
private struct GuideChipsAfter: View {
    let suggestions = ["positive", "negative", "borderline"]
    @State private var text = ""

    var body: some View {
        HLFlowLayout {
            ForEach(suggestions, id: \.self) { label in
                HLChip(verbatim: label, isSelected: text == label) { text = label }
            }
        }
    }
}

/// `Medications/ActiveMedicationRow.swift`: a hand-built mark becomes a badge,
/// a coloured state a status pill.
private struct GuideBadgeAfter: View {
    var body: some View {
        VStack {
            HLBadge(String(localized: "medications.recordOnly.badge"), icon: "doc.text")
                .accessibilityIdentifier("medications.recordOnly.badge")
            HLStatusPill(.connected(label: String(localized: "Connected")))
        }
    }
}

/// `Labs/LabResultEntryMode.swift`: the raw segmented picker becomes the
/// adaptive one.
private struct GuideSegmentAfter: View {
    private enum ResultType: String, CaseIterable, Identifiable {
        case numeric, qualitative
        var id: String {
            rawValue
        }

        var pickerLabel: LocalizedStringKey {
            switch self {
            case .numeric: "labs.form.numeric"
            case .qualitative: "labs.form.qualitative"
            }
        }
    }

    @State private var resultType: ResultType = .numeric
    private let labels = ResultType.allCases.map(\.pickerLabel)

    var body: some View {
        HLAdaptiveSegmentedPicker("labs.form.resultType", selection: $resultType, labels: labels) {
            ForEach(ResultType.allCases) { type in
                Text(type.pickerLabel).tag(type)
            }
        }
    }
}

/// `Insights/Sub/SleepStageCompositionCard.swift`: the range picker in a card
/// becomes the page's floating period control.
private struct GuidePeriodAfter: View {
    private enum Window: String, HLRangeOption {
        case week, month
        var id: String {
            rawValue
        }

        var label: String {
            rawValue
        }

        var rangeAccessibilityLabel: String {
            rawValue
        }
    }

    @State private var window: Window = .week

    var body: some View {
        HLPage {
            HLCard { Text(verbatim: "…") }
        }
        .safeAreaInset(edge: .bottom) {
            HLFloatingPeriodControl(selection: $window)
        }
    }
}

/// `Cycle/CycleCaptureSheet.swift`: a stepper over a decimal range becomes a
/// number field; a date is a row like any other.
private struct GuideInputAfter: View {
    @State private var bbt: Double? = 36.5
    @State private var date = Date(timeIntervalSince1970: 0)

    var body: some View {
        Form {
            Section {
                HLNumberField("cycle.capture.bbt.label", value: $bbt, unit: .celsius, range: 35 ... 39, fractionDigits: 2 ... 2)
                DatePicker(selection: $date, displayedComponents: .date) {
                    HLRowTitle("cycle.capture.date")
                }
            }
            .hlFormRowSurface()
        }
        .hlPageMargins()
    }
}
