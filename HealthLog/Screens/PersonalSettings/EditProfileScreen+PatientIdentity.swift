import SwiftUI

/// **v0.10.0 — extended patient-identity fields.**
///
/// The full legal name, health insurer (Krankenkasse) and German insurance
/// number (KVNR) feed the Doctor-Report cover + the FHIR Patient resource.
/// Split into its own file to keep `EditProfileScreen` under the
/// file-/type-length budget (one-type-per-file hygiene, mirrors the W-C split
/// of `EditProfileFormValidator`).
///
/// **Security:** the KVNR is sensitive PII. It is bound to local `@State`
/// + the in-memory `UserProfile` only, travels solely over the existing
/// cert-pinned TLS in the profile PATCH, and is **never** passed to any
/// `Logger`/`HLLog`/`print`. Display is plaintext — it's the user's own data
/// on their own device, matching the web app (no masking required).
extension EditProfileScreen {
    /// The "Patient identity" section: full name, insurer, and KVNR, each on
    /// the same auto-commit/baseline-diff path as the rest of the form.
    var patientIdentitySection: some View {
        Section {
            LabeledContent {
                TextField(
                    String(localized: "Optional"),
                    text: $fullName
                )
                .textContentType(.name)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("editProfile.fullName")
            } label: {
                Text("Full name")
            }
            LabeledContent {
                TextField(
                    String(localized: "Optional"),
                    text: $insurerName
                )
                .textContentType(.organizationName)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("editProfile.insurerName")
            } label: {
                Text("Health insurer")
            }
            LabeledContent {
                TextField(
                    String(localized: "Optional"),
                    text: $insuranceNumber
                )
                // KVNR is an opaque identifier — no content-type hint, no
                // autocorrect, no autocapitalisation so the user types it
                // verbatim. The server runs the authoritative mod-10 check.
                .textContentType(.none)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("editProfile.insuranceNumber")
            } label: {
                Text("Insurance number")
            }
            LabeledContent {
                TextField(
                    String(localized: "Optional"),
                    text: $insurerIkNumber
                )
                // IKNR is a 9-digit opaque identifier — number-pad entry, no
                // autocorrect/autocapitalisation. The server runs the
                // authoritative validation.
                .textContentType(.none)
                .keyboardType(.numberPad)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("editProfile.insurerIkNumber")
            } label: {
                Text("Insurer ID (IK)")
            }
        } header: {
            Text("Patient identity")
        } footer: {
            if let err = identityValidationError {
                HLFormErrorText(err)
            } else {
                Text("Optional. Used on the Doctor report cover and the FHIR export.")
            }
        }
    }

    /// First non-nil error across the three patient-identity fields, surfaced
    /// in the shared section footer. Empty values are valid (they clear).
    var identityValidationError: String? {
        EditProfileFormValidator.fullNameError(for: fullName)
            ?? EditProfileFormValidator.insurerNameError(for: insurerName)
            ?? EditProfileFormValidator.insuranceNumberError(for: insuranceNumber)
            ?? EditProfileFormValidator.insurerIkNumberError(for: insurerIkNumber)
    }

    /// Folds any diverged patient-identity field into the diff `patch`.
    /// Empty string clears (the server collapses `""` → null). The KVNR is
    /// sent verbatim; the server normalises + runs the authoritative mod-10
    /// check. Returns `true` when at least one field diverged.
    func applyIdentityDiff(to patch: inout ProfilePatch) -> Bool {
        var dirty = false

        let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFullName != baseline.fullName {
            patch.fullName = trimmedFullName.isEmpty ? .some(nil) : .some(trimmedFullName)
            dirty = true
        }

        let trimmedInsurer = insurerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInsurer != baseline.insurerName {
            patch.insurerName = trimmedInsurer.isEmpty ? .some(nil) : .some(trimmedInsurer)
            dirty = true
        }

        let trimmedKVNR = insuranceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKVNR != baseline.insuranceNumber {
            patch.insuranceNumber = trimmedKVNR.isEmpty ? .some(nil) : .some(trimmedKVNR)
            dirty = true
        }

        let trimmedIK = insurerIkNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedIK != baseline.insurerIkNumber {
            patch.insurerIkNumber = trimmedIK.isEmpty ? .some(nil) : .some(trimmedIK)
            dirty = true
        }

        return dirty
    }

    /// Applies the loaded profile's patient-identity values to the form
    /// fields. Called from `loadBaseline` so the prefill assignments don't
    /// count against `EditProfileScreen`'s type-body budget.
    func applyIdentityBaseline(_ snapshot: ProfileFormState) {
        fullName = snapshot.fullName
        insurerName = snapshot.insurerName
        insuranceNumber = snapshot.insuranceNumber
        insurerIkNumber = snapshot.insurerIkNumber
    }

    /// Toolbar trailing accessory: an in-flight spinner while a commit is
    /// running, the transient "Saved" confirmation right after, otherwise
    /// nothing. Replaces the removed Save button. Lives here purely for
    /// `EditProfileScreen` type-length hygiene.
    @ViewBuilder var savedCue: some View {
        if isSaving {
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("editProfile.saveProgress")
        } else if showSavedCue {
            Label {
                Text("Saved")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(HLColor.statusOK)
            .transition(.opacity)
            .accessibilityIdentifier("editProfile.savedCue")
        }
    }
}
