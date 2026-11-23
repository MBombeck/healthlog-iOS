import SwiftUI

/// `/settings/advanced` — Privacy & Security (renamed from "Advanced" in
/// v0.8.0 W7). Mirrors `advanced-section.tsx` minus the Research-Mode card
/// that PB3 originally shipped as a placeholder.
///
/// **Scope:**
/// - Security card: biometric-lock toggle (a privacy/security control that
///   the audit W2 said belongs near sign-in, now in its dedicated home).
///
/// **The local clinical-attestation row is gone.** The card that let
/// anyone type a name into this device and thereby mark LOINC mappings as
/// reviewed by a physician was removed together with its registry, its
/// storage and its composition entry. A name typed on a phone is not clinical review, so
/// no local surface may produce that claim; `physicianReviewPending` stays
/// declared by the mapper for every mapping that needs it, and the FHIR export
/// stays unconditionally disclaimed.
///
/// **v0.8.0 W7 de-dup (audit O1/O2):**
/// - The duplicate "Delete account permanently" danger-zone card (and its
///   confirmation sheet) was removed. Delete-account now lives exactly once,
///   in the hub-root Security section (`SettingsScreen.sicherheitSection`),
///   per HIG (the destructive action belongs on the screen that owns the
///   account). Two divergent irreversible sheets were the worst IA defect.
/// - The duplicate "Manage passkeys" row was removed. Passkeys live once, in
///   Account (`SettingsAccountScreen`), where users look for sign-in
///   credentials.
///
/// **The Research-Mode card is gone.** The server retired the
/// feature on 2026-08-08 (`0160052289e4`, *"the switch governed nothing"*): the
/// curve it claimed to unlock had painted for every account for several releases,
/// `/api/auth/me/research-mode` was deleted and its three user columns dropped
/// in migration 0321. The switch could no longer be turned on at all — its POST
/// answered 404 — so it is removed rather than disabled, together with the
/// acknowledgment dialog it presented.
///
/// **Glucose targets and injection sites moved
/// out** (they were never privacy or security): the diabetes toggle to Mehr →
/// Über mich, the deny-list door to the Medications tab. This screen is now
/// exactly what its title promises: the biometric lock.
///
/// The struct name + sub-route slug + `settings.hub.advanced` accessibility
/// identifier stay `advanced` for selector stability — the same continuity
/// trick `dashboard`→Appearance already uses.
struct SettingsAdvancedScreen: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        HLPage {
            sicherheitCard
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
    }

    // The glucose-targets card and the
    // injection-sites card LEFT this screen: neither is privacy or security.
    // The „Ich habe Diabetes" toggle (which server-side selects the tighter
    // ADA glucose bands) is a static self-medical fact and lives on Mehr →
    // Über mich, beside anamnesis, allergies and family history. The
    // injection-site deny-list governs exactly the intake pickers of the
    // Medications tab's injection meds and lives there, as a management card
    // at the end of the list. Same keys, same stores, same semantics — only
    // the hosts moved. What remains here is what the title promises: the
    // biometric lock.

    /// UI-Standard R3 — der Karten-Subtitle („Biometrische Sperre beim Öffnen
    /// der App.") stand direkt über der Zeile „Biometrische Sperre", deren
    /// eigene Beschreibung dasselbe plus Substanz sagt. Die Zeilen-Beschreibung
    /// ist Klasse D und bleibt unverändert; die redundante Hälfte ist gefallen.
    /// One row, one heading: the switch "App-Sperre" says it.
    private var sicherheitCard: some View {
        HLCard(layout: .rows) {
            HLSettingsToggleRow(
                title: "Biometric lock",
                description: "settings.advanced.biometricLock.description",
                isOn: bindable(\.biometricLockEnabled),
                accessibilityID: "settings.advanced.biometricLockToggle"
            )
        }
    }

    // There is no local LOINC clinical sign-off: the device cannot know who
    // typed a reviewer name or whether they are a clinician, so no local input
    // could make "reviewed by a physician" true. `MetricFHIRMapper` declares
    // `physicianReviewPending` and the FHIR export says so unconditionally.
    // Account deletion lives in the hub-root Security section of
    // SettingsScreen; the Insights customization card lives on Appearance.

    private func bindable<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(get: { store[keyPath: keyPath] }, set: { store[keyPath: keyPath] = $0 })
    }
}
