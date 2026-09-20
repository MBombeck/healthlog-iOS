import SwiftUI

// 1.0.3 (Task 4b) — split the Health & care ("Health & Pflege" / clinical-spine)
// section rows out of `MoreScreen.swift` to keep it under the 600-line
// file_length budget (PROJECT_GUIDE.md discipline) after Task 4 added the
// "Medical sources" row. Pure move: the rows, order, gating and copy are unchanged.

extension MoreScreen {
    /// Rows for the clinical-spine ("Health & care") section of the Mehr tab —
    /// extracted verbatim from `content` so `MoreScreen.swift` stays under the
    /// file-length budget. See the file header for why this split exists.
    @ViewBuilder
    var clinicalSectionRows: some View {
        // v1.26 W-ABOUT-ME — "Über mich" leads the clinical spine: one
        // calm home for everything the user records about themselves —
        // the read-only profile basics (name + email + Krankenkasse) and
        // the three re-parented self / medical-history modules (condition
        // journal, allergies, family history). Those three underlying
        // screens + their data wiring are unchanged; only their entry
        // point moved one hop deeper into `AboutMeScreen`. The
        // illness/allergies/family descriptors still live in `Layout`
        // (consumed by the hub), just no longer as direct rows here.
        NavigationLink {
            AboutMeScreen()
        } label: {
            HLSettingsRow(
                icon: Layout.aboutMeRow.icon,
                title: LocalizedStringKey(Layout.aboutMeRow.title),
                subtitle: Layout.aboutMeRow.subtitle.map { LocalizedStringKey($0) }
            )
        }
        .accessibilityIdentifier(Layout.aboutMeRow.accessibilityIdentifier)
        // v0150 design-M2 — row order mirrors the web `NAV_DESTINATIONS`
        // clinical spine EXACTLY (Cycle · Labs · Illness · Vorsorge ·
        // Coach; web's Insights sits between Vorsorge and Coach but is an
        // iOS top-level tab, not a More row, so it is omitted here). The
        // earlier iOS order (Vorsorge-first, Coach last after the gated
        // Cycle row) drifted from web parity; this restores it.
        // v0.14.8 C5 — the women-only cycle home (mirror of web `/cycle`).
        // The CycleGate hides this row for ineligible / opted-out users, and
        // it is hard-gated behind `FeatureFlag.cycleTracking` (default OFF).
        if container?.cycleGate.isCycleTrackingAvailable == true {
            NavigationLink {
                CycleScreen()
            } label: {
                HLSettingsRow(
                    icon: Layout.cycleRow.icon,
                    title: LocalizedStringKey(Layout.cycleRow.title),
                    subtitle: Layout.cycleRow.subtitle.map { LocalizedStringKey($0) }
                )
            }
            .accessibilityIdentifier(Layout.cycleRow.accessibilityIdentifier)
        }
        // Build 9 (Server-Prefs) / C7 — the cycle SETTINGS entry, mirroring
        // the web settings row. Gated identically to the cycle home row
        // above (`isCycleTrackingAvailable`: flag ON *and* eligible —
        // opted-in OR female OR HK-female OR server module on). The raw
        // flag defaults TRUE, so gating on it leaked a "Zyklus" row (→ the
        // Apple-Health screen) to every user incl. non-cycle males — a
        // dead end. A non-eligible user who wants to opt in still can, via
        // the opt-in toggle on the Apple-Health integration screen directly.
        if container?.cycleGate.isCycleTrackingAvailable == true {
            NavigationLink {
                AppleHealthIntegrationDetailScreen()
            } label: {
                HLSettingsRow(
                    icon: Layout.cycleSettingsRow.icon,
                    title: LocalizedStringKey(Layout.cycleSettingsRow.title),
                    subtitle: Layout.cycleSettingsRow.subtitle.map { LocalizedStringKey($0) }
                )
            }
            .accessibilityIdentifier(Layout.cycleSettingsRow.accessibilityIdentifier)
        }
        // v1.18.1 (#30) — Lab results + biomarker catalog. Gated behind the
        // `labs` server module (default-on). Promoted out of the generic
        // "Records & achievements" drawer into the clinical spine (web parity).
        if container?.moduleGate.isEnabled(.labs) != false {
            NavigationLink {
                LabsScreen()
            } label: {
                HLSettingsRow(
                    icon: Layout.labsRow.icon,
                    title: LocalizedStringKey(Layout.labsRow.title),
                    subtitle: Layout.labsRow.subtitle.map { LocalizedStringKey($0) }
                )
            }
            .accessibilityIdentifier(Layout.labsRow.accessibilityIdentifier)
        }
        // v1.18.3 (§1) — illness/condition journal, default-ON.
        // v1.26 W-ABOUT-ME → v1.26.1 W-ABOUT-ME-RECONCILE — briefly
        // re-parented into the "Über mich" hub, then RESTORED here as a
        // direct clinical-spine row next to Labs. The operator clarified
        // the Beschwerden-Tagebuch is an ongoing complaint/symptom LOG,
        // not static self-info, so it does not belong in the hub. The
        // `IllnessJournalScreen` + its `.illness` module gate are
        // unchanged; only the entry point moved back out of the hub.
        if container?.moduleGate.isEnabled(.illness) != false {
            NavigationLink {
                IllnessJournalScreen()
            } label: {
                HLSettingsRow(
                    icon: Layout.illnessRow.icon,
                    title: LocalizedStringKey(Layout.illnessRow.title),
                    subtitle: Layout.illnessRow.subtitle.map { LocalizedStringKey($0) }
                )
            }
            .accessibilityIdentifier(Layout.illnessRow.accessibilityIdentifier)
        }
        // Document vault ("Dokumente") — opt-in `inboundDocuments` module
        // (server ships it OFF by default). Same `!= false` gate idiom; the
        // vault self-gates to an enable-CTA if the route 403's mid-flight.
        if container?.moduleGate.isEnabled(.inboundDocuments) != false {
            NavigationLink {
                DocumentsScreen()
            } label: {
                HLSettingsRow(
                    icon: Layout.documentsRow.icon,
                    title: LocalizedStringKey(Layout.documentsRow.title),
                    subtitle: Layout.documentsRow.subtitle.map { LocalizedStringKey($0) }
                )
            }
            .accessibilityIdentifier(Layout.documentsRow.accessibilityIdentifier)
        }
        // Build 7.6 (GH #48) — nutrient read/display front door. Opt-in
        // `nutrients` module (server ships it OFF by default). Same
        // default-on `!= false` idiom; the screen self-gates to the
        // enable-in-settings hint if the route 403's mid-flight.
        if container?.moduleGate.isEnabled(.nutrients) != false {
            NavigationLink {
                NutrientListScreen()
            } label: {
                HLSettingsRow(
                    icon: Layout.nutritionRow.icon,
                    title: LocalizedStringKey(Layout.nutritionRow.title),
                    subtitle: Layout.nutritionRow.subtitle.map { LocalizedStringKey($0) }
                )
            }
            .accessibilityIdentifier(Layout.nutritionRow.accessibilityIdentifier)
        }
        // Build 7 Item 7.7 — environmental-context front door. Default-ON
        // `environment` module (server v1.29.1). Same `!= false` idiom as
        // the rows above; the screen self-gates to the disabled hint if the
        // `/api/environment` route 403's mid-flight.
        if container?.moduleGate.isEnabled(.environment) != false {
            NavigationLink {
                EnvironmentScreen()
            } label: {
                HLSettingsRow(
                    icon: Layout.environmentRow.icon,
                    title: LocalizedStringKey(Layout.environmentRow.title),
                    subtitle: Layout.environmentRow.subtitle.map { LocalizedStringKey($0) }
                )
            }
            .accessibilityIdentifier(Layout.environmentRow.accessibilityIdentifier)
        }
        // v1.25 W-MENTAL-HEALTH — WHO-5 / PHQ-9 / GAD-7 self-assessment.
        // Additive to mood, never a replacement. A More front-door, NOT a
        // per-metric Insights tab and NOT a Coach surface (the score
        // signals are kept off the AI).
        //
        // Build 2 / 2.6 — gated on the `mentalHealth` module. The server
        // grew the key in v1.29.1; until now this row mounted
        // unconditionally and the screen 403'd (`module.disabled`) for
        // anyone who had switched the module off. Same default-on
        // `!= false` idiom as the illness/documents rows above.
        if container?.moduleGate.isEnabled(.mentalHealth) != false {
            NavigationLink {
                MentalWellbeingScreen()
            } label: {
                HLSettingsRow(
                    icon: Layout.mentalWellbeingRow.icon,
                    title: LocalizedStringKey(Layout.mentalWellbeingRow.title),
                    subtitle: Layout.mentalWellbeingRow.subtitle.map { LocalizedStringKey($0) }
                )
            }
            .accessibilityIdentifier(Layout.mentalWellbeingRow.accessibilityIdentifier)
        }
        // v0.15 W-FRONTDOORS (GAP 1) — Vorsorge front door. CORE, never
        // module-gated (a reminder can target core vitals weight/BP/pulse
        // or be free-text — gating would orphan reminders the user can
        // still create). The deep path (gear → Notifications → preventive
        // card → Manage) still works; this is the direct front door.
        NavigationLink {
            MeasurementRemindersScreen()
        } label: {
            HLSettingsRow(
                icon: Layout.vorsorgeRow.icon,
                title: LocalizedStringKey(Layout.vorsorgeRow.title),
                subtitle: Layout.vorsorgeRow.subtitle.map { LocalizedStringKey($0) }
            )
        }
        .accessibilityIdentifier(Layout.vorsorgeRow.accessibilityIdentifier)
        // 1.0.3 (App Review 1.4.1) — Medical sources hub. CORE, never gated.
        NavigationLink {
            MedicalSourcesScreen()
        } label: {
            HLSettingsRow(
                icon: Layout.medicalSourcesRow.icon,
                title: LocalizedStringKey(Layout.medicalSourcesRow.title),
                subtitle: Layout.medicalSourcesRow.subtitle.map { LocalizedStringKey($0) }
            )
        }
        .accessibilityIdentifier(Layout.medicalSourcesRow.accessibilityIdentifier)
        // v0152 W-COACH-CLEANUP (C2) — the "Mehr" Coach row was removed.
        // The operator flagged it as a stray coach entry ("das wird auch
        // ein Fehler sein dass die da drin ist") that opened the coach
        // against his External-AI pick. The manual coach entry returns as
        // an inline button on the Insights metric pages (later update); the
        // proactive nudge still surfaces server-side. Coach settings
        // (Past conversations, memory) stay reachable under Settings →
        // Coach. No More-row coach affordance here.
    }
}
