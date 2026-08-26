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
            Text("reminders.create.label.header")
        }
    }

    var typeSection: some View {
        Section {
            Picker(selection: $selectedType) {
                Text("reminders.create.type.freeText").tag(String?.none)
                ForEach(MeasurementReminderType.catalog, id: \.wire) { entry in
                    Text(entry.label).tag(String?.some(entry.wire))
                }
            } label: {
                Text("reminders.create.type.label")
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.type")
        } footer: {
            Text("reminders.create.type.footer")
        }
    }

    // MARK: - Cadence (interval ↔ RRULE)

    var cadenceSection: some View {
        Section {
            Picker(selection: $cadenceMode) {
                Text("reminders.create.cadence.interval").tag(ReminderCadenceMode.interval)
                Text("reminders.create.cadence.rrule").tag(ReminderCadenceMode.rrule)
            } label: {
                Text("reminders.create.cadence.label")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("MeasurementReminderCreateSheet.cadenceMode")

            switch cadenceMode {
            case .interval:
                intervalStepper
            case .rrule:
                rruleControls
            }
        } footer: {
            Text(
                cadenceMode == .interval
                    ? "reminders.create.schedule.footer"
                    : "reminders.create.schedule.rrule.footer"
            )
        }
    }

    private var intervalStepper: some View {
        Stepper(value: $intervalDays, in: 1 ... 3650) {
            HStack {
                Text("reminders.create.interval.label")
                Spacer()
                Text(String(format: String(localized: "reminders.schedule.everyNDays"), intervalDays))
                    .foregroundStyle(HLText.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityIdentifier("MeasurementReminderCreateSheet.interval")
    }

    @ViewBuilder
    private var rruleControls: some View {
        Picker(selection: $rrulePreset) {
            ForEach(RRulePreset.allCases) { preset in
                Text(preset.label).tag(preset)
            }
        } label: {
            Text("reminders.create.rrule.preset.label")
        }
        .accessibilityIdentifier("MeasurementReminderCreateSheet.rrulePreset")

        if rrulePreset == .custom {
            TextField(String(localized: "reminders.create.rrule.customPlaceholder"), text: $customRrule)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("MeasurementReminderCreateSheet.customRrule")

            if !customRrule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !rruleIsValid {
                Text("reminders.create.rrule.invalid")
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .accessibilityIdentifier("MeasurementReminderCreateSheet.rruleInvalid")
            }
        }
    }

    // MARK: - Anchor date

    var anchorSection: some View {
        Section {
            Toggle(isOn: $useAnchorDate) {
                Text("reminders.create.anchor.toggle")
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.anchorToggle")

            if useAnchorDate {
                DatePicker(
                    selection: $anchorDate,
                    displayedComponents: .date
                ) {
                    Text("reminders.create.anchor.label")
                }
                .accessibilityIdentifier("MeasurementReminderCreateSheet.anchorDate")
            }
        } footer: {
            Text("reminders.create.anchor.footer")
        }
    }

    // MARK: - Notify hour

    var notifyHourSection: some View {
        Section {
            Picker(selection: $notifyHour) {
                ForEach(0 ..< 24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            } label: {
                Text("reminders.create.notifyHour.label")
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.notifyHour")
        }
    }

    // MARK: - Location

    var locationSection: some View {
        Section {
            TextField(String(localized: "reminders.create.location.placeholder"), text: $location)
                .accessibilityIdentifier("MeasurementReminderCreateSheet.location")
        } header: {
            Text("reminders.create.location.label")
        }
    }

    // MARK: - Enabled (per-reminder, edit only)

    var enabledSection: some View {
        Section {
            Toggle(isOn: $enabled) {
                Text("reminders.create.enabled.label")
            }
            .accessibilityIdentifier("MeasurementReminderCreateSheet.enabled")
        } footer: {
            Text("reminders.create.enabled.footer")
        }
    }
}
