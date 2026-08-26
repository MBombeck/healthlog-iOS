import SwiftUI

/// **G4 (AUDIT-onboarding) — onboarding baseline-profile parity.**
///
/// Web onboarding (step 3) collects a baseline profile — display name, height,
/// date of birth, gender — via `PUT /api/auth/profile`. iOS already owns this
/// write path: `EditProfileScreen` → `SettingsStore.updateProfile(_:)` →
/// `PATCH /api/user/profile`. This step mirrors the web intake during
/// onboarding, writing through that **existing** store with a `ProfilePatch`.
/// No parallel write path is introduced.
///
/// **Skippable, never a gate.** A user can finish onboarding with everything
/// blank and edit it later in Settings → Profile. "Continue" sends only the
/// fields actually filled in (a diff `ProfilePatch`); "Later" advances
/// untouched. Failures don't block onboarding — the write is retryable in
/// Settings.
///
/// **Server-only surface.** Profile lives on the server, so this step is
/// reached on the server branch only (standalone has no server). The
/// flow inserts it after the anamnesis step, before `done`.
struct BaselineProfileStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var store: SettingsStore?
    @State private var displayName = ""
    @State private var heightCm = ""
    @State private var hasDateOfBirth = false
    @State private var dateOfBirth = Date.now
    @State private var gender: GenderOption = .unspecified
    @State private var isSaving = false
    @State private var appeared = false
    @State private var hydrated = false
    /// audit 02 · M-5 — set when the profile save fails so the step surfaces the
    /// error instead of silently advancing as if the fields were persisted.
    @State private var saveFailed = false
    /// 08-10 — set when the height field holds something that is neither blank
    /// nor a plausible height. The old code simply *dropped* such a value
    /// (`if let parsed = Int(…), (50…300).contains(parsed)`) and, when it was
    /// the only thing typed, advanced through `guard dirty else { onNext() }`:
    /// the user's input was gone and the step said nothing.
    @State private var invalidHeight = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                header
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)

                card
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)
                    .animation(cardAnimation, value: appeared)

                Spacer(minLength: HLSpace.xxl)
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.top, HLSpace.xxl)
        }
        // The numberPad height field has no return key; let a downward drag on
        // the scroll dismiss the keyboard so the user is never trapped behind it
        // (QA-b198 Design-M3).
        .scrollDismissesKeyboard(.interactively)
        .background(HLColor.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: HLSpace.sm) {
                if invalidHeight {
                    Text("onboarding.baselineProfile.invalidHeight")
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.baselineProfile.invalidHeight")
                }
                if saveFailed {
                    Text("onboarding.save.failed")
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.baselineProfile.saveFailed")
                }
                HLButton(
                    String(localized: "Continue"),
                    variant: .primary,
                    size: .large,
                    isLoading: isSaving
                ) {
                    Task { await saveThenContinue() }
                }
                .accessibilityIdentifier("onboarding.baselineProfile.continue")
                HLButton(String(localized: "Later"), variant: .ghost) {
                    onSkip()
                }
                .accessibilityIdentifier("onboarding.baselineProfile.skip")
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.bottom, HLSpace.xxxl)
            .background(HLColor.background)
        }
        .task { await prepareStore() }
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Image(systemName: "person.text.rectangle")
                // Canonical onboarding hero glyph (`HLIconSize.display`, mono).
                .font(.hlIcon(HLIconSize.display))
                .foregroundStyle(HLText.primary)
            Text(String(localized: "onboarding.baselineProfile.title"))
                .font(.hlTitle1)
                .foregroundStyle(HLText.primary)
            Text(String(localized: "onboarding.baselineProfile.subtitle"))
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    field(
                        label: String(localized: "Display name"),
                        prompt: String(localized: "onboarding.baselineProfile.name.prompt"),
                        text: $displayName,
                        keyboard: .default,
                        identifier: "onboarding.baselineProfile.name"
                    )
                    Divider().opacity(0.4)
                    field(
                        label: String(localized: "Height (cm)"),
                        prompt: String(localized: "Optional"),
                        text: $heightCm,
                        keyboard: .numberPad,
                        identifier: "onboarding.baselineProfile.height"
                    )
                    // The message describes what is in the field, so it goes
                    // away the moment the field stops saying it.
                    .onChange(of: heightCm) { _, _ in invalidHeight = false }
                    Divider().opacity(0.4)
                    Toggle(String(localized: "Set date of birth"), isOn: $hasDateOfBirth)
                        .accessibilityIdentifier("onboarding.baselineProfile.hasDateOfBirth")
                    if hasDateOfBirth {
                        DatePicker(
                            String(localized: "Date of birth"),
                            selection: $dateOfBirth,
                            in: minBirthDate ... .now,
                            displayedComponents: .date
                        )
                        .accessibilityIdentifier("onboarding.baselineProfile.dateOfBirth")
                    }
                    Divider().opacity(0.4)
                    Picker(String(localized: "Gender"), selection: $gender) {
                        ForEach(GenderOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .accessibilityIdentifier("onboarding.baselineProfile.gender")
                }
            }
            Text(String(localized: "onboarding.baselineProfile.footer"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(
        label: String,
        prompt: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        identifier: String
    ) -> some View {
        HStack {
            Text(label)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.md)
            TextField(prompt, text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: - Persist

    private func prepareStore() async {
        guard store == nil, let container else { return }
        let s = container.settingsStore
        store = s
        guard !hydrated else { return }
        // Hydrate drafts from any existing server profile (HealthKit may have
        // already populated some of these) so re-onboarding doesn't blank a
        // value the user already has.
        if let profile = s.profile {
            displayName = profile.displayName ?? ""
            heightCm = profile.heightCm.map(String.init) ?? ""
            gender = GenderOption(serverValue: profile.gender)
            if let dob = profile.dateOfBirth {
                dateOfBirth = dob
                hasDateOfBirth = true
            } else {
                dateOfBirth = defaultBirthDate
            }
        } else {
            dateOfBirth = defaultBirthDate
        }
        hydrated = true
    }

    /// Builds a diff `ProfilePatch` from the filled fields and saves via the
    /// existing `SettingsStore.updateProfile`. A blank-everything step is a
    /// no-op save (we still advance). Reuses the exact same write path as
    /// `EditProfileScreen` — no parallel profile write is introduced.
    private func saveThenContinue() async {
        guard let store else {
            onNext()
            return
        }
        // A new attempt starts with no verdict on screen, so the message the
        // user reads always describes the tap they just made.
        saveFailed = false
        invalidHeight = false
        var patch = ProfilePatch()
        var dirty = false

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            patch.displayName = .some(trimmedName)
            dirty = true
        }
        // 08-10 — optional is not the same as unchecked. Blank may advance;
        // anything non-blank must be a height or the step stays and says so.
        switch Self.validateHeight(heightCm) {
        case .blank:
            break
        case let .valid(centimetres):
            patch.heightCm = .some(centimetres)
            dirty = true
        case .invalid:
            invalidHeight = true
            return
        }
        if hasDateOfBirth {
            patch.dateOfBirth = .some(dateOfBirth)
            dirty = true
        }
        if let serverGender = gender.serverValue {
            patch.gender = .some(serverGender)
            dirty = true
        }

        guard dirty else {
            onNext()
            return
        }

        isSaving = true
        let ok = await store.updateProfile(patch)
        isSaving = false
        // audit 02 · M-5 — surface a failed profile write instead of advancing
        // as if saved. The user can retry Continue or tap "Later" to skip.
        if !ok {
            saveFailed = true
            return
        }
        onNext()
    }

    // MARK: - Height (08-10)

    /// What the height field holds. Three answers, because an optional field
    /// has three states and the old code only had two: it folded "left empty"
    /// and "typed something impossible" into the same silent discard.
    enum HeightEntry: Equatable {
        /// Nothing was typed. Legitimate — the whole step is skippable.
        case blank
        /// A plausible height, in centimetres.
        case valid(Int)
        /// Non-blank and not a height. The only state that must block.
        case invalid
    }

    /// The pure form of the rule, so all six boundaries (blank, 49, 50, 300,
    /// 301, non-numeric) are checkable without a view tree. The band is the
    /// server's: `50…300` cm, the same one `EditProfileScreen` enforces.
    nonisolated static func validateHeight(_ raw: String) -> HeightEntry {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .blank }
        guard let parsed = Int(trimmed), (50 ... 300).contains(parsed) else { return .invalid }
        return .valid(parsed)
    }

    // MARK: - Date bounds

    private var minBirthDate: Date {
        DateComponents(calendar: .current, year: 1900, month: 1, day: 1).date ?? .distantPast
    }

    private var defaultBirthDate: Date {
        Calendar.current.date(byAdding: .year, value: -30, to: .now) ?? .now
    }

    // MARK: - Entrance

    private var entranceOffset: CGFloat {
        reduceMotion ? 0 : 14
    }

    private var cardAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.3, dampingFraction: 0.85).delay(0.05)
    }
}
