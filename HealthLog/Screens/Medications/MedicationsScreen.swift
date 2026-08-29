import SwiftUI

struct MedicationsScreen: View {
    @Environment(MedicationsStore.self) private var store
    @Environment(\.appContainer) private var container
    /// v0.12 W0-1 — bind the tab's `NavigationStack` to the router's `medsPath`
    /// so deep links (`healthlog://medications/<id>`, med-reminder body-taps,
    /// the in-app inbox) that append a `MedicationDetailRoute` actually push the
    /// detail screen instead of dead-ending at the list root. Before this the
    /// stack was unbound: the router mutated `medsPath` and nothing observed it.
    @Environment(AppRouter.self) private var router
    /// **v0.14.1 INV-med-cadence-phantom (BUG 2)** — force a today-intakes
    /// revalidate on every foreground so a stale optimistic `.taken` snapshot
    /// (served via SWR `.cached`) can't survive an app resume / day-boundary
    /// crossing and render a phantom "taken today" that masks a real pending
    /// dose. The day-anchored cache key already makes a NEW calendar day a
    /// structural miss; this additionally reconciles a same-day stale snapshot.
    @Environment(\.scenePhase) private var scenePhase

    @State private var isPresentingAdd: Bool = false
    /// **W-B184 MED-1** — drives the layout customize sheet (view-mode toggle
    /// + native reorder) opened from the header wrench.
    @State private var isPresentingCustomize: Bool = false
    @State private var editing: Medication?
    @State private var archiveConfirmTarget: Medication?
    @State private var showArchived: Bool = false
    /// History tap on a card pushes the detail screen. Set from the
    /// header icon button on `MedicationCard`; the `.navigationDestination`
    /// already routes `Medication` value, so we re-use it.
    @State private var historyPushTarget: Medication?
    /// M1 — an in-app compliance-bar tap. Routes to the detail screen with
    /// `focus: .compliance`, which pre-expands the Verlauf disclosure but opens
    /// at the TOP (no auto-scroll). Distinct from `historyPushTarget` (the
    /// header history icon → `.history`, which DOES scroll to Verlauf) so the
    /// operator tapping the compliance bars no longer lands scrolled down.
    @State private var compliancePushTarget: Medication?
    /// **v0.11 #60 / 15-04** — the quick path's interstitial slot. One
    /// presentation, two reasons to use it: an injection-site capture before a
    /// TAKEN write on a tracked med (the mark fires only once a site is picked),
    /// and — since 15-04 — the deviating-dose dialog a long-press on Genommen
    /// opens. Oral meds never populate the first (the mark fires immediately).
    @State private var siteCaptureTarget: MedicationQuickInterstitial?

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.medsPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    // v0.6.1.3 Y4.1 — inline header (handbook §3.1
                    // Flavour A — DashboardHeader pattern). The "+"
                    // button sits inline with the large title at the
                    // same baseline, no circle backplate, monochrome
                    // glyph. The legacy `.toolbar` slot below moves to
                    // a no-op so the system navigation chrome doesn't
                    // render a competing trailing affordance.
                    MedicationsHeader(
                        onAdd: { isPresentingAdd = true },
                        onCustomize: { isPresentingCustomize = true }
                    )

                    // audit-release 05 C-1 — a critical (life-safety) med alarm
                    // that failed to arm used to be silently swallowed. Surface
                    // a persistent, honest warning naming the affected meds, with
                    // a re-arm retry (a forced reload re-runs the reconcile). Not
                    // the transient `store.error` banner: this state must stay
                    // visible until the alarm actually arms.
                    if !store.criticalAlarmFailureNames.isEmpty {
                        CriticalAlarmFailureBanner(
                            medicationNames: store.criticalAlarmFailureNames,
                            onRetry: { Task { await store.load(force: true) } }
                        )
                    }

                    if isShowingInitialSkeleton {
                        MedicationsSkeletonContent()
                    } else if hasNoContent {
                        EmptyMedicationsState(onAdd: { isPresentingAdd = true })
                    } else {
                        // v0.6.1.4 Y4.2 — operator brief 2026-05-23
                        // dropped the screen-level aggregate compliance
                        // stripe. The 7- and 30-day bars on each
                        // `MedicationCard` (v0.6.1.2 Y4) and the
                        // ComplianceKPI tile on `MedicationDetailScreen`
                        // carry the adherence visualisation now — the
                        // tab header opens directly into the card
                        // stack with no preface graphic.
                        //
                        // v0.6.1.2 Y4 (D-018): the legacy "Heute"
                        // section is gone from this tab. Operator brief
                        // 2026-05-22: "Heute"-Rhythmus komplett weg —
                        // die Liste zeigt jetzt nur Aktive (+ optional
                        // Archivierte) Medikamente. Take/Snooze/Skip
                        // wandert in den Detail-Screen pro Medikament.
                        ActiveMedicationsSection(
                            medications: store.activeMedications,
                            todayIntakes: store.derivedTodayIntakes,
                            onAdd: { isPresentingAdd = true },
                            onEdit: { medication in editing = medication },
                            onArchive: { medication in archiveConfirmTarget = medication },
                            onMark: { intakeId, status, medication in
                                // v0.11 W26 — undo-aware mark: the store fires
                                // the mark + enqueues a `Rückgängig` toast so a
                                // mis-tap on Genommen/Übersprungen is reversible.
                                // v0.11 #60 — for an injection-tracked med a
                                // TAKEN tap first captures a site (web parity);
                                // oral meds + every Übersprungen fire immediately.
                                dispatchQuickMark(intakeId: intakeId, status: status, medication: medication)
                            },
                            onMarkAdHoc: { medication, status in
                                // Synthesise a placeholder id and route through
                                // the bulk-intake POST. Used for PRN / off-day
                                // weekly meds that have no today-intake row yet.
                                // v0.14.2 H3 — resolve `scheduledFor` to the
                                // nearest DUE recurrence slot for a scheduled
                                // (non-PRN) med so a weekly off-day / cyclic
                                // off-week mark attaches to the real slot, not
                                // `now` (which mis-attributes compliance). PRN
                                // keeps `now`.
                                let scheduledFor = ActiveMedicationsSection.resolveAdHocScheduledFor(
                                    medication: medication,
                                    now: .now,
                                    timeZone: store.profileTimeZone
                                )
                                let placeholderID = MedicationIntake.synthesizedPlaceholderID(
                                    medicationId: medication.id,
                                    scheduledAt: scheduledFor
                                )
                                dispatchQuickMark(intakeId: placeholderID, status: status, medication: medication)
                            },
                            onHistory: { medication in historyPushTarget = medication },
                            // M1 — compliance-bar tap opens the detail at the TOP
                            // (focus `.compliance`, pre-expands Verlauf but does
                            // not auto-scroll). Previously reused `historyPushTarget`
                            // → `.history`, which scrolled the page to Compliance and
                            // read as "med opens scrolled wrong" (only daily meds
                            // render the tappable bars, so the bug looked
                            // inconsistent vs weekly meds). The header history icon
                            // keeps its deliberate scroll via `historyPushTarget`.
                            onComplianceTap: { medication in compliancePushTarget = medication },
                            // 15-04 (E3) — long-press on Genommen opens the
                            // existing deviating-dose dialog for that med.
                            onDeviatingDose: { target in siteCaptureTarget = .deviatingDose(target) },
                            windowIntakes: store.derivedTodayIntakes
                        )

                        if !store.archivedMedications.isEmpty {
                            ArchivedMedicationsSection(
                                medications: store.archivedMedications,
                                isExpanded: $showArchived,
                                onUnarchive: { medication in
                                    Task { await store.unarchive(id: medication.id) }
                                }
                            )
                        }

                        // 25-02 (E-2026-08-29 #1) — the global injection-site
                        // deny-list door, moved here from Einstellungen →
                        // Datenschutz und Sicherheit. It governs exactly the
                        // intake pickers of THIS tab's injection meds, so its
                        // management lives with them — and only for a person
                        // it can do anything for (at least one injection med).
                        if Self.showsInjectionSitesDoor(medications: store.medications) {
                            injectionSitesCard
                        }
                    }

                    // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
                    // primitive as Dashboard/Insights, self-suppressing).
                    HLSyncStatusFooter(screenLoading: store.isLoading)
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
                // Native iOS-18 `TabView` already supplies the bottom inset;
                // the legacy 96pt was a pre-native-`TabView` leftover (M2-A2).
                .padding(.bottom, HLSpace.lg)
            }
            // UI-MANIFEST §4: every screen canvas resolves through
            // `.hlScreenBackground()` so the `scrollContentBackground` +
            // `listRowBackground` wipes are applied uniformly. The previous
            // direct `.background(HLColor.background...)` rendered the same
            // pixel color but skipped those wipes, which is the kind of
            // ad-hoc drift the manifest forbids.
            .hlScreenBackground()
            // v0.5.x C-9 — iOS 26+ soft scroll-edge so content blurs into
            // the navigation Liquid Glass instead of clipping cleanly.
            // iOS 18-25: no-op (system stays flat-translucent).
            .hlScrollEdgeSoft()
            // v0.6.1.3 Y4.1 — large title moves into the inline
            // `MedicationsHeader` so the "+" button can sit at the same
            // baseline (handbook §3.1 Flavour A). The `.navigationTitle`
            // is intentionally omitted; the NavigationStack still owns
            // the back-stack behaviour for pushed detail screens.
            .navigationBarTitleDisplayMode(.inline)
            // W-B184 — WHOOP-style pull-to-refresh (custom glyph + checkmark +
            // one success haptic; the sync handshake driving the checkmark runs
            // inside the modifier).
            // 21-03 (D-14-06-C) — the pull is the one trigger a person
            // performs, so it says so. `force: true` because a pull inside the
            // 60 s `medicationsList` TTL would otherwise short-circuit to
            // `.fresh(cached)` and be a no-op by construction — the other half
            // of "das Runterziehen bringt keine Lösung", and the reason
            // `.onAppear` below already forces while the pull did not.
            .hlPullToRefresh { await store.load(force: true, intent: .userInitiated) }
            .task { if store.medications.isEmpty { await store.load() } }
            // v0.5.5.1 — after archive-all the server-emitted today-rows
            // orphan the Today section (synth only fires for active meds).
            // Refresh on every tab-activation so the next SWR revalidate
            // flushes the stale intake rows.
            // v0.14.1 INV-med-cadence-phantom (BUG 2) — `force: true` bypasses
            // the today-intakes 30s TTL so the meds surface always reconciles a
            // possibly-stale optimistic `.taken` snapshot against the server on
            // appear (prefer a `.fresh` round-trip over trusting `.cached`).
            .onAppear { Task { await store.load(force: true) } }
            // v0.14.1 INV-med-cadence-phantom (BUG 2) — same force-revalidate on
            // every background→foreground transition: a resume can cross a day
            // boundary or land after a server-side intake correction, and a
            // forced load replaces any stale snapshot with the canonical state
            // so the card never shows a phantom "taken" + disabled Genommen.
            // W-PERF-SWR (Med/High) — route the foreground forced load through
            // the store's throttle so a rapid background→foreground flap
            // (notification-center peek, app-switcher scrub) coalesces into one
            // round-trip instead of fanning out 3 force-revalidates per event.
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await store.loadOnForeground() }
                }
            }
            .hlErrorBannerOverlay(error: store.error) {
                Task { await store.load() }
            }
            .sheet(isPresented: $isPresentingAdd) {
                AddMedicationSheet(
                    onSaved: { isPresentingAdd = false },
                    onDismiss: { isPresentingAdd = false }
                )
            }
            // W-B184 MED-1 — customize sheet. 08-05 removed the presentation
            // picker and 08-13 removed the branch it used to choose between,
            // so native reorder is all this sheet does; it PUTs
            // `/api/medications/layout` with order only.
            .sheet(isPresented: $isPresentingCustomize) {
                MedicationsLayoutCustomizeSheet()
            }
            .sheet(item: $editing) { medication in
                EditMedicationSheet(
                    medication: medication,
                    onSaved: { editing = nil },
                    onDismiss: { editing = nil }
                )
            }
            // v0.11 #60 — injection-site capture interstitial for the quick
            // "Genommen" path. Presented only for `injectionSiteCaptureEnabled`
            // meds; on confirm it threads the chosen site into the existing
            // undoable mark (optimistic-write + Outbox + undo-toast preserved).
            .sheet(item: $siteCaptureTarget) { target in
                switch target {
                case let .injectionSite(capture):
                    IntakeSiteCaptureSheet(
                        medication: capture.medication,
                        onConfirm: { site in
                            siteCaptureTarget = nil
                            Task {
                                await store.markIntakeQuickUndoable(
                                    intakeId: capture.intakeId,
                                    status: .taken,
                                    injectionSite: site
                                )
                            }
                        },
                        onCancel: { siteCaptureTarget = nil }
                    )
                case let .deviatingDose(target):
                    // 15-04 (E3) — the dialog that already exists, reached in
                    // two gestures instead of three taps and a memory of where
                    // "Manuell nachtragen" lives. Wrapped in its own stack so
                    // the sheet keeps a title bar and its Save action.
                    NavigationStack {
                        MedicationFreeIntakeSheet(
                            preselectedMedicationID: target.medicationID,
                            // `.failed` keeps the sheet open with its own inline
                            // error; success and queued both close it.
                            onDone: { _ in siteCaptureTarget = nil }
                        )
                    }
                }
            }
            .hlConfirmDestructive(
                Text("Archive medication?"),
                presenting: $archiveConfirmTarget,
                message: { target in
                    Text("“\(target.name)” will be hidden. History is kept and can be restored later.")
                },
                confirm: Text("Archive"),
                cancel: Text("Cancel"),
                onCancel: { archiveConfirmTarget = nil },
                action: { target in
                    Task { await store.archive(id: target.id) }
                    archiveConfirmTarget = nil
                }
            )
            // Routes the row-tap to Stream Delta's real `MedicationDetailScreen`.
            // The placeholder shipped by Alpha (A1-Audit §5, user-report #2
            // "kein Effekt") is replaced here.
            .navigationDestination(for: Medication.self) { medication in
                if let container {
                    MedicationDetailScreen(
                        medication: medication,
                        repo: container.medicationsRepo,
                        glp1LocalRepo: container.glp1LocalRepo,
                        therapyLogRepo: container.syncModeStore.isPaired ? container.medicationTherapyLogRepo : nil,
                        // W-TZ-MED — bucket the Verlauf track on the server-profile
                        // zone (same provider the store's due-derive uses).
                        profileTimeZoneProvider: store.profileTimeZoneProvider
                    )
                } else {
                    // Defensive — environment not provisioned (preview, etc.).
                    // The production path always has the container.
                    Text(medication.name)
                        .font(.hlTitle2)
                        .padding()
                }
            }
            .navigationDestination(item: $historyPushTarget) { medication in
                // v0.12 W0-1 — the card-header history icon now passes
                // `focus: .history` so it converges on the Verlauf section
                // (same surface a `…/history` reminder deep-link lands on).
                if let container {
                    MedicationDetailScreen(
                        medication: medication,
                        repo: container.medicationsRepo,
                        glp1LocalRepo: container.glp1LocalRepo,
                        therapyLogRepo: container.syncModeStore.isPaired ? container.medicationTherapyLogRepo : nil,
                        // W-TZ-MED — server-profile day-anchoring for the track.
                        profileTimeZoneProvider: store.profileTimeZoneProvider,
                        focus: .history
                    )
                } else {
                    Text(medication.name)
                        .font(.hlTitle2)
                        .padding()
                }
            }
            .navigationDestination(item: $compliancePushTarget) { medication in
                // M1 — the in-app compliance-bar tap. Opens at the TOP with the
                // Verlauf disclosure pre-expanded (`focus: .compliance`), but does
                // NOT auto-scroll. Genuine reminder/URL deep-links keep `.history`.
                if let container {
                    MedicationDetailScreen(
                        medication: medication,
                        repo: container.medicationsRepo,
                        glp1LocalRepo: container.glp1LocalRepo,
                        therapyLogRepo: container.syncModeStore.isPaired ? container.medicationTherapyLogRepo : nil,
                        profileTimeZoneProvider: store.profileTimeZoneProvider,
                        focus: .compliance
                    )
                } else {
                    Text(medication.name)
                        .font(.hlTitle2)
                        .padding()
                }
            }
            // v0.12 W0-1 — typed deep-link destination. The router appends
            // `MedicationDetailRoute(id:focus:)` to `medsPath` for
            // `healthlog://medications/<id>` and `…/<id>/history` (and the
            // med-reminder body-tap, which synthesises the former). Resolve the
            // id against the loaded catalog → push `MedicationDetailScreen` with
            // the requested focus. This is the W0-2 ship-gate: a med-reminder
            // tap now lands on the dose detail, not the list root.
            .navigationDestination(for: MedicationDetailRoute.self) { route in
                medicationDetailDestination(for: route)
            }
        }
    }

    /// v0.12 W0-1 — resolves a `MedicationDetailRoute` (id + focus) to the
    /// detail screen. If the catalog isn't loaded yet (cold-start-from-tap), a
    /// `.task` kicks the load and the view re-resolves once `store.medications`
    /// hydrates; until then it shows a lightweight progress placeholder rather
    /// than a dead end. An id with no matching medication (stale reminder for an
    /// archived/deleted med) shows the same placeholder while loading, then a
    /// "not found" message — never a crash.
    @ViewBuilder
    private func medicationDetailDestination(for route: MedicationDetailRoute) -> some View {
        if let container, let medication = store.medications.first(where: { $0.id == route.id }) {
            MedicationDetailScreen(
                medication: medication,
                repo: container.medicationsRepo,
                glp1LocalRepo: container.glp1LocalRepo,
                therapyLogRepo: container.syncModeStore.isPaired ? container.medicationTherapyLogRepo : nil,
                // W-TZ-MED — server-profile day-anchoring for the track.
                profileTimeZoneProvider: store.profileTimeZoneProvider,
                focus: route.focus
            )
        } else {
            // QoS-1 (A360-4) — the cold deep-link placeholder must not spin
            // forever on a failed cold-start. `MedicationDeepLinkPlaceholder`
            // owns the load and renders three honest terminal states:
            // spinner while loading, an inline error + "Erneut versuchen" on a
            // failed load (`store.error`), and the documented "not found"
            // message once the load settles but the id is absent.
            MedicationDeepLinkPlaceholder(store: store, requestedID: route.id)
        }
    }

    /// First-paint skeleton: we have no rows in memory yet AND the store
    /// is mid-load. Subsequent loads (refresh, scenePhase) keep the
    /// existing content visible (`isShowingStaleCache`) — the SWR pattern
    /// dictates we don't re-flash the skeleton on every revalidation.
    ///
    /// W-MED2: keep the medications-empty gate as-is — `medications`
    /// reflects the user's catalog (server is authoritative). The
    /// `derivedTodayIntakes` synthesis only fires when `medications` is
    /// non-empty, so the skeleton-vs-content branch is unaffected.
    private var isShowingInitialSkeleton: Bool {
        store.isLoading && store.medications.isEmpty && store.todayIntakes.isEmpty
    }

    /// True when the load has settled and there is genuinely nothing for
    /// the user to look at. Distinguishes "still loading" from "no
    /// medications recorded yet". The "no rows" branch is the operator's
    /// first-launch state — once a medication exists, the synth-overlay
    /// keeps the screen populated regardless of server intake-event
    /// timing.
    private var hasNoContent: Bool {
        !store.isLoading
            && store.medications.isEmpty
            && store.todayIntakes.isEmpty
            && store.error == nil
    }

    /// **v0.11 #60** — single decision point for every quick "Genommen" /
    /// "Übersprungen" tap on this screen (card CTA + list ✓/swipe).
    ///
    /// For a TAKEN write on an `injectionSiteCaptureEnabled` med we present the
    /// `IntakeSiteCaptureSheet` first (web parity: mark-taken → site prompt →
    /// done) and fire the mark only once the operator picks a site (or skips).
    /// Every other case — a SKIPPED write, or an oral / non-tracked med — fires
    /// the undoable mark immediately with no popup, so Lisinopril is unchanged.
    private func dispatchQuickMark(intakeId: String, status: IntakeStatus, medication: Medication) {
        if status == .taken, medication.injectionSiteCaptureEnabled {
            siteCaptureTarget = .injectionSite(QuickSiteCapture(intakeId: intakeId, medication: medication))
            return
        }
        Task { await store.markIntakeQuickUndoable(intakeId: intakeId, status: status) }
    }

    // MARK: - Injection sites (25-02, E-2026-08-29 #1)

    /// The user-level global deny-list editor's door, moved out of
    /// Einstellungen → Datenschutz und Sicherheit. The list it edits governs
    /// exactly this tab's injection intake pickers (deny always wins, server
    /// v1.8.5), so its management lives with the medications — same card
    /// shape, same catalogue keys, same destination screen as before the move.
    private var injectionSitesCard: some View {
        HLSettingsCard(
            icon: "circle.grid.cross",
            title: "Injection sites"
        ) {
            HLSettingsActionRow(title: "Manage sites", presents: .push) {
                SettingsInjectionSitesScreen()
            }
            .accessibilityIdentifier("medications.injectionSitesRow")
        }
    }

    /// The door renders only for a person the deny-list can do anything for:
    /// somebody with at least one injection medication (active or archived —
    /// an archived pen can be unarchived, and its site exclusions should be
    /// editable before that). Zero injection meds → no door, no explainer —
    /// the same calm rule the score tile follows.
    static func showsInjectionSitesDoor(medications: [Medication]) -> Bool {
        medications.contains { $0.isInjection }
    }
}

/// **v0.11 #60** — pending quick-path injection-site capture payload. Carries
/// the resolved intake id (real, synth-placeholder, or ad-hoc) plus its
/// medication so the capture sheet can load the effective allowed-set and the
/// confirm closure can fire the undoable mark with the chosen site.
/// **15-04** — what the medications screen's one interstitial slot is showing.
/// An enum rather than a second `.sheet`: the quick path has exactly one
/// modal moment, and which moment it is depends on the gesture.
enum MedicationQuickInterstitial: Identifiable {
    /// v0.11 #60 — capture an injection site before the TAKEN write lands.
    case injectionSite(QuickSiteCapture)
    /// 15-04 (E3) — "Mit abweichender Dosis erfassen…", opened by a long-press
    /// on a card's Genommen CTA. Carries what the existing free-intake dialog
    /// is preselected with.
    case deviatingDose(MedicationCardActions.DeviatingDose)

    var id: String {
        switch self {
        case let .injectionSite(capture): "site:" + capture.id
        case let .deviatingDose(target): "dose:" + target.medicationID
        }
    }
}

struct QuickSiteCapture: Identifiable {
    let intakeId: String
    let medication: Medication
    var id: String {
        intakeId
    }
}

// MARK: - Inline header (v0.6.1.3 Y4.1)

/// **Medikamente screen header — v0.6.1.3 Y4.1.**
///
/// Mirrors the Dashboard `DashboardHeader` + MoreScreen `MoreHeader`
/// pattern (handbook §3.1 Flavour A / B): the screen-level affordance
/// — here the "Medikament hinzufügen" plus glyph — sits inline with
/// the large title at the same vertical baseline, no circle backplate,
/// monochrome glyph in `HLText.primary`. The handbook anti-pattern
/// AP-018 explicitly bans the `.topBarTrailing` toolbar slot for this
/// kind of inline affordance.
///
/// The glyph is sized at 22pt so it visually matches the `.hlLargeTitle`
/// next to it without a circle backplate (the same trick `MoreHeader`
/// uses for the gear in Y5's eventual refactor). 44pt tap target stays
/// satisfied by the outer `.frame(minWidth:, minHeight:)`.
private struct MedicationsHeader: View {
    let onAdd: () -> Void
    /// **W-B184 MED-1** — opens the layout customize sheet (view-mode toggle +
    /// native reorder). Sits inline before the "+" affordance, monochrome glyph
    /// matching the same baseline.
    let onCustomize: () -> Void

    private static let buttonSize: CGFloat = 44

    var body: some View {
        HStack(alignment: .center, spacing: HLSpace.md) {
            Text(LocalizedStringKey("Medications"))
                .font(.hlLargeTitle)
                .foregroundStyle(HLText.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: onCustomize) {
                Image(systemName: "slider.horizontal.3")
                    .font(.hlTitle2)
                    .foregroundStyle(HLText.primary)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(LocalizedStringKey("med.layout.customize.title")))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("medications.header.customizeButton")
            Button(action: onAdd) {
                // Y8 M-3: lift the + glyph off the raw 22pt literal
                // onto .hlTitle2 (22pt @L) so it scales with the
                // .hlLargeTitle title beside it under accessibility
                // text-size pref instead of locking small.
                Image(systemName: "plus")
                    .font(.hlTitle2)
                    .foregroundStyle(HLText.primary)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(LocalizedStringKey("Add medication")))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("medications.header.addButton")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// W-UX2 (2026-05-21): `ComplianceHeatmapSection` extracted to its own file
// (`ComplianceHeatmapSection.swift`) so the new GitHub-style 8-week grid +
// `GitHubGreen` palette can carry the dedicated documentation without
// pushing this screen past the SwiftLint file-length budget.
//
// W-MEDS-VISUAL-IMPL (Issue #7, 2026-05-21): `ActiveMedicationsSection` +
// `EmptyActiveMedicationsState` extracted to `ActiveMedicationRow.swift`
// so the one-card-per-medication redesign + its empty-state pattern can
// land alongside the row component without pushing this host past the
// file-length budget.
//
// v0.5.6 (REG-5, B1, 2026-05-21): `ArchivedMedicationsSection` extracted
// to `ArchivedMedicationsSection.swift` for the same file-length reason
// after the REG-5 visual-contract unification grew the section past
// the inline-section size that fit in this host.
//
// v0.6.1.4 Y4.2 — operator brief 2026-05-23 dropped the screen-level
// `.searchable` field. The previous filter helper and no-match empty
// state lived in `MedicationsScreen+Search.swift`; that file is gone
// alongside the search bar. The card stack now renders the full active
// list directly — scrolling carries the long tail.
