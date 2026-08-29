import SwiftUI

/// `/settings/advanced` — Privacy & Security (renamed from "Advanced" in
/// v0.8.0 W7). Mirrors `advanced-section.tsx` minus the Research-Mode card
/// that PB3 originally shipped as a placeholder.
///
/// **Scope:**
/// - Security card: biometric-lock toggle (a privacy/security control that
///   the audit W2 said belongs near sign-in, now in its dedicated home).
///
/// **08-06 — the local clinical-attestation row is gone.** The card that let
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
/// **D-12-05-A — the Research-Mode card is gone.** The server retired the
/// feature on 2026-08-08 (`0160052289e4`, *"the switch governed nothing"*): the
/// curve it claimed to unlock had painted for every account for several releases,
/// `/api/auth/me/research-mode` was deleted and its three user columns dropped
/// in migration 0321. The switch could no longer be turned on at all — its POST
/// answered 404 — so it is removed rather than disabled, together with the
/// acknowledgment dialog it presented.
///
/// **25-02 (E-2026-08-29 #1) — glucose targets and injection sites moved
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
        HLSettingsPage(title: "Privacy & Security") {
            sicherheitCard
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
    }

    // 25-02 (E-2026-08-29 #1) — the glucose-targets card and the
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
    private var sicherheitCard: some View {
        HLSettingsCard(
            icon: "lock.shield.fill",
            title: "Security"
        ) {
            HLSettingsToggleRow(
                title: "Biometric lock",
                description: "settings.advanced.biometricLock.description",
                isOn: bindable(\.biometricLockEnabled),
                accessibilityID: "settings.advanced.biometricLockToggle"
            )
        }
    }

    // 08-06 — the LOINC clinical sign-off card was REMOVED, and the removal is
    // a truth fix rather than an IA fix. The row pushed a screen whose whole
    // mechanism was: type a name into a text field on this device, tap the
    // per-row confirm action, and the mapping counted as cleared by a
    // physician from then on. Nothing about that is review — the device cannot know who
    // typed, whether they are a clinician, or whether they looked at the
    // mapping at all — yet the resulting flag was allowed to drop the
    // draft-mapping disclaimer on a clinical export. The card, its destination
    // screen, the registry behind it, the UserDefaults blob, the Keychain
    // reviewer-name slot and the environment injection all went in one commit;
    // `MetricFHIRMapper` keeps declaring `physicianReviewPending` and the FHIR
    // export keeps saying so unconditionally, which is the honest statement the
    // sign-off was overriding. Deliberately NOT replaced by a local boolean,
    // date or "reviewed by me" toggle: there is no local input that could make
    // the claim true.

    // W-B187 (Settings consolidation §A.2) — the LEGACY `ChartDetailScreen`
    // parking row was REMOVED. The v0.11 chart-detail cutover made the
    // web-mirror `InsightsMetricScreen` the canonical drill-down everywhere, so
    // the parked row was a user-facing dead surface (a developer artifact in a
    // user privacy/security screen).
    //
    // 09-08 (Phase 9): removing that row was what made the legacy screen
    // statically unreachable, and the screen source itself is now DELETED. The
    // reusable half — `ChartDetailStore`, the chart components, the fullscreen
    // cover, the math and the accessibility helpers — stays, and
    // `InsightsMetricScreen` composes it. See `ChartDetailCutoverTests`.

    // v0.8.0 W7 O1/C-top — `dangerZoneCard` (the second "Delete account
    // permanently" affordance + its own confirmation sheet) removed. The
    // canonical delete-account path is the hub-root Security section in
    // SettingsScreen, which still mounts the DeleteAccountScreen sheet.
    // v0.6.1.12 Y9.2-E — `insightsCustomizationCard` lives on Appearance.

    private func bindable<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(get: { store[keyPath: keyPath] }, set: { store[keyPath: keyPath] = $0 })
    }
}
