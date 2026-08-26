import PhotosUI
import SwiftUI
import UIKit

/// Edit form behind the avatar-hero NavigationLink in `ProfileScreen`
/// (and the Konto card in `SettingsAccountScreen`).
/// Drives `SettingsStore.updateProfile(_:)` with a **diff payload** so the
/// server only sees the fields the user actually changed.
///
/// Validation:
/// - `displayName`: 1-50 chars (trimmed), nullable to clear.
/// - `heightCm`: 50-300, nullable to clear.
/// - `dateOfBirth`: 1900-01-01 … today.
/// - `gender`: enum picker, nullable to clear ("Keine Angabe").
///
/// **Auto-save UX (v0.8.3 W-C):** there is no explicit Save button anymore.
/// Field edits auto-commit through a short debounce (`commitDebounceNanos`),
/// and a final commit fires on `onDisappear` so nothing is lost when the user
/// taps back. Each commit reuses `buildPatch()` to send only the diverged
/// fields via `PATCH /api/user/profile`; on success the baseline resets and a
/// lightweight "Gespeichert"/"Saved" cue + `.sensoryFeedback(.success)`
/// confirm the write. Failures surface inline via `SettingsStore.error`. The
/// avatar still uploads immediately + independently through `AvatarStore`
/// (W1c) — we now also pulse the same success feedback after a silent upload
/// completes. M2-A6 / v0.4.1, reworked v0.8.3 W-C from the TestFlight "Save
/// feels redundant / photo-pick gives no feedback" report
/// (`.planning/v083-reorder/R5-profile-save.md`).
///
/// **v0.5.5.2 — first-edit gate.** The red "Bitte einen Anzeigenamen
/// eingeben." footer used to fire the moment the screen opened on a
/// profile whose server-side `displayName` was empty. Operator read that
/// as "screen broken on open" rather than "field-needs-input". We now
/// gate the footer behind `hasUserEditedDisplayName` — the validation
/// itself still runs (an invalid field is never auto-committed), it just
/// no longer shouts before any keyboard interaction.
struct EditProfileScreen: View {
    /// W-B187 — not `private` so the `+Preferences` extension (units +
    /// time-format sections, split out for file-length hygiene) can read the
    /// store for its bindings, mirroring how `+PatientIdentity` reaches the
    /// shared `@State`.
    @Environment(SettingsStore.self) var settings
    @Environment(AvatarStore.self) private var avatarStore
    /// QoL-A2 (Felt-craft #5) — gate the "Saved" cue fade on reduce-motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// v0.8.0 W11 — PhotosPicker selection for the profile avatar.
    @State private var avatarPickerItem: PhotosPickerItem?
    /// Drives the inline "Could not load the photo" footer when the picked
    /// item can't be read as image data on-device (before any upload).
    @State private var avatarPickError: Bool = false
    /// v0.8.2 W1c (A4) — `true` from the instant a pick fires until its
    /// `loadTransferable` resolves (which can take seconds for a large iCloud
    /// asset). The picker disables on `isUploading || isPreparing` so a second
    /// pick can't start during the transferable load — only `isUploading`
    /// (set inside `AvatarStore.upload`) covered the *network* window, leaving
    /// the load window open to a racing re-pick.
    @State private var isPreparing: Bool = false
    /// v0.8.2 W1c (A4) — handle to the in-flight pick→upload task. A re-pick
    /// cancels the prior task so the last selection wins `image`/`loadedKey`
    /// deterministically instead of "whichever upload finished last".
    @State private var pickTask: Task<Void, Never>?

    @State private var displayName: String = ""
    @State private var dateOfBirth: Date = .distantPast
    @State private var hasDateOfBirth: Bool = false
    @State private var gender: GenderOption = .unspecified
    @State private var heightCm: String = ""
    /// v0.10.0 — extended patient-identity fields (full legal name, health
    /// insurer, KVNR). Feed the Doctor-Report cover + FHIR Patient. The KVNR
    /// is sensitive PII held only in this @State + the in-memory profile —
    /// never logged. Not `private` so the `+PatientIdentity` extension (split
    /// out for file-length hygiene) can bind the section's TextFields.
    @State var fullName: String = ""
    @State var insurerName: String = ""
    @State var insuranceNumber: String = ""
    /// v0.11.0 — insurer IKNR (9-digit Institutionskennzeichen). Feeds the
    /// FHIR `Coverage` payor Organization identifier. Identifying PII — held
    /// only in this @State + the in-memory profile, never logged.
    @State var insurerIkNumber: String = ""
    /// v0.8.3 W-C — `true` while an auto-commit `PATCH` is in flight. Drives the
    /// inline progress affordance next to the "Saved" cue.
    @State var isSaving: Bool = false
    /// Toggled on every successful commit (field PATCH or photo upload) to fire
    /// `.sensoryFeedback(.success)`.
    @State private var saveSucceeded: Bool = false
    /// v0.8.3 W-C — drives the brief "Saved"/"Gespeichert" pill. Set `true` on a
    /// successful commit, auto-cleared after a short delay so the cue is a
    /// transient confirmation, not a permanent badge.
    @State var showSavedCue: Bool = false
    /// v0.8.3 W-C — debounced auto-commit handle. A new field edit cancels the
    /// prior pending commit so we coalesce rapid keystrokes into one PATCH.
    @State private var commitTask: Task<Void, Never>?
    /// v0.8.3 W-C — clears the transient "Saved" cue after it has been shown.
    @State private var savedCueTask: Task<Void, Never>?
    /// Not `private` so the `+PatientIdentity` diff helper can read it.
    @State var baseline: ProfileFormState = .empty
    /// v0.5.5.2 — flips to `true` on the first keystroke. The footer-error
    /// rendering checks this so the "Bitte einen Anzeigenamen eingeben."
    /// copy doesn't surface on the initial server-prefill of an empty
    /// `displayName`. The auto-commit keeps honouring the validation
    /// regardless, so an empty/invalid field is never persisted.
    @State private var hasUserEditedDisplayName: Bool = false
    /// Suppresses the `.onChange(of: displayName)` side-effect during
    /// `loadBaseline`. Without it the prefill assignment would itself
    /// flip the "user touched it" flag and defeat the gate's purpose.
    @State private var isApplyingBaseline: Bool = false

    var body: some View {
        Form {
            avatarSection

            Section {
                LabeledContent {
                    TextField(
                        String(localized: "Required"),
                        text: $displayName
                    )
                    .textContentType(.name)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("editProfile.displayName")
                } label: {
                    Text("Display name")
                }
            } header: {
                Text("Identity")
            } footer: {
                if hasUserEditedDisplayName, let length = displayNameValidationError {
                    HLFormErrorText(length)
                } else {
                    Text("How you appear in the app and in the Doctor report.")
                }
            }

            Section {
                Toggle(String(localized: "Set date of birth"), isOn: $hasDateOfBirth)
                    .accessibilityIdentifier("editProfile.hasDateOfBirth")
                if hasDateOfBirth {
                    DatePicker(
                        String(localized: "Date of birth"),
                        selection: $dateOfBirth,
                        in: minBirthDate ... .now,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("editProfile.dateOfBirth")
                }
            } header: {
                Text("Date of birth")
            } footer: {
                Text("Used for age-based reference ranges (e.g. pulse zones).")
            }

            Section {
                Picker(String(localized: "Gender"), selection: $gender) {
                    ForEach(GenderOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .accessibilityIdentifier("editProfile.gender")
            } header: {
                Text("Gender")
            }

            Section {
                LabeledContent {
                    TextField(
                        String(localized: "Optional"),
                        text: $heightCm
                    )
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("editProfile.heightCm")
                } label: {
                    Text("Height (cm)")
                }
            } header: {
                Text("Height")
            } footer: {
                if let err = heightValidationError {
                    HLFormErrorText(err)
                } else {
                    Text("50 – 300 cm. Leave empty to clear the value.")
                }
            }

            patientIdentitySection

            // W-B187 (Settings consolidation §A.1) — personal-attribute prefs
            // relocated here so Profile is the single home for "how I read my
            // own data": display units (from Account) + time format (from
            // Appearance). Both bind to the same `SettingsStore` paths as before.
            unitsSection
            timeFormatSection
            dateFormatSection

            if let error = settings.error {
                Section {
                    Label(error.userFacingDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("editProfile.error")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .hlScreenBackground()
        // v0.5.x C-9 — iOS 26+ soft scroll-edge so Form content blurs into
        // the navigation Liquid Glass instead of clipping cleanly.
        // iOS 18-25: no-op (system stays flat-translucent).
        .hlScrollEdgeSoft()
        .navigationTitle(Text("Edit Profile"))
        .navigationBarTitleDisplayMode(.inline)
        // v0.8.3 W-C — the explicit Save button is gone; the toolbar now hosts
        // a transient "Saved" confirmation (or an in-flight spinner) so the
        // auto-commit is never silent.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                savedCue
            }
        }
        .sensoryFeedback(.success, trigger: saveSucceeded)
        .onAppear(perform: loadBaseline)
        // v0.8.3 W-C — flush any pending commit when the screen leaves. A
        // debounced edit that hasn't fired yet (user types then immediately
        // taps back) must still reach the server, so we commit un-debounced
        // here. `commitNow` is idempotent — a no-op when there's no diff.
        .onDisappear {
            commitTask?.cancel()
            savedCueTask?.cancel()
            commitNow()
        }
        // v0.5.5.2 — gate the displayName validation footer behind the
        // first real edit. `isApplyingBaseline` filters out the prefill
        // assignment in `loadBaseline` so server-empty displayNames don't
        // immediately surface as red errors on screen-open.
        // v0.8.3 W-C — a real edit also schedules a debounced auto-commit.
        .onChange(of: displayName) { _, _ in
            guard !isApplyingBaseline else { return }
            hasUserEditedDisplayName = true
            scheduleCommit()
        }
        // v0.8.3 W-C — auto-commit on the remaining editable fields. Toggling
        // DOB on/off, the date itself, the gender picker and the height field
        // all feed the same debounced commit so every change is persisted.
        // `scheduleCommit` itself no-ops while `isApplyingBaseline` is set, so
        // the prefill assignments in `loadBaseline` never trigger a write.
        .onChange(of: hasDateOfBirth) { _, _ in scheduleCommit() }
        .onChange(of: dateOfBirth) { _, _ in scheduleCommit() }
        .onChange(of: gender) { _, _ in scheduleCommit() }
        .onChange(of: heightCm) { _, _ in scheduleCommit() }
        // v0.10.0 — auto-commit the patient-identity fields on the same
        // debounce as every other editable field.
        .onChange(of: fullName) { _, _ in scheduleCommit() }
        .onChange(of: insurerName) { _, _ in scheduleCommit() }
        .onChange(of: insuranceNumber) { _, _ in scheduleCommit() }
        .onChange(of: insurerIkNumber) { _, _ in scheduleCommit() }
        // v0.8.0 W11 — load the picked photo's bytes on-device, then upload
        // through AvatarStore (downscale + multipart + idempotent POST).
        // v0.8.2 W1c (A4) — flip `isPreparing` synchronously here (disables
        // the picker before the transferable load), and cancel any prior
        // in-flight pick so a rapid re-pick can't race two uploads.
        .onChange(of: avatarPickerItem) { _, newValue in
            guard let newValue else { return }
            avatarPickError = false
            isPreparing = true
            pickTask?.cancel()
            pickTask = Task { await handlePickedAvatar(newValue) }
        }
        // Resolve the existing avatar for the preview when the screen opens.
        .task(id: settings.profile?.avatarUrl) {
            await avatarStore.load(avatarURLPath: settings.profile?.avatarUrl)
        }
    }

    // MARK: - Avatar section (W11)

    private var avatarSection: some View {
        // Snapshot the MainActor-isolated store state into plain locals so the
        // @Sendable PhotosPicker label closure captures values, not the store.
        let hasImage = avatarStore.image != nil
        return Section {
            HStack(spacing: HLSpace.md) {
                HLProfileAvatar(
                    size: 64,
                    email: settings.profile?.email,
                    initials: settings.profile?.avatarInitials ?? "?",
                    image: avatarStore.image
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    PhotosPicker(
                        selection: $avatarPickerItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        // `hasImage` is a Sendable Bool snapshotted above, so
                        // it captures cleanly into the @Sendable label closure.
                        // The two literals extract as separate catalogue keys.
                        if hasImage {
                            Text("Change photo")
                        } else {
                            Text("Add photo")
                        }
                    }
                    .disabled(avatarStore.isUploading || isPreparing)
                    .accessibilityIdentifier("editProfile.avatarPicker")

                    if hasImage {
                        Button(role: .destructive) {
                            Task { await avatarStore.remove() }
                        } label: {
                            Text("Remove photo")
                        }
                        .disabled(avatarStore.isUploading || isPreparing)
                        .accessibilityIdentifier("editProfile.avatarRemove")
                    }
                }

                Spacer()

                // v0.8.3 W-C — label the in-flight state so the disabled
                // picker reads as progress, not a freeze. `isPreparing` covers
                // the on-device transferable load (seconds for large iCloud
                // assets); `isUploading` covers the network upload window.
                if avatarStore.isUploading || isPreparing {
                    HStack(spacing: HLSpace.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading photo…")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Loading photo…"))
                    .accessibilityIdentifier("editProfile.avatarProgress")
                }
            }
            .padding(.vertical, HLSpace.xs)
        } header: {
            Text("Photo")
        } footer: {
            if avatarPickError {
                HLFormErrorText(String(localized: "Could not load the selected photo."))
            } else if let err = avatarStore.error {
                HLFormErrorText(err.userFacingDescription)
            } else {
                Text("Your photo is stored on your own HealthLog server — never shared with a third party.")
            }
        }
    }

    /// Reads the picked item's bytes on-device, decodes to `UIImage`, then
    /// hands off to `AvatarStore.upload` (which downscales + uploads). On a
    /// read failure surfaces the inline footer; never leaves a broken state.
    ///
    /// v0.8.2 W1c (A4): `isPreparing` is cleared in a `defer` so the picker
    /// re-enables on every exit (success, decode failure, or cancellation).
    /// A cancellation between the transferable load and the upload (a re-pick
    /// superseded this task) bails before mutating store/image state, so the
    /// last selection wins.
    private func handlePickedAvatar(_ item: PhotosPickerItem) async {
        defer { isPreparing = false }
        // A7 LOW — decode off the MainActor. A large picked photo decoded via
        // `UIImage(data:)` on the calling actor (this view method) blocks the
        // main thread before `AvatarStore.upload` downscales; hop to a detached
        // task so the picker dismiss / UI doesn't hitch on the decode.
        let uiImage: UIImage? = if let data = try? await item.loadTransferable(type: Data.self) {
            await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
        } else {
            nil
        }
        guard let uiImage else {
            // A superseding re-pick cancelled this task mid-load — don't flash
            // the error footer for a deliberately-abandoned pick.
            if Task.isCancelled { return }
            avatarPickError = true
            return
        }
        // The newer pick cancelled us after the bytes arrived — defer to it
        // rather than racing a second upload to the same store.
        if Task.isCancelled { return }
        let uploaded = await avatarStore.upload(uiImage)
        // Reset the selection so re-picking the same asset fires onChange again.
        avatarPickerItem = nil
        // v0.8.3 W-C — W1c uploads the photo silently; pulse the same success
        // confirmation the field auto-commit uses so the upload is never
        // feedback-less. A surfaced upload error is left to the avatar footer.
        if uploaded { signalSaved() }
    }

    // MARK: - Load + diff

    private func loadBaseline() {
        guard let profile = settings.profile else { return }
        isApplyingBaseline = true
        defer { isApplyingBaseline = false }
        let snapshot = ProfileFormState(
            displayName: profile.displayName ?? "",
            dateOfBirth: profile.dateOfBirth,
            gender: GenderOption(serverValue: profile.gender),
            heightCm: profile.heightCm.map(String.init) ?? "",
            fullName: profile.fullName ?? "",
            insurerName: profile.insurerName ?? "",
            insuranceNumber: profile.insuranceNumber ?? "",
            insurerIkNumber: profile.insurerIkNumber ?? ""
        )
        baseline = snapshot
        displayName = snapshot.displayName
        if let dob = snapshot.dateOfBirth {
            dateOfBirth = dob
            hasDateOfBirth = true
        } else {
            dateOfBirth = defaultBirthDate
            hasDateOfBirth = false
        }
        gender = snapshot.gender
        heightCm = snapshot.heightCm
        applyIdentityBaseline(snapshot)
    }

    // MARK: - Auto-commit (v0.8.3 W-C)

    /// Debounce window for the field auto-commit. Coalesces a burst of
    /// keystrokes / picker taps into a single PATCH rather than one-per-edit.
    private static let commitDebounceNanos: UInt64 = 600_000_000 // 0.6 s

    /// How long the transient "Saved" cue stays on screen after a successful
    /// commit before it fades back out.
    private static let savedCueLingerNanos: UInt64 = 1_600_000_000 // 1.6 s

    /// Schedules a debounced auto-commit. Re-scheduling cancels the prior
    /// pending commit, so rapid edits collapse into one write. No-op while the
    /// baseline prefill is being applied (those assignments aren't user edits).
    func scheduleCommit() {
        guard !isApplyingBaseline else { return }
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: Self.commitDebounceNanos)
            if Task.isCancelled { return }
            commitNow()
        }
    }

    /// Commits the current diff immediately (no debounce). Used by `onDisappear`
    /// as a safety net so an edit the user makes right before tapping back is
    /// never lost. Idempotent: a no-op when validation fails or nothing changed.
    private func commitNow() {
        guard validationPasses, let patch = buildPatch() else { return }
        Task { await commitProfile(patch) }
    }

    /// Sends the field diff and, on success, re-baselines + confirms.
    private func commitProfile(_ patch: ProfilePatch) async {
        isSaving = true
        let success = await settings.updateProfile(patch)
        isSaving = false
        guard success else { return }
        // Reset baseline so subsequent edits compute diff against the
        // freshly-persisted state (and so a re-commit of the same values
        // becomes a no-op).
        loadBaseline()
        signalSaved()
    }

    /// Fires the success haptic and shows the transient "Saved" cue. Shared by
    /// the field auto-commit and the silent avatar upload (W1c) so every
    /// successful write surfaces the same confirmation.
    private func signalSaved() {
        saveSucceeded.toggle()
        withAnimation(reduceMotion ? nil : HLMotion.smooth) { showSavedCue = true }
        savedCueTask?.cancel()
        savedCueTask = Task {
            try? await Task.sleep(nanoseconds: Self.savedCueLingerNanos)
            if Task.isCancelled { return }
            withAnimation(reduceMotion ? nil : HLMotion.smooth) { showSavedCue = false }
        }
    }

    /// Construct a minimal `ProfilePatch` containing only fields that diverge
    /// from the baseline. Returns nil if every field is unchanged.
    private func buildPatch() -> ProfilePatch? {
        var patch = ProfilePatch()
        var dirty = false

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != baseline.displayName {
            patch.displayName = trimmedName.isEmpty ? .some(nil) : .some(trimmedName)
            dirty = true
        }

        // DOB diff: handle the on/off toggle as a "clear" gesture.
        let newDOB: Date? = hasDateOfBirth ? dateOfBirth : nil
        if !sameDay(newDOB, baseline.dateOfBirth) {
            patch.dateOfBirth = .some(newDOB)
            dirty = true
        }

        if gender != baseline.gender {
            patch.gender = .some(gender.serverValue)
            dirty = true
        }

        let trimmedHeight = heightCm.trimmingCharacters(in: .whitespaces)
        if trimmedHeight != baseline.heightCm {
            if trimmedHeight.isEmpty {
                patch.heightCm = .some(nil)
            } else if let parsed = Int(trimmedHeight) {
                patch.heightCm = .some(parsed)
            }
            dirty = true
        }

        // v0.10.0 — patient-identity diffs live in the +PatientIdentity split.
        if applyIdentityDiff(to: &patch) {
            dirty = true
        }

        return dirty ? patch : nil
    }

    private func sameDay(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (a?, b?): Calendar.current.isDate(a, inSameDayAs: b)
        default: false
        }
    }

    // MARK: - Validation

    private var displayNameValidationError: String? {
        EditProfileFormValidator.displayNameError(for: displayName)
    }

    private var heightValidationError: String? {
        EditProfileFormValidator.heightError(for: heightCm)
    }

    /// v0.5.5.2 — testable mirror of the live footer-gating logic. Returns
    /// the same string the footer renders, given the input `displayName`
    /// and whether the user has typed since the screen opened. Tests pin
    /// this so a future refactor that breaks the "no red footer on initial
    /// open" contract fails fast instead of surfacing in operator hands.
    /// `nonisolated` so the Swift Testing suite can invoke it without
    /// hopping onto MainActor (the function reads zero @State — pure
    /// value-level computation).
    nonisolated static func displayNameFooterError(displayName: String, hasUserEdited: Bool) -> String? {
        guard hasUserEdited else { return nil }
        return EditProfileFormValidator.displayNameError(for: displayName)
    }

    /// v0.8.3 W-C — validation gate for the auto-commit. An invalid field
    /// (empty/over-length name, out-of-range height) is never persisted; the
    /// inline footer already tells the user why. Replaces the old button-gating
    /// `canSave` — the dirty-check now lives in `buildPatch()` at commit time.
    private var validationPasses: Bool {
        displayNameValidationError == nil
            && heightValidationError == nil
            && identityValidationError == nil
    }

    // MARK: - Date bounds

    private var minBirthDate: Date {
        // 1900-01-01 — matches plan §4.3.
        DateComponents(calendar: .current, year: 1900, month: 1, day: 1).date ?? .distantPast
    }

    private var defaultBirthDate: Date {
        // Reasonable default when the user toggles DOB on for the first time —
        // 30 years ago, midnight local time.
        Calendar.current.date(byAdding: .year, value: -30, to: .now) ?? .now
    }
}

// MARK: - Local form state

/// Not `private` so the `+PatientIdentity` extension can read the baseline.
struct ProfileFormState: Equatable {
    var displayName: String
    var dateOfBirth: Date?
    var gender: GenderOption
    var heightCm: String
    var fullName: String
    var insurerName: String
    var insuranceNumber: String
    var insurerIkNumber: String

    static let empty = ProfileFormState(
        displayName: "",
        dateOfBirth: nil,
        gender: .unspecified,
        heightCm: "",
        fullName: "",
        insurerName: "",
        insuranceNumber: "",
        insurerIkNumber: ""
    )
}
