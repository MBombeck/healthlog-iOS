import SwiftUI

/// `MeasurementReminderCreateSheet` form-section subviews (Build 6.4). Extracted
/// from the main sheet (file_length / type_body_length discipline) — the state,
/// body, and submit path stay in `MeasurementReminderCreateSheet.swift`.
extension MeasurementReminderCreateSheet {
    // MARK: - Label + type

    var labelSection: some View {
        Section {
            TextField(String(localized: "reminders.create.label.placeholder"), text: $label)
                .focused($labelFocused)
                .submitLabel(.done)
                .accessibilityIdentifier("MeasurementReminderCreateSheet.label")
        } header: {
            HLSectionHeader("reminders.create.label.header")
        }
        .hlFormRowSurface()
    }

    var typeSection: some View {
        Section {
            // A form picker: at AX sizes the value wraps under the title
            // instead of being cut in the middle ("Freite…wert)").
            HLFormPicker(
                "reminders.create.type.label",
                selection: $selectedType,
                options: [String?.none] + MeasurementReminderType.catalog.map { String?.some($0.wire) }
            ) { wire in
                Self.typeLabel(for: wire)
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.type")
        } footer: {
            Text("reminders.create.type.footer")
        }
        .hlFormRowSurface()
    }

    /// The picker text of a type, the free-text choice for `nil`.
    static func typeLabel(for wire: String?) -> Text {
        guard let wire, let entry = MeasurementReminderType.catalog.first(where: { $0.wire == wire }) else {
            return Text("reminders.create.type.freeText")
        }
        return Text(entry.label)
    }

    // MARK: - Cadence (interval ↔ RRULE)

    @ViewBuilder
    var cadenceSection: some View {
        Section {
            HLAdaptiveSegmentedPicker(
                "reminders.create.cadence.label",
                selection: $cadenceMode,
                labels: ["reminders.create.cadence.interval", "reminders.create.cadence.rrule"]
            ) {
                Text("reminders.create.cadence.interval").tag(ReminderCadenceMode.interval)
                Text("reminders.create.cadence.rrule").tag(ReminderCadenceMode.rrule)
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.cadenceMode")

            switch cadenceMode {
            case .interval:
                intervalStepper
            case .rrule:
                rrulePresetPicker
            }
        } footer: {
            // No footer saying who computes the next due date. The
            // rare hand-written rule waits behind a quiet "Advanced" line.
            if cadenceMode == .rrule {
                advancedRuleToggle
            }
        }
        .hlFormRowSurface()
        if cadenceMode == .rrule, rrulePreset == .custom {
            customRuleSection
        }
    }

    /// At AX sizes title and value stand above the stepper; beside it the
    /// title broke into a column of syllables ("Wie-der-ho-lung").
    @ViewBuilder
    private var intervalStepper: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HLRowTitle("reminders.create.interval.label")
                intervalValue
                Stepper(value: $intervalDays, in: 1 ... 3650) {
                    HLRowTitle("reminders.create.interval.label")
                }
                .labelsHidden()
                .accessibilityIdentifier("MeasurementReminderCreateSheet.interval")
            }
        } else {
            Stepper(value: $intervalDays, in: 1 ... 3650) {
                HStack {
                    HLRowTitle("reminders.create.interval.label")
                    Spacer()
                    intervalValue
                }
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.interval")
        }
    }

    private var intervalValue: some View {
        Text(String(format: String(localized: "reminders.schedule.everyNDays"), intervalDays))
            .foregroundStyle(HLText.secondary)
            .monospacedDigit()
    }

    private var rrulePresetPicker: some View {
        // The custom rule shows as the picker's value only while it is in
        // use; it is chosen through "Advanced", not offered in the list.
        HLFormPicker(
            "reminders.create.rrule.preset.label",
            selection: presetSelection,
            options: RRulePreset.allCases.filter { $0 != .custom || rrulePreset == .custom }
        ) { preset in
            Text(preset.label)
        }
        .accessibilityIdentifier("MeasurementReminderCreateSheet.rrulePreset")
    }

    /// Picking a standard repeat closes the custom rule again.
    private var presetSelection: Binding<RRulePreset> {
        Binding(
            get: { rrulePreset },
            set: { newValue in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { rrulePreset = newValue }
            }
        )
    }

    /// The centred text link that folds the custom rule out beneath the card.
    /// Open means the custom rule is in use; closing it returns to the repeat
    /// that was picked before.
    private var advancedRuleToggle: some View {
        let isExpanded = rrulePreset == .custom
        return HLLinkButton("Advanced", isExpanded: isExpanded) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                if isExpanded {
                    rrulePreset = presetBeforeCustom
                } else {
                    presetBeforeCustom = rrulePreset
                    rrulePreset = .custom
                }
            }
        }
        .accessibilityIdentifier("MeasurementReminderCreateSheet.advanced")
    }

    private var customRuleSection: some View {
        Section {
            TextField(String(localized: "reminders.create.rrule.customPlaceholder"), text: $customRrule)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("MeasurementReminderCreateSheet.customRrule")

            if !customRrule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !rruleIsValid {
                Text("reminders.create.rrule.invalid")
                    .hlText(.rowStatus, status: HLColor.statusBad)
                    .accessibilityIdentifier("MeasurementReminderCreateSheet.rruleInvalid")
            }
        } header: {
            HLSectionHeader("reminders.create.rrule.custom")
        } footer: {
            Text("reminders.create.rrule.custom.help")
        }
        .hlFormRowSurface()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Anchor date

    var anchorSection: some View {
        Section {
            Toggle(isOn: $useAnchorDate) {
                HLRowTitle("reminders.create.anchor.toggle")
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.anchorToggle")

            if useAnchorDate {
                DatePicker(
                    selection: $anchorDate,
                    displayedComponents: .date
                ) {
                    HLRowTitle("reminders.create.anchor.label")
                }
                .accessibilityIdentifier("MeasurementReminderCreateSheet.anchorDate")
            }
        }
        .hlFormRowSurface()
        // Counting from the day it is created is the expected default;
        // the toggle names the other choice.
    }

    // MARK: - Notify hour

    var notifyHourSection: some View {
        Section {
            // The device's clock: 09:00 in German, 9:00 AM in English.
            HLFormPicker(
                "reminders.create.notifyHour.label",
                selection: $notifyHour,
                options: Array(0 ..< 24)
            ) { hour in
                Text(verbatim: ClockTimeText.text(hour: hour))
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.notifyHour")
        }
        .hlFormRowSurface()
    }

    // MARK: - Location

    var locationSection: some View {
        Section {
            TextField(String(localized: "reminders.create.location.placeholder"), text: $location)
                .accessibilityIdentifier("MeasurementReminderCreateSheet.location")
        } header: {
            HLSectionHeader("reminders.create.location.label")
        }
        .hlFormRowSurface()
    }

    // MARK: - Enabled (per-reminder, edit only)

    var enabledSection: some View {
        Section {
            Toggle(isOn: $enabled) {
                HLRowTitle("reminders.create.enabled.label")
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.enabled")
        }
        .hlFormRowSurface()
    }
}
