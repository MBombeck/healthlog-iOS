import SwiftUI

// v0.15 W-FRONTDOORS — split `MoreScreen.Layout` out of `MoreScreen.swift` to keep
// that file under the 600-line file_length budget (PROJECT_GUIDE.md discipline) after the
// clinical-spine section + Vorsorge/Coach rows landed. Pure move: the descriptor
// enum is unchanged; `MoreScreenLayoutTests` reads it from here unchanged.

extension MoreScreen {
    /// v0.5.1-F5 — Declarative layout descriptor for the Mehr tab.
    ///
    /// Centralising the row metadata + section titles here gives us a
    /// contract-test surface (`MoreScreenLayoutTests`) without dragging
    /// `ViewInspector` into the suite. The SwiftUI body still owns the
    /// rendering — these constants only describe **what** the body must
    /// declare, not how it does so.
    ///
    /// Adding/removing rows requires touching both this enum and the
    /// matching `Section` block above, on purpose: the tests guard against
    /// silent drift (e.g. a future Welle re-introducing a Benachrichtigungen
    /// row that duplicates the Settings path).
    enum Layout {
        /// v0.14.1 (#134) — heading for the combined Persönliche Rekorde +
        /// Erfolge + Workouts section. "Records & achievements" names the two
        /// grouped surfaces the operator reads as one achievement story.
        /// v0.14.8 W2 (Audit §3.c) — also hosts the Messwerte row since the
        /// orphaned "Data & devices" section was dropped.
        static let recordsSectionTitle = "Records & achievements"

        /// v0.15 W-FRONTDOORS — heading for the clinical-spine section (Vorsorge ·
        /// Labs · Illness · Cycle · Coach), mirroring the web nav-model grouping.
        /// Sits above "Records & achievements" so the clinical front doors read as
        /// the primary features the web makes them, not records footnotes.
        static let clinicalSectionTitle = "Health & care"

        // v0.14.8 W2 (Audit §3.c) — `dataDevicesSectionTitle` + `dataDevicesRows`
        // removed: after Geräte (v0.14.10 §3) and Export (v0.14.7 C1) moved back
        // to the Settings hub the section held only Messwerte under a heading
        // that promised devices. The row folded into `recordsRows`.

        // v0.14.8 (Task D) — `shareWithDoctorSectionTitle` removed: the "Mit dem
        // Arzt teilen" LIST section was dropped in favour of the header share
        // glyph. The destination (the unified sharing surface) is now reached via
        // `shareToolbarAccessibility*` above.

        // v0.14.8 W2 (Audit §3.c/§5) — the dead legacy descriptors
        // `serverDataSectionTitle` / `serverDataRows` / `devicesRow` /
        // `exportRow` were deleted: the v0.5.3-F3 "Activities & goals" section
        // was superseded by the v0.14.1 (#134) reorg (`recordsRows`), Geräte
        // lives in the Settings hub (`HubRow.devices`, v0.14.10 §3) and Export
        // is back on the Settings hub too (`HubRow.export`, v0.14.7 C1) — none
        // of them was rendered or deep-linked anymore.

        static let navigationTitle = "More"

        /// v0.14.8 C5 — heading for the women-only cycle section (gated). Only
        /// ever rendered when `CycleGate.isCycleTrackingAvailable`.
        static let cycleSectionTitle = "Cycle"

        /// v0.5.4-NF-2 — accessibility metadata for the gear-icon toolbar
        /// shortcut. Keeping the strings centralised mirrors the `Row`
        /// pattern + lets `MoreScreenLayoutTests` pin the identifier so a
        /// future wave can't silently drop the affordance.
        static let gearToolbarAccessibilityLabel = "Open Settings"
        static let gearToolbarAccessibilityIdentifier = "more.toolbar.gear"

        /// v0.14.8 (Task D) — accessibility metadata for the header share glyph
        /// (left of the gear), which pushes `UnifiedSharingScreen`. Replaces the
        /// removed "Mit dem Arzt teilen" list row; the identifier is pinned by
        /// `MoreScreenLayoutTests` so a future wave can't silently drop it.
        static let shareToolbarAccessibilityLabel = "Share with your doctor"
        static let shareToolbarAccessibilityIdentifier = "more.toolbar.share"

        /// **UI-Standard R5 — der Zeilen-Untertitel ist optional.**
        /// „maximal eine Zeile; fällt, wenn er nur den Titel umformuliert;
        /// bleibt, wenn er Inhalt aufzählt oder eingrenzt." Vor dem Umbau trug
        /// *jede* Mehr-Zeile einen Untertitel, weil das Feld ihn verlangte —
        /// `nil` macht „diese Zeile braucht keinen" überhaupt erst
        /// formulierbar.
        struct Row {
            let id: String
            let icon: String
            let title: String
            let subtitle: String?
            var accessibilityIdentifier: String {
                "more.row.\(id)"
            }

            init(id: String, icon: String, title: String, subtitle: String? = nil) {
                self.id = id
                self.icon = icon
                self.title = title
                self.subtitle = subtitle
            }
        }

        /// v0.11 IA — `moodRow` removed. The More→Stimmung entry was dropped
        /// when mood analysis/history moved into Insights.
        /// R5-A1 (17-05) — der unter R5/U7 gefallene Untertitel („Badges &
        /// Meilensteine") ist zurück, im neuen Register: Komma statt „&". Die
        /// Zeile führt jetzt auf, was hinter ihr liegt, statt den Titel zu
        /// wiederholen.
        static let achievementsRow = Row(
            id: "achievements",
            icon: "trophy.fill",
            title: "Achievements",
            subtitle: "Badges, milestones"
        )

        /// v0.14.8 C5 — the gated cycle home row (mirror of web `/cycle`). The
        /// `drop.fill` glyph matches the cycle capture surface so the row→screen
        /// transition reads continuous.
        static let cycleRow = Row(
            id: "cycle",
            icon: "drop.fill",
            title: "Cycle",
            subtitle: "Calendar, predictions, phases"
        )

        /// **Build 9 (Server-Prefs) / C7 — the cycle SETTINGS entry**, mirroring
        /// the web settings row. Distinct from ``cycleRow`` (the feature home): it
        /// navigates to the Apple-Health integration detail that hosts the
        /// server-synced cycle opt-in toggle, so the on/off control is discoverable
        /// (incl. before opting in). Gated behind `FeatureFlag.cycleTracking`, like
        /// the whole cycle surface. NOT part of the curated ``clinicalRows`` list.
        /// R5-A1 (17-05) — der frühere Untertitel war eine Umformulierung des
        /// Titels und fiel deshalb unter R5/U7 weg. Unter R5-A1 wird er nicht
        /// gestrichen, sondern umgeschrieben, bis er etwas trägt: die Zeile
        /// führt zur Apple-Health-Integrationsseite, auf der der server-synchrone
        /// Zyklus-Opt-in sitzt — der Schalter UND der Sync gehören in den Satz.
        static let cycleSettingsRow = Row(
            id: "cycle_settings",
            icon: "gearshape",
            title: "more.cycleSettings.title",
            subtitle: "Turn tracking on or off, Apple Health sync"
        )

        /// v0.5.3-F3 — Web-Parity rows.
        static let workoutsRow = Row(
            id: "workouts",
            icon: "figure.run",
            title: "Workouts",
            subtitle: "Workouts from Apple Health"
        )
        /// v0.11 W-A — `targetsRow` removed. The "Goals" destination retired
        /// when targets folded into the per-metric chart detail (web parity).
        /// R5-A1 (17-05) — unter R5/U7 fiel der Untertitel als Umformulierung
        /// weg; er ist zurück und benennt jetzt die drei Abschnitte des Screens
        /// (Bestwerte, Streaks, Meilensteine) statt den Titel zu wiederholen.
        static let personalRecordsRow = Row(
            id: "personal_records",
            icon: "rosette",
            title: "Personal records",
            subtitle: "Best values, streaks, milestones"
        )

        /// v0.14.2 (#136) — Messwerte: metric-type picker →
        /// `MeasurementsPickerScreen`, which pushes the existing
        /// `MeasurementListScreen(kind:)` values table. `list.bullet.rectangle`
        /// reads as "a table of values", matching the destination's content.
        /// v0.14.8 W2 (Audit §3.c) — rendered in the Records & achievements
        /// section since the "Data & devices" section was dropped.
        /// R5-A1 (17-05) — unter R5/U7 fiel der Untertitel als Umformulierung
        /// weg; er ist zurück und sagt, wie die Liste sortiert ist, was die
        /// Zeile vom „Messen"-Weg unterscheidet.
        static let measurementsRow = Row(
            id: "measurements",
            icon: "list.bullet.rectangle",
            title: "Measurements",
            subtitle: "Every reading, newest first"
        )

        /// v1.18.1 (#30) — Lab results + biomarker catalog (mirror of the web
        /// labs surface). Gated behind the `labs` server module. `testtube.2`
        /// reads as "lab samples", matching the destination's content. Sits last
        /// in Records & achievements, next to Measurements (both browse health
        /// data). The biomarker catalog is reached from the LabsScreen toolbar,
        /// not a second row.
        /// v0153 INV-D — title repointed at the canonical screen key
        /// `labs.list.title` (de "Laborwerte") so the More row no longer leaks
        /// the unregistered English literal; the subtitle is its own keyed
        /// string ("more.labs.subtitle").
        static let labsRow = Row(
            id: "labs",
            icon: "testtube.2",
            title: "labs.list.title",
            subtitle: "more.labs.subtitle"
        )

        /// v1.18.3 (§1) — condition/illness journal (mirror of the web illness
        /// surface). Default-ON (born-gating dropped); shown unless the user
        /// disabled the module (`isEnabled(.illness) != false`).
        /// `heart.text.square` reads as a health journal.
        /// v0153 INV-D — title repointed at the canonical screen key
        /// `illness.journal.title` (de "Beschwerden-Tagebuch") so the More row
        /// no longer leaks the unregistered English literal; the subtitle is its
        /// own keyed string ("more.illness.subtitle").
        /// v1.26 W-ABOUT-ME → v1.26.1 W-ABOUT-ME-RECONCILE — briefly re-parented
        /// into `AboutMeScreen`, then RESTORED as a direct clinical-spine row.
        /// The operator clarified the Beschwerden-Tagebuch is an ongoing
        /// complaint/symptom LOG, not static self-info, so it does not belong in
        /// the "Über mich" hub — its front door lives back in the Mehr → Health &
        /// care section next to Labs, under the same `.illness` module gate.
        static let illnessRow = Row(
            id: "illness",
            icon: "heart.text.square",
            title: "illness.journal.title",
            subtitle: "more.illness.subtitle"
        )

        /// Document vault ("Dokumente") front door — opt-in `inboundDocuments`
        /// module (server ships it OFF by default; gated `!= false`).
        /// `doc.text.magnifyingglass` reads as a searchable document store,
        /// matching the vault's browse+search surface. Title/subtitle are keyed
        /// (de + en in `Localizable.xcstrings`).
        static let documentsRow = Row(
            id: "documents",
            icon: "doc.text.magnifyingglass",
            title: "documents.list.title",
            subtitle: "more.documents.subtitle"
        )

        /// Build 7.6 (GH #48) — nutrient read/display front door. Opt-in
        /// `nutrients` module (server ships it OFF by default; gated `!= false`).
        /// `leaf` reads as the diet/nutrition surface. Title/subtitle are keyed
        /// (de + en in `Localizable.xcstrings`).
        static let nutritionRow = Row(
            id: "nutrition",
            icon: "leaf",
            title: "nutrients.list.title",
            subtitle: "more.nutrients.subtitle"
        )

        /// Build 7 Item 7.7 — environmental-context front door (mirror of the web
        /// `environment` module). Default-ON tracking module (server v1.29.1); a
        /// disabled account self-gates to the neutral disabled hint. `cloud.sun`
        /// reads as the weather/daylight surface. Title/subtitle are keyed
        /// (de + en in `Localizable.xcstrings`). Rendered directly in the clinical
        /// spine like `nutritionRow` (not part of the curated `clinicalRows`
        /// invariant list — that array pins only the always-rendered core rows).
        static let environmentRow = Row(
            id: "environment",
            icon: "cloud.sun",
            title: "environment.list.title",
            subtitle: "more.environment.subtitle"
        )

        /// v1.26 W-ABOUT-ME — the "Über mich" personal / medical-history hub
        /// front door. Groups the re-parented condition-journal, allergies and
        /// family-history entry points plus the read-only profile basics
        /// (name + email + Krankenkasse). `person.text.rectangle` reads as a
        /// personal profile card. The three history rows below are no longer
        /// rendered directly in the Mehr menu — they are consumed by
        /// `AboutMeScreen` (see `hostedHistoryRows`) — but their descriptors are
        /// KEPT here as the single source of their icon + localized copy +
        /// `more.row.*` accessibility id, which the hub reuses verbatim.
        static let aboutMeRow = Row(
            id: "about_me",
            icon: "person.text.rectangle",
            title: "aboutMe.title",
            subtitle: "more.aboutMe.subtitle"
        )

        /// v1.25 W-RECORDS — Allergies front door (mirror of web `/allergies`;
        /// FHIR `AllergyIntolerance`). Default-on (no module gate in v1.25.0).
        /// `allergens` matches the records surface's empty-state glyph so the
        /// row→screen transition reads continuous.
        /// v1.26 W-ABOUT-ME — RE-PARENTED into `AboutMeScreen`; no longer a
        /// top-level Mehr row. The descriptor stays as the hub's single source.
        static let allergiesRow = Row(
            id: "allergies",
            icon: "allergens",
            title: "allergies.list.title",
            subtitle: "more.allergies.subtitle"
        )

        /// v1.25 W-RECORDS — Family history front door (mirror of web
        /// `/family-history`; FHIR `FamilyMemberHistory`). Default-on.
        /// v1.26 W-ABOUT-ME — RE-PARENTED into `AboutMeScreen`; no longer a
        /// top-level Mehr row. The descriptor stays as the hub's single source.
        /// R5 — Untertitel „Erkrankungen in der Familie" gefallen: eine
        /// Umformulierung des Titels „Familienanamnese".
        static let familyHistoryRow = Row(
            id: "family_history",
            icon: "figure.2.and.child.holdinghands",
            title: "familyHistory.list.title"
        )

        /// v1.25 W-MENTAL-HEALTH — opt-in PHQ-9 / GAD-7 self-assessment front door
        /// (mirror of web `/insights/mental-wellbeing`). ADDITIVE to mood, never a
        /// replacement; default-on (no module gate in v1.25.0). `brain.head.profile`
        /// reads as a mental-wellbeing check-in. Deliberately a More front-door —
        /// NOT in the per-metric Insights tab strip, NOT a Coach surface (the score
        /// signals are kept off the AI by construction).
        static let mentalWellbeingRow = Row(
            id: "mental_wellbeing",
            icon: "brain.head.profile",
            title: "more.mentalWellbeing.title",
            subtitle: "more.mentalWellbeing.subtitle"
        )

        /// v0.15 W-FRONTDOORS — Vorsorge / preventive-care front door (mirror of
        /// web `/vorsorge`). CORE (never module-gated). `stethoscope` matches the
        /// reminder list's card icon so the row→screen transition reads continuous.
        static let vorsorgeRow = Row(
            id: "vorsorge",
            icon: "stethoscope",
            title: "Preventive care",
            subtitle: "Measurement reminders, check-ups"
        )

        // v0152 W-COACH-CLEANUP (C2) — the `coachRow` descriptor was removed with
        // the More Coach row. The operator flagged the More-tab coach entry as a
        // stray surface that opened the coach against his External-AI pick; the
        // manual coach entry returns as an inline button on the Insights metric
        // pages (next wave). Coach settings stay reachable under Settings → Coach.

        // v0.14.8 (Task D) — `shareWithDoctorRow` removed: the list entry was
        // dropped in favour of the `MoreHeader` share glyph (left of the gear).
        // the sharing destination itself is unchanged by this row's removal.

        /// v0.6.1.5 Y5 — Sicherheit-section rows. Sign-out drops the
        /// session locally (server data stays); Konto löschen wipes the
        /// account server-side via the DeleteAccountScreen sheet.
        static let signOutRow = Row(
            id: "sign_out",
            icon: "rectangle.portrait.and.arrow.right",
            title: "Sign out",
            subtitle: "Your data on the server is preserved"
        )
        static let deleteAccountRow = Row(
            id: "delete_account",
            icon: "trash.fill",
            title: "Delete account",
            subtitle: "Irreversible, the server removes all data"
        )

        /// v0.14.1 (#134) — rows in the combined "Records & achievements"
        /// section, in render order: Persönliche Rekorde, Erfolge, Workouts.
        /// v0.14.8 W2 (Audit §3.c) — Messwerte appended when the orphaned
        /// "Data & devices" section was dropped.
        /// v0.15 W-FRONTDOORS — Labs + Illness moved to `clinicalRows` (the
        /// clinical-spine section), out of this records drawer.
        static let recordsRows: [Row] = [personalRecordsRow, achievementsRow, workoutsRow, measurementsRow]

        /// v0.15 W-FRONTDOORS — rows in the clinical-spine "Health & care"
        /// section, in render order: Vorsorge (core), Labs, Illness, Cycle
        /// (gated). Pinned for the contract test against silent drift.
        /// `vorsorgeRow` is always present; the rest gate per module / eligibility,
        /// so the rendered subset is a superset filter of this list.
        /// v0152 W-COACH-CLEANUP (C2) — the Coach row was removed (the operator
        /// flagged the stray More coach entry); it is no longer a clinical-spine row.
        /// v1.25 W-RECORDS — Allergies + Family history appended to the clinical
        /// spine next to Labs / Illness (first-class structured records the web
        /// surfaces directly; default-on, no module gate).
        /// v1.25 W-MENTAL-HEALTH — the mental-wellbeing screener front door
        /// appended to the clinical spine (default-on; additive to mood).
        /// v1.26 W-ABOUT-ME — the condition-journal, allergies and
        /// family-history rows were RE-PARENTED into the new "Über mich" hub
        /// (`aboutMeRow` → `AboutMeScreen`), which now leads the spine.
        /// v1.26.1 W-ABOUT-ME-RECONCILE — the condition journal (Beschwerden-
        /// Tagebuch) was RESTORED as a direct clinical-spine row next to Labs:
        /// the operator clarified it is an ongoing symptom LOG, not static
        /// self-info, so it does not belong in the hub. Allergies + family
        /// history STAY in the hub (they ARE static self-medical info), so their
        /// descriptors are still absent from this list.
        static let clinicalRows: [Row] = [aboutMeRow, vorsorgeRow, labsRow, illnessRow, documentsRow, mentalWellbeingRow, cycleRow]

        /// **R5-A1 (17-05) — every row the Mehr tab actually renders, in render
        /// order.** `recordsRows` and `clinicalRows` are section lists and do not
        /// add up to the tab: the cycle-settings, nutrition, environment, sign-out
        /// and delete-account rows are declared standalone, and the allergies /
        /// family-history descriptors are deliberately NOT here because they are
        /// rendered inside the „Über mich" hub rather than on this tab.
        ///
        /// It exists so the subtitle contract can be asserted over the real set: a
        /// row added later without a subtitle fails `SettingsSubtitleTests` instead
        /// of quietly reintroducing the inconsistency the operator flagged.
        static let renderedRows: [Row] = [
            aboutMeRow, vorsorgeRow, labsRow, illnessRow, documentsRow,
            mentalWellbeingRow, cycleRow, cycleSettingsRow, nutritionRow,
            environmentRow, personalRecordsRow, achievementsRow, workoutsRow,
            measurementsRow, signOutRow, deleteAccountRow
        ]

        // v0.14.8 (Task D) — `shareWithDoctorRows` removed alongside the section.
        // v0.14.8 W2 (Audit §3.c) — `dataDevicesRows` + `serverDataRows` removed
        // (see the section-title note above).
    }
}
