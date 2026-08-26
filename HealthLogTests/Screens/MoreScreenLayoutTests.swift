@testable import HealthLog
import Testing

/// v0.5.1-F5 / v0.5.2-A3 — MoreScreen.Layout contract tests.
///
/// The Mehr tab is described declaratively by `MoreScreen.Layout`. These
/// tests pin the **shape** of that descriptor — section titles, row order,
/// accessibility identifiers — so a future wave cannot silently
/// re-introduce a Benachrichtigungen duplicate row or split the merged
/// "Mentale Gesundheit und Vitalwerte" section back into two.
///
/// Why a state-contract test instead of a snapshot:
/// - SwiftUI image snapshots of `MoreScreen` would drag the navigation
///   shell + `HLAccent` environment + a HealthKit-aware `Charts`/`Mood`
///   stack into the suite for a layout that has no rendering logic.
/// - The reported regressions (operator-felt duplicates + mis-labelled
///   sections) are state-shaped, not pixel-shaped.
@Suite("MoreScreen.Layout — section + row contract")
struct MoreScreenLayoutTests {
    // MARK: - Section headings

    @Test("Navigation title remains the More heading")
    func navigationTitle() {
        #expect(MoreScreen.Layout.navigationTitle == "More")
    }

    // MARK: - Removed-row guards

    //
    // v0.17 settings-hygiene — the `vitalSignsSectionTitle` / `vitalSignsRows`
    // descriptors (single-row "Achievements" section, test-only) were removed.
    // Achievements now lives in `recordsRows`; these guards run against the
    // live records catalogue.

    @Test("Trends row was removed in v0.11 IA — ChartsScreen duplicate per-metric list cut")
    func trendsRowAbsent() {
        // v0.11 IA — the metric path is consolidated to Insights (tile →
        // ChartDetailScreen) + the Dashboard tile shortcut. The rival
        // More→Trends list (ChartsScreen) is gone; guard re-introduction.
        let ids = MoreScreen.Layout.recordsRows.map(\.id)
        #expect(!ids.contains("trends"))
    }

    @Test("Stimmung row removed from Mehr in v0.11 IA — mood analysis lives in Insights")
    func moodRowAbsentFromMehr() {
        // v0.11 IA — the More→Stimmung row (→ MoodAnalysisScreen) was a
        // duplicate of the Insights mood surface. It was dropped; mood logging
        // stays on Erfassen, analysis/history lives in Insights. Guard against
        // re-introduction.
        let ids = MoreScreen.Layout.recordsRows.map(\.id)
        #expect(!ids.contains("mood"))
    }

    // MARK: - Notifications duplicate is dropped

    @Test("No Benachrichtigungen row at the More-tab level — that duplicate was removed in v0.5.1-F5")
    func notificationsRowAbsent() {
        // The Settings hub still owns the Benachrichtigungen path via
        // SettingsNotificationsScreen. The separate Mehr → Benachrichtigungen
        // row was redundant and the operator called it out on the
        // v0.5.0 walkthrough — guard against re-introduction.
        let allTitles = MoreScreen.Layout.recordsRows
            .map(\.title)
        #expect(!allTitles.contains("Benachrichtigungen"))

        let allIds = MoreScreen.Layout.recordsRows
            .map(\.id)
        #expect(!allIds.contains("notifications"))
    }

    @Test("v0.5.4.1: No duplicate Einstellungen row in any list section — gear toolbar is the canonical entry")
    func settingsRowDuplicateAbsent() {
        let allIds = MoreScreen.Layout.recordsRows
            .map(\.id)
        #expect(!allIds.contains("settings"))
    }

    // MARK: - Row icon symbols

    @Test("Row icons match the operator-approved SF Symbol glyphs")
    func rowIcons() {
        #expect(MoreScreen.Layout.achievementsRow.icon == "trophy.fill")
        #expect(MoreScreen.Layout.workoutsRow.icon == "figure.run")
        #expect(MoreScreen.Layout.personalRecordsRow.icon == "rosette")
    }

    // MARK: - v0.14.1 (#134) — Mehr IA reorg

    @Test(
        "Records & achievements section groups Rekorde + Erfolge + Workouts + Messwerte in order (Labs/Illness promoted to clinical spine in v0.15)"
    )
    func recordsSectionComposition() {
        #expect(MoreScreen.Layout.recordsSectionTitle == "Records & achievements")
        let titles = MoreScreen.Layout.recordsRows.map(\.title)
        // v0.15 W-FRONTDOORS — Lab results + Condition journal were PROMOTED out
        // of this records drawer into the clinical-spine "Health & care" section.
        #expect(titles == ["Personal records", "Achievements", "Workouts", "Measurements"])
        let ids = MoreScreen.Layout.recordsRows.map(\.id)
        #expect(ids == ["personal_records", "achievements", "workouts", "measurements"])
    }

    // MARK: - v0.15 W-FRONTDOORS — clinical-spine section

    @Test(
        "Health & care clinical-spine section leads with Über mich, then Vorsorge + Labs + Illness + Documents + Mental wellbeing + Cycle"
    )
    func clinicalSectionComposition() {
        #expect(MoreScreen.Layout.clinicalSectionTitle == "Health & care")
        let ids = MoreScreen.Layout.clinicalRows.map(\.id)
        // v0152 W-COACH-CLEANUP (C2) — the stray More Coach row was removed; the
        // manual coach entry returns inline on the Insights pages (next wave).
        // v1.25 W-MENTAL-HEALTH — the PHQ-9 / GAD-7 screener front door.
        // Documents — the opt-in `inboundDocuments` vault front door.
        // v1.26 W-ABOUT-ME — the "Über mich" hub (`about_me` → `AboutMeScreen`)
        // now leads the spine, hosting allergies + family history.
        // v1.26.1 W-ABOUT-ME-RECONCILE — the condition journal (`illness`) was
        // RESTORED as a direct clinical-spine row next to Labs (it is an ongoing
        // symptom log, not static self-info). Allergies + family history STAY in
        // the hub, so they remain absent here.
        #expect(ids == ["about_me", "vorsorge", "labs", "illness", "documents", "mental_wellbeing", "cycle"])
    }

    @Test("Build 9 (C7) — cycle settings row descriptor is stable and stays OUT of the curated clinicalRows")
    func cycleSettingsRowDescriptor() {
        #expect(MoreScreen.Layout.cycleSettingsRow.id == "cycle_settings")
        #expect(MoreScreen.Layout.cycleSettingsRow.icon == "gearshape")
        #expect(MoreScreen.Layout.cycleSettingsRow.title == "more.cycleSettings.title")
        // **Amended 2026-08-23 (Plan 17-05, R5-A1).** This clause used to pin
        // `subtitle == nil`, on R5's rule that a subtitle which only rephrases
        // its title falls. R5 Amendment A1 supersedes that for hub rows BY NAME:
        // on the settings hub and the „Mehr" tab a rephrasing subtitle is not
        // deleted, it is rewritten until it carries something — which is what
        // this row's now does (the row opens the Apple-Health integration page
        // that hosts the server-synced cycle opt-in, so the switch AND the sync
        // are in the sentence).
        //
        // The clause is kept rather than dropped: what it is really about is that
        // this descriptor is stable, and a pin that says „and its subtitle is
        // exactly this" is stronger than no pin at all.
        #expect(MoreScreen.Layout.cycleSettingsRow.subtitle == "Turn tracking on or off, Apple Health sync")
        #expect(MoreScreen.Layout.cycleSettingsRow.accessibilityIdentifier == "more.row.cycle_settings")
        // It is rendered inline (flag-gated) — NOT part of the curated clinical spine,
        // so `clinicalSectionComposition` stays unchanged.
        #expect(MoreScreen.Layout.clinicalRows.contains { $0.id == "cycle_settings" } == false)
    }

    @Test("Documents vault front-door row has a stable id/icon and sits in the clinical spine")
    func documentsFrontDoorRow() {
        #expect(MoreScreen.Layout.documentsRow.id == "documents")
        #expect(MoreScreen.Layout.documentsRow.icon == "doc.text.magnifyingglass")
        #expect(MoreScreen.Layout.documentsRow.title == "documents.list.title")
        #expect(MoreScreen.Layout.documentsRow.subtitle == "more.documents.subtitle")
        #expect(MoreScreen.Layout.documentsRow.accessibilityIdentifier == "more.row.documents")
        #expect(MoreScreen.Layout.clinicalRows.contains { $0.id == "documents" })
    }

    @Test("Mental-wellbeing screener front-door row has a stable id/icon and sits in the clinical spine")
    func mentalWellbeingFrontDoorRow() {
        #expect(MoreScreen.Layout.mentalWellbeingRow.id == "mental_wellbeing")
        #expect(MoreScreen.Layout.mentalWellbeingRow.icon == "brain.head.profile")
        #expect(MoreScreen.Layout.mentalWellbeingRow.title == "more.mentalWellbeing.title")
        #expect(MoreScreen.Layout.mentalWellbeingRow.subtitle == "more.mentalWellbeing.subtitle")
        #expect(MoreScreen.Layout.mentalWellbeingRow.accessibilityIdentifier == "more.row.mental_wellbeing")
        #expect(MoreScreen.Layout.clinicalRows.contains { $0.id == "mental_wellbeing" })
    }

    // MARK: - v1.26 W-ABOUT-ME — "Über mich" hub

    @Test("Über mich hub row leads the clinical spine with a stable id/icon/keys")
    func aboutMeFrontDoorRow() {
        #expect(MoreScreen.Layout.aboutMeRow.id == "about_me")
        #expect(MoreScreen.Layout.aboutMeRow.icon == "person.text.rectangle")
        #expect(MoreScreen.Layout.aboutMeRow.title == "aboutMe.title")
        #expect(MoreScreen.Layout.aboutMeRow.subtitle == "more.aboutMe.subtitle")
        #expect(MoreScreen.Layout.aboutMeRow.accessibilityIdentifier == "more.row.about_me")
        // Leads the Health & care section.
        #expect(MoreScreen.Layout.clinicalRows.first?.id == "about_me")
    }

    @Test("Allergies + Family history stay RE-PARENTED into the hub — absent from every live Mehr section (condition journal restored)")
    func selfHistoryRowsReparentedOutOfMehr() {
        // v1.26.1 W-ABOUT-ME-RECONCILE — allergies + family history remain in the
        // Über mich hub (static self-medical info). Their descriptors survive as
        // the hub's single source, but neither is a direct Mehr row. The
        // condition journal is NOT in this set — it was restored to the spine.
        for id in ["allergies", "family_history"] {
            #expect(!MoreScreen.Layout.clinicalRows.contains { $0.id == id })
            #expect(!MoreScreen.Layout.recordsRows.contains { $0.id == id })
        }
    }

    @Test("Vorsorge front-door row is CORE (present in the clinical spine) with stable id/icon")
    func vorsorgeFrontDoorRow() {
        #expect(MoreScreen.Layout.vorsorgeRow.id == "vorsorge")
        #expect(MoreScreen.Layout.vorsorgeRow.icon == "stethoscope")
        #expect(MoreScreen.Layout.vorsorgeRow.accessibilityIdentifier == "more.row.vorsorge")
        #expect(MoreScreen.Layout.clinicalRows.contains { $0.id == "vorsorge" })
    }

    @Test("Coach nav-home row is absent from the More clinical spine (v0152 W-COACH-CLEANUP C2)")
    func coachNavHomeRowRemoved() {
        // The operator flagged the stray More Coach entry; it opened the coach
        // against his External-AI pick. The manual coach entry returns as an
        // inline button on the Insights metric pages (next wave). Coach settings
        // (Past conversations, memory) stay reachable under Settings → Coach.
        #expect(!MoreScreen.Layout.clinicalRows.contains { $0.id == "coach" })
    }

    @Test("Devices stays in the Settings hub — no devices row in any live Mehr section (v0.14.10 §3 / v0.14.8 W2 §3.c)")
    func devicesRowAbsentFromMehr() {
        // v0.14.10 §3 — operator wants Geräte under Einstellungen. The dead
        // `devicesRow`/`serverDataRows` source-compat descriptors were deleted
        // in v0.14.8 W2 (§3.c) together with the orphaned "Data & devices"
        // section, so the only guard left is the live row catalogue.
        let allIds = MoreScreen.Layout.recordsRows
            .map(\.id)
        #expect(!allIds.contains("devices"))
    }

    @Test("No Goals/targets row anywhere on the Mehr tab (v0.11 W-A)")
    func noTargetsRow() {
        let allIds = MoreScreen.Layout.recordsRows
            .map(\.id)
        #expect(!allIds.contains("targets"))
    }

    @Test("Records section exposes accessibility identifiers under more.row.* namespace")
    func recordsAccessibilityIdentifiers() {
        let identifiers = MoreScreen.Layout.recordsRows.map(\.accessibilityIdentifier)
        #expect(identifiers == [
            "more.row.personal_records",
            "more.row.achievements",
            "more.row.workouts",
            "more.row.measurements"
        ])
    }

    @Test("Measurements picker row folded into Records & achievements — the orphaned Data & devices section is gone (v0.14.8 W2 §3.c)")
    func measurementsRowFoldedIntoRecords() {
        // v0.14.8 W2 (Audit §3.c) — after Geräte (v0.14.10 §3) and Export
        // (v0.14.7 C1) moved back to the Settings hub, "Data & devices" held a
        // single Messwerte row under a heading that promised devices. The row
        // now renders last in the Records & achievements section; the section
        // descriptor + the dead exportRow/devicesRow descriptors were deleted.
        #expect(MoreScreen.Layout.measurementsRow.icon == "list.bullet.rectangle")
        #expect(MoreScreen.Layout.measurementsRow.title == "Measurements")
        #expect(MoreScreen.Layout.measurementsRow.accessibilityIdentifier == "more.row.measurements")
        // Measurements is still last in the records section after Labs/Illness
        // were promoted to the clinical spine (v0.15 W-FRONTDOORS).
        #expect(MoreScreen.Layout.recordsRows.last?.id == "measurements")
    }

    @Test("Lab results row lives in the clinical spine, gated behind the labs module (v0.15 promotion)")
    func labsRowPresentAndGated() {
        #expect(MoreScreen.Layout.labsRow.icon == "testtube.2")
        // v0153 INV-D — the row's title is now the canonical screen
        // localization key (de "Laborwerte"), not the unregistered English
        // literal that leaked into the German build. The subtitle is its own
        // keyed string.
        #expect(MoreScreen.Layout.labsRow.title == "labs.list.title")
        #expect(MoreScreen.Layout.labsRow.subtitle == "more.labs.subtitle")
        #expect(MoreScreen.Layout.labsRow.accessibilityIdentifier == "more.row.labs")
        // v0.15 — promoted out of recordsRows into clinicalRows.
        #expect(MoreScreen.Layout.clinicalRows.contains { $0.id == "labs" })
        #expect(!MoreScreen.Layout.recordsRows.contains { $0.id == "labs" })
    }

    @Test("Condition journal descriptor is stable and RESTORED to the clinical spine next to Labs (v1.26.1 W-ABOUT-ME-RECONCILE)")
    func illnessRowRestoredToClinicalSpine() {
        #expect(MoreScreen.Layout.illnessRow.icon == "heart.text.square")
        // v0153 INV-D — the row's title is now the canonical screen
        // localization key (de "Beschwerden-Tagebuch"), not the unregistered
        // English literal that leaked into the German build. The subtitle is
        // its own keyed string.
        #expect(MoreScreen.Layout.illnessRow.title == "illness.journal.title")
        #expect(MoreScreen.Layout.illnessRow.subtitle == "more.illness.subtitle")
        #expect(MoreScreen.Layout.illnessRow.accessibilityIdentifier == "more.row.illness")
        // v1.26.1 W-ABOUT-ME-RECONCILE — the operator clarified the Beschwerden-
        // Tagebuch is an ongoing symptom LOG, not static self-info, so it left
        // the Über mich hub and its front door returned to the clinical spine,
        // positioned right after Labs. Still never a records-drawer row.
        #expect(MoreScreen.Layout.clinicalRows.contains { $0.id == "illness" })
        #expect(!MoreScreen.Layout.recordsRows.contains { $0.id == "illness" })
        // Sits directly after Labs (web-parity clinical ordering).
        let ids = MoreScreen.Layout.clinicalRows.map(\.id)
        let labsIndex = ids.firstIndex(of: "labs")
        #expect(labsIndex != nil)
        if let labsIndex, labsIndex + 1 < ids.count {
            #expect(ids[labsIndex + 1] == "illness")
        }
    }

    @Test("Export row stays in the Settings hub — no export row in any live Mehr section (v0.14.7 C1 / v0.14.8 W2 §3.c)")
    func exportRowAbsentFromMehr() {
        // v0.14.8 W2 (§3.c) — the dead `exportRow` source-compat descriptor was
        // deleted with the section; guard the live catalogue instead.
        let allIds = MoreScreen.Layout.recordsRows
            .map(\.id)
        #expect(!allIds.contains("export"))
    }

    @Test("Share-with-doctor LIST section + row were removed; the header share glyph is the entry now (v0.14.8 Task D)")
    func shareWithDoctorRowRemovedFromList() {
        // v0.14.8 (Task D) — operator: "Ich hätte gerne, dass man das 'Mehr —
        // kann ich mit dem Arzt teilen?' komplett weg hat." The list row was
        // dropped in favour of a header share glyph (left of the gear) that
        // pushes the sharing surface. No live list section maps
        // a `share_with_doctor` row anymore.
        let allIds = MoreScreen.Layout.recordsRows.map(\.id)
        #expect(!allIds.contains("share_with_doctor"))
    }

    // MARK: - v0.5.4-NF-2 — Gear-icon toolbar shortcut

    @Test("Gear toolbar trailing item uses a stable accessibility identifier")
    func gearToolbarAccessibilityIdentifier() {
        // The Mehr → Settings shortcut is reachable via the `gearshape`
        // trailing nav-bar item *in addition* to the bottom "App"
        // section's Einstellungen row. Pin the identifier so a future
        // wave can't silently drop the affordance — operators (and UI
        // tests) rely on the namespaced `more.toolbar.gear` reference.
        #expect(MoreScreen.Layout.gearToolbarAccessibilityIdentifier == "more.toolbar.gear")
    }

    @Test("Gear toolbar trailing item exposes an operator-facing accessibility label")
    func gearToolbarAccessibilityLabel() {
        // Localised key — the value pinned here is the English source
        // string after the v0.8.2 W2 sweep (`sourceLanguage: en`); the
        // German translation lives in Localizable.xcstrings.
        #expect(MoreScreen.Layout.gearToolbarAccessibilityLabel == "Open Settings")
    }

    // MARK: - v0.14.8 (Task D) — Header share glyph

    @Test("Header share glyph (left of gear) uses a stable accessibility identifier")
    func shareToolbarAccessibilityIdentifier() {
        // v0.14.8 (Task D) — the "Mit dem Arzt teilen" list row was replaced by
        // a header share glyph that pushes the sharing surface. Pin the
        // identifier so a future wave can't silently drop the affordance —
        // UI tests resolve the namespaced `more.toolbar.share` reference.
        #expect(MoreScreen.Layout.shareToolbarAccessibilityIdentifier == "more.toolbar.share")
    }

    @Test("Header share glyph exposes an operator-facing accessibility label")
    func shareToolbarAccessibilityLabel() {
        // Localised key — English source value; the German translation
        // ("Mit dem Arzt teilen") lives in Localizable.xcstrings.
        #expect(MoreScreen.Layout.shareToolbarAccessibilityLabel == "Share with your doctor")
    }

    // MARK: - v0.6.1.5 Y5 — Account (sign-out + delete) rows

    //
    // v0.17 settings-hygiene — the `sicherheitSectionTitle` + `sicherheitRows`
    // descriptors (test-only, no production reader) were removed. The two rows
    // themselves stay (`SettingsAccountScreen` reads them); the order/id/a11y
    // guards run against the kept `signOutRow` / `deleteAccountRow` directly.

    @Test("Account section contains sign-out then delete in stable order")
    func sicherheitRowsOrder() {
        // Order matters: the recoverable action (Abmelden) is listed
        // first, the irrevocable one (Konto löschen) second, per
        // Apple-HIG destructive-affordance discipline.
        let titles = [MoreScreen.Layout.signOutRow, MoreScreen.Layout.deleteAccountRow].map(\.title)
        #expect(titles == ["Sign out", "Delete account"])
    }

    @Test("Account row identifiers are stable namespace tokens")
    func sicherheitRowIdentifiers() {
        let ids = [MoreScreen.Layout.signOutRow, MoreScreen.Layout.deleteAccountRow].map(\.id)
        #expect(ids == ["sign_out", "delete_account"])
    }

    @Test("Account rows expose accessibility identifiers under more.row.* namespace")
    func sicherheitAccessibilityIdentifiers() {
        let identifiers = [MoreScreen.Layout.signOutRow, MoreScreen.Layout.deleteAccountRow]
            .map(\.accessibilityIdentifier)
        #expect(identifiers == [
            "more.row.sign_out",
            "more.row.delete_account"
        ])
    }

    @Test("Sicherheit row icons read as destructive intents at a glance")
    func sicherheitRowIcons() {
        // Sign-out lifts the system off the device — the
        // arrow-out-of-rectangle glyph carries the right semantic.
        // Konto löschen drops the account server-side — the trash
        // glyph signals irrevocability.
        #expect(MoreScreen.Layout.signOutRow.icon == "rectangle.portrait.and.arrow.right")
        #expect(MoreScreen.Layout.deleteAccountRow.icon == "trash.fill")
    }

    @Test("Sicherheit row subtitles spell out the contract in single lines")
    func sicherheitRowSubtitles() {
        // Subtitles replace the pre-Y5 Section footers — operator
        // wanted the destructive section to consume less vertical
        // real estate, so the contract copy demotes onto the row
        // itself.
        #expect(MoreScreen.Layout.signOutRow.subtitle == "Your data on the server is preserved")
        // **Amended 2026-08-23 (Plan 17-05, R5-A1).** The middle dot is out —
        // the operator reads it as machine-written and the amendment names the
        // comma as the only separator. The sentence is otherwise untouched,
        // including the word „irreversible", which is the contract copy this
        // clause exists to protect.
        #expect(MoreScreen.Layout.deleteAccountRow.subtitle == "Irreversible, the server removes all data")
    }
}
