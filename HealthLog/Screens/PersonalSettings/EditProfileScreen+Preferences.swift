import SwiftUI

/// **W-B187 (Settings consolidation §A.1) — personal-attribute preferences.**
///
/// The two "how I read my own data" prefs were relocated INTO the profile
/// editor so Profile is the single home for personal-attribute settings:
///   - **Units** (weight / blood pressure / blood glucose) — moved here from
///     `SettingsAccountScreen`. Weight / blood pressure are local UserDefaults
///     prefs (`SettingsStore.weightUnit` etc.); the glucose unit is the
///     account's (#108, `setGlucoseUnit`). The server stores canonical SI and
///     conversion happens at display time. Accessibility identifiers (`settings.units.*`) are preserved verbatim
///     so existing selectors / UI tests keep resolving.
///   - **Time format** (auto / 24h / 12h) — moved here from the Appearance page
///     (`SettingsDashboardScreen`). Server-backed (`User.timeFormat`); the picker
///     binds to `SettingsStore.setTimeFormat(_:)`, which optimistically mirrors
///     locally and PATCHes `/api/user/profile` — the exact endpoint this profile
///     editor already drives.
///
/// Split into its own file to keep `EditProfileScreen` under the file-/type-length
/// budget, mirroring the `+PatientIdentity` split. Both sections read/write the
/// same `SettingsStore` bindings as before — this is a relocation, not a rewrite.
extension EditProfileScreen {
    /// The "Units" section: display-unit pickers for weight, blood pressure and
    /// blood glucose. Each binds straight to its `SettingsStore` property (the
    /// `didSet` persists to UserDefaults), exactly as it did on the Account page.
    var unitsSection: some View {
        Section {
            // Build 9 (Server-Prefs) / 9.1 — server-owned unit system. A segmented
            // metric/imperial control above the three detail pickers; writes go
            // through `setUnitPreference` (optimistic mirror + PATCH). With no
            // explicit weight override, the weight picker follows this binary.
            HLAdaptiveSegmentedPicker(
                "settings.unitSystem.title",
                selection: unitSystemBinding,
                labels: HLUnitPreference.allCases.map { LocalizedStringKey($0.label) }
            ) {
                ForEach(HLUnitPreference.allCases, id: \.self) { pref in
                    Text(pref.label).tag(pref)
                }
            }
            .accessibilityIdentifier("settings.units.systemPicker")
            unitRow(label: "Weight", identifier: "settings.units.weightPicker") {
                Picker(String(localized: "Weight"), selection: bindable(\.weightUnit)) {
                    ForEach(WeightUnit.allCases) { unit in
                        Text(unit.unitSuffix).tag(unit)
                    }
                }
                .labelsHidden()
            }
            unitRow(label: "Blood pressure", identifier: "settings.units.bloodPressurePicker") {
                Picker(String(localized: "Blood pressure"), selection: bindable(\.bloodPressureUnit)) {
                    ForEach(BloodPressureUnit.allCases) { unit in
                        Text(unit.unitSuffix).tag(unit)
                    }
                }
                .labelsHidden()
            }
            unitRow(label: "Blood glucose", identifier: "settings.units.glucosePicker") {
                // The glucose unit belongs to the account: the pick
                // PATCHes `/api/auth/me/glucose-unit` (optimistic, reverted on
                // failure) so the server converts the series into the same unit.
                Picker(String(localized: "Blood glucose"), selection: glucoseUnitBinding) {
                    ForEach(GlucoseUnit.allCases) { unit in
                        Text(unit.unitSuffix).tag(unit)
                    }
                }
                .labelsHidden()
            }
        } header: {
            HLSectionHeader("Units")
        }
        .hlFormRowSurface()
        // UI-Standard R2 — der Abschnitts-Footer („Lege fest, wie Gewicht,
        // Blutdruck und Glukose angezeigt werden.") zählte die drei Zeilen
        // auf, die direkt darüber „Gewicht", „Blutdruck" und „Blutzucker"
        // heißen. Tautologie, gefallen.
    }

    /// Time and date format in one card: an auto / 24h / 12h picker and an
    /// auto / DMY / MDY / YMD picker, each bound to the server-backed
    /// `SettingsStore` setter so the pick PATCHes `/api/user/profile` (server
    /// `User.dateFormat`, v1.21.0) and every rendered clock and date snaps
    /// immediately. The header names the pair, so no row repeats it.
    var formatsSection: some View {
        Section {
            // Form pickers: at AX sizes the value wraps under the title
            // instead of being cut in the middle.
            HLFormPicker(
                "settings.time_format.title",
                selection: timeFormatBinding,
                options: HLTimeFormat.allCases
            ) { format in
                Text(format.label)
            }
            .accessibilityIdentifier("editProfile.timeFormatPicker")
            HLFormPicker(
                "settings.date_format.title",
                selection: dateFormatBinding,
                options: HLDateFormat.allCases
            ) { format in
                Text(format.label)
            }
            .accessibilityIdentifier("editProfile.dateFormatPicker")
        } header: {
            HLSectionHeader("profile.formats.header")
        }
        .hlFormRowSurface()
    }

    /// Binding for the server-backed time-format pick: reads the resolved
    /// preference, writes through ``SettingsStore/setTimeFormat(_:)`` (optimistic
    /// local mirror + PATCH).
    private var timeFormatBinding: Binding<HLTimeFormat> {
        Binding(
            get: { settings.timeFormat },
            set: { newValue in Task { await settings.setTimeFormat(newValue) } }
        )
    }

    /// Binding for the server-backed date-format pick: reads the resolved
    /// preference, writes through ``SettingsStore/setDateFormat(_:)`` (optimistic
    /// local mirror + PATCH).
    private var dateFormatBinding: Binding<HLDateFormat> {
        Binding(
            get: { settings.dateFormat },
            set: { newValue in Task { await settings.setDateFormat(newValue) } }
        )
    }

    /// Binding for the server-backed unit-system pick: reads the resolved
    /// preference, writes through ``SettingsStore/setUnitPreference(_:)``
    /// (optimistic mirror + PATCH). Mirrors ``timeFormatBinding``.
    private var glucoseUnitBinding: Binding<GlucoseUnit> {
        Binding(
            get: { settings.glucoseUnit },
            set: { newValue in Task { await settings.setGlucoseUnit(newValue) } }
        )
    }

    private var unitSystemBinding: Binding<HLUnitPreference> {
        Binding(
            get: { settings.unitPreference },
            set: { newValue in Task { await settings.setUnitPreference(newValue) } }
        )
    }

    private func unitRow(
        label: LocalizedStringKey,
        identifier: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        LabeledContent {
            content()
        } label: {
            HLRowTitle(label)
        }
        .accessibilityIdentifier(identifier)
    }

    private func bindable<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }
}
