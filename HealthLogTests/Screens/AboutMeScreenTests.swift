@testable import HealthLog
import Testing

/// v1.26 W-ABOUT-ME / v1.26.1 W-ABOUT-ME-RECONCILE — "Über mich" hub contract
/// tests.
///
/// The hub groups the two static self-medical-history modules (allergies, family
/// history) plus the read-only profile basics and Körperdaten.
/// `AboutMeScreen.hostedHistoryRows` is the declarative list the body renders
/// from; pinning it guards against a future wave silently dropping a module from
/// the hub or re-ordering the group — the mirror of the `MoreScreenLayoutTests`
/// re-parenting guard.
///
/// v1.26.1 — the condition/complaint journal (Beschwerden-Tagebuch) was REMOVED
/// from the hub: the operator clarified it is an ongoing symptom LOG, not static
/// self-info, so it lives back in the Mehr → Health & care section.
@MainActor
@Suite("AboutMeScreen — hub composition contract")
struct AboutMeScreenTests {
    @Test("Hub hosts the two static self-history modules in order: allergies, family history (condition journal removed)")
    func hostedHistoryRowsComposition() {
        let ids = AboutMeScreen.hostedHistoryRows.map(\.id)
        #expect(ids == ["allergies", "family_history"])
    }

    @Test("Condition journal is NOT hosted by the hub — it is an ongoing symptom log, not static self-info (v1.26.1)")
    func conditionJournalAbsentFromHub() {
        let ids = AboutMeScreen.hostedHistoryRows.map(\.id)
        #expect(!ids.contains("illness"))
    }

    @Test("Each hosted row reuses the canonical MoreScreen.Layout descriptor (icon + localized keys + more.row.* id)")
    func hostedRowsReuseCanonicalDescriptors() {
        // Reusing the descriptors keeps icons + localized copy single-sourced
        // and means existing `more.row.*` UI-test selectors still resolve — the
        // rows just live one navigation hop deeper now.
        let rows = AboutMeScreen.hostedHistoryRows
        #expect(rows.map(\.icon) == ["allergens", "figure.2.and.child.holdinghands"])
        #expect(rows.map(\.title) == ["allergies.list.title", "familyHistory.list.title"])
        // UI-Standard R5 — „Erkrankungen in der Familie" war eine
        // Umformulierung des Titels „Familienanamnese" und ist gefallen;
        // „Stoffe und Reaktionen" grenzt „Allergien" ein und bleibt.
        #expect(rows.map(\.subtitle) == ["more.allergies.subtitle", nil])
        #expect(rows.map(\.accessibilityIdentifier) == ["more.row.allergies", "more.row.family_history"])
    }

    /// **UI-Standard R4/R7 (U7) — der Archetyp-Wegweiser bleibt gestrichen.**
    ///
    /// „Name und E-Mail änderst du in den Einstellungen unter Profil." war der
    /// Satz, an dem der Betreiber aufgefallen ist, dass die App zu viel redet —
    /// und er war zur Hälfte schlicht falsch: die App hat **keine** Oberfläche,
    /// um die E-Mail-Adresse zu ändern (`EditProfileScreen` reicht sie nur an
    /// den Avatar durch). R4: ein Wegweiser zu etwas, das es nicht gibt, wird
    /// gestrichen, nicht verlinkt. Der Karten-Footer der Versicherungs-Karte
    /// sagte dasselbe ein drittes Mal.
    ///
    /// Der Phrasen-Scan (`UIStandardCopyGuardTests`) fängt eine *Neuformulierung*
    /// des Wegweisers; dieser Test fängt die Rückkehr **genau dieser** Schlüssel,
    /// die ein Merge oder ein Katalog-Roundtrip wiederbeleben könnte.
    @Test("Die zwei reinen Wegweiser-Footer sind aus dem Katalog verschwunden — nicht nur aus dem Screen")
    func archetypeSignpostKeysAreGone() throws {
        let catalog = try ParityCatalog.load()
        for key in ["aboutMe.profile.footer", "aboutMe.insurance.footer"] {
            #expect(
                catalog.strings[key] == nil,
                """
                \(key) ist zurück. R4: Der Absprung („In Profil bearbeiten") steht bereits auf \
                demselben Bildschirm — dort gehört keine Prosa hin, und eine E-Mail-Änderung \
                gibt es in der App überhaupt nicht.
                """
            )
        }
    }

    @Test("Körperdaten section copy is localized — the new keys resolve, never leaking a raw dotted key")
    func bodyDataSectionKeysResolve() {
        // The Körperdaten section (height / sex / DOB / age / weight + the
        // "In Profil bearbeiten" route) is rendered inline, so this guards its
        // presence via the localized copy contract: each key must resolve to
        // real text, not echo the raw key (a raw-key leak the operator flags).
        for key in [
            "aboutMe.body.title",
            "aboutMe.body.footer",
            "aboutMe.body.height",
            "aboutMe.body.sex",
            "aboutMe.body.dateOfBirth",
            "aboutMe.body.age",
            "aboutMe.body.weight",
            "aboutMe.body.editInProfile"
        ] {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(resolved != key)
            #expect(!resolved.isEmpty)
        }
    }
}
