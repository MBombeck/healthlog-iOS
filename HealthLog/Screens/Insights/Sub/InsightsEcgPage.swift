import SwiftUI

/// The Insights **ECG** special page (P8, web `/insights/ecg`, server v1.28.50).
///
/// Lists the single-lead ECG strips the operator's device recorded, each with
/// the DEVICE's own result. Metadata only — the trace itself lives one push
/// deeper, on ``EcgDetailScreen``.
///
/// **Regulatory framing (load-bearing — do NOT soften).** HealthLog shows the
/// recording and the result the recording device produced. It never
/// re-classifies, never interprets the waveform, and never diagnoses. The
/// permanent, non-dismissible disclaimer at the foot of the page is part of the
/// copy contract shared with the web app; the "discuss with a clinician" note
/// appears only for a NON-NORMAL DEVICE verdict and is likewise not a HealthLog
/// assessment. Same posture as `InsightsRhythmEventsCard`.
///
/// **Data-gated.** The pill only exists when `EcgStore.hasRecordings` is true
/// (`liveAvailableSpecials`), so this page is normally reached with recordings;
/// the empty branch catches the availability latch, a revalidation blip and the
/// pulse-page cross-link. CU-37 rewrote it to state the truth — nothing has been
/// uploaded yet — and to hand over the archive-import path that works today.
///
/// **Lives inside the Insights pager.** Owns no `NavigationStack` (the
/// container does). Its inner `ScrollView` reports its offset to
/// `InsightsStripVisibility`; header anatomy is the shared `InsightsPageHeader`
/// so the top region never jumps across the pager.
struct InsightsEcgPage: View {
    @Environment(EcgStore.self) private var store
    /// The container's hide-on-scroll model — **OPTIONAL** for the same reason
    /// `InsightsMetricScreen` reads it optionally: since the pulse-page
    /// cross-link (P8 B-5) this page is ALSO pushed from stacks that carry no
    /// Insights tab strip (e.g. the Dashboard drill-down into the pulse page).
    /// Present in the pager → the offset report drives the strip; absent →
    /// harmless no-op. Reading it non-optionally would trap there.
    @Environment(InsightsStripVisibility.self) private var stripVisibility: InsightsStripVisibility?
    /// CU-37 — the empty state routes to Settings → Apple-Health-Import. Read
    /// OPTIONALLY for the same reason as `stripVisibility`: this page is pushed
    /// from several stacks (Insights pager, Dashboard pulse drill-down) and is
    /// constructed bare in tests and previews, where a non-optional read traps.
    @Environment(AppRouter.self) private var router: AppRouter?
    /// The archive import is a SERVER endpoint — standalone has no route for it.
    @Environment(BackendAvailability.self) private var backend: BackendAvailability?
    /// GH #74 — container access for the device-local ECG upload switch. The
    /// `appContainer` environment key is already optional, so this page keeps
    /// building bare in tests and previews.
    @Environment(\.appContainer) private var container

    var body: some View {
        Group {
            if store.hasRecordings {
                content
            } else {
                emptyState
            }
        }
        .background(HLSurface.primary.ignoresSafeArea())
        .task {
            if store.list == nil { await store.load() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                InsightsPageHeader(
                    "insights.ecg.title",
                    subtitle: "insights.ecg.subtitle",
                    accessibilityIdentifierSuffix: "ecg"
                )

                Text("insights.ecg.intro")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                recordingsList

                if store.loadFailed {
                    Text("insights.ecg.loadError")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                EcgDisclaimerBlock()

                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxl)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            stripVisibility?.report(offset: newOffset)
        }
        .hlScrollEdgeSoft()
        .hlPullToRefresh { await store.refresh() }
    }

    private var recordingsList: some View {
        HLCard {
            VStack(spacing: 0) {
                ForEach(Array(store.recordings.enumerated()), id: \.element.id) { index, recording in
                    row(for: recording)
                    if index < store.recordings.count - 1 {
                        Divider().overlay(HLColor.separator)
                    }
                }
            }
        }
        .accessibilityIdentifier("insights.ecg.list")
    }

    /// One recording row. Tappable ONLY when a waveform exists — a `ts-`
    /// fallback event carries a verdict but no signal, so its row is a plain
    /// line rather than a push into an empty screen.
    @ViewBuilder
    private func row(for recording: EcgRecordingDTO) -> some View {
        if EcgPresentation.isOpenable(recording) {
            NavigationLink {
                EcgDetailScreen(recording: recording)
            } label: {
                EcgRecordingRow(recording: recording, showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insights.ecg.row.\(recording.id)")
        } else {
            EcgRecordingRow(recording: recording, showsChevron: false)
                .accessibilityIdentifier("insights.ecg.row.\(recording.id)")
        }
    }

    /// Calm, **honest** empty state (CU-37).
    ///
    /// The copy this replaced said recordings "sync from a compatible
    /// single-lead device" — which implied a transfer that did not exist. An
    /// empty surface means *nothing was ever uploaded*, not *no ECG exists*,
    /// and the body says exactly that.
    ///
    /// It names the archive path (Apple Health → `export.zip` → Einstellungen →
    /// Apple-Health-Import, which ``AppleHealthImportService`` already posts to
    /// and the server already parses ECG CSVs out of) and offers it as a route
    /// rather than a description. No promise carries a date.
    ///
    /// **GH #74 update.** The premise CU-37 was written against — "there is no
    /// HealthKit ECG read path and no JSON ingest route" — no longer holds:
    /// server v1.35.3 ships `POST /api/insights/ecg`, and this app now reads
    /// `HKElectrocardiogram` behind a device-local switch. So the empty branch
    /// gained a second, actionable reading (``uploadOffNote``). The archive
    /// path stays: it is still the only way in for a recording that never
    /// reached this iPhone's HealthKit at all.
    ///
    /// The hardware sentence is deliberately separate and deliberately quiet:
    /// "your device cannot record ECGs" is a different fact from "you have not
    /// uploaded one", it is not an error, and it is not an invitation to buy a
    /// watch.
    ///
    /// **No disclaimer block here on purpose** — the permanent non-dismissible
    /// notice ``EcgDisclaimerBlock`` speaks about a shown device verdict, and
    /// there is none. Nothing on this branch interprets, classifies or judges
    /// anything; it only says what is and is not in the record.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: HLSpace.lg) {
                HLEmptyState(
                    icon: "waveform.path.ecg",
                    title: "insights.ecg.empty.title",
                    message: "insights.ecg.empty.body"
                )

                uploadOffNote

                importPathCard

                Text("insights.ecg.empty.hardwareNote")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("insights.ecg.empty.hardwareNote")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.xxl)
            .padding(.bottom, HLSpace.xxxl)
        }
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("insights.ecg.empty")
    }

    /// **GH #74 — the second reason this surface can be empty, and the only one
    /// the user can do something about.**
    ///
    /// Since server v1.35.3 there IS a live path from Apple Health to the
    /// record, and it hangs on a switch that starts OFF. So an empty surface
    /// now has two honest readings — "nothing was ever uploaded" (the body
    /// above, still true) and "the upload is switched off" — and only the
    /// second one has an action behind it.
    ///
    /// **UI-Standard R2, category "Leerzustand": one line, and only when it is
    /// true.** Switch on → the line is absent; there is nothing to say, and a
    /// "the upload is on" reassurance would be exactly the kind of state
    /// narration R2 forbids. Switch off → one sentence naming the condition,
    /// plus the way to the switch rather than a sentence about where it is
    /// (R4). No server → absent as well: the switch itself is hidden there,
    /// and pointing at a control that does not exist would be a new dishonesty
    /// in the place built to remove one.
    @ViewBuilder
    private var uploadOffNote: some View {
        if backend?.hasServer != false, container?.ecgHealthSyncStore.enabled == false {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("insights.ecg.empty.uploadOff")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // UI-Standard R9: eine nachgeordnete Vollbreiten-Aktion ist
                // `.secondary`. Nicht `.primary` — der abschliessende Griff
                // dieser Fläche ist der Archiv-Import darunter, und zwei laute
                // Knöpfe übereinander sagen dem Nutzer nicht, welcher zuerst.
                HLButton(
                    String(localized: "insights.ecg.empty.uploadOffCta"),
                    icon: "heart.text.square",
                    variant: .secondary
                ) {
                    router?.requestAppleHealthSettings()
                }
                .accessibilityIdentifier("insights.ecg.empty.uploadOffCta")
            }
            .accessibilityIdentifier("insights.ecg.empty.uploadOff")
        }
    }

    /// The route that works today, spelled out and walkable.
    ///
    /// The CTA is dropped without a server (standalone): the archive import is a
    /// server endpoint, so naming a step that cannot run would recreate exactly
    /// the dishonesty this empty state exists to remove. The steps themselves
    /// stay — they are still true of where recordings come from.
    private var importPathCard: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text("insights.ecg.empty.pathTitle")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .accessibilityAddTraits(.isHeader)

                pathStep(number: 1, text: "insights.ecg.empty.pathStep1")
                pathStep(number: 2, text: "insights.ecg.empty.pathStep2")
                pathStep(number: 3, text: "insights.ecg.empty.pathStep3")

                if backend?.hasServer != false {
                    HLButton(
                        String(localized: "insights.ecg.empty.cta"),
                        icon: "tray.and.arrow.down.fill",
                        variant: .restrained
                    ) {
                        router?.requestAppleHealthImport()
                    }
                    .accessibilityIdentifier("insights.ecg.empty.importCta")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("insights.ecg.empty.path")
    }

    private func pathStep(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: "\(number).circle")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.tertiary)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

/// One list row: when it was recorded, the DEVICE's result, and the device's
/// average heart rate. Every value is rendered verbatim — nothing is recomputed.
struct EcgRecordingRow: View {
    let recording: EcgRecordingDTO
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(HLDateFormat.dateTime(recording.recordedAt))
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Text(EcgPresentation.resultLabel(for: recording.verdict))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                if recording.averageHeartRate != nil {
                    Text(EcgPresentation.bpmValue(recording.averageHeartRate))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            }
            Spacer(minLength: 0)
            if showsChevron {
                HLDisclosureChevron()
            }
        }
        .padding(.vertical, HLSpace.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Disclaimer

/// The permanent, non-dismissible ECG attribution block.
///
/// **Do NOT soften or make this dismissible.** It is the copy contract that
/// keeps the surface an awareness view of the DEVICE's own certified result
/// rather than a HealthLog reading of an ECG.
///
/// **UI-Standard R17 (U1) — was hier gekürzt wurde und was nicht.** Der Satz
/// trägt zwei Dinge: die ZUSCHREIBUNG („das Ergebnis stammt von deinem
/// Aufzeichnungsgerät; HealthLog liest oder interpretiert EKG-Aufzeichnungen
/// nicht") und, angehängt, den Pauschalteil „und stellt keine Diagnose". Die
/// Zuschreibung ist der Vertrag und bleibt wortgleich. Der Pauschalteil ist
/// gefallen — er lebt am Ack-Sheet und in Einstellungen → Über diese App, und
/// „HealthLog interpretiert nicht" ist ohnehin die konkretere und stärkere
/// Aussage. Der Block bleibt permanent und nicht abweisbar.
///
/// **Achtung, Repo-Grenze:** der Wortlaut war bis hierher wortgleich mit dem
/// Web-Katalog (`insights.ecg.disclaimer`). Bis das Web-Repo nachzieht, driften
/// die beiden Fassungen um genau diesen Nachsatz auseinander.
struct EcgDisclaimerBlock: View {
    var body: some View {
        HLCard(style: .ghost) {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "info.circle")
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                Text("insights.ecg.disclaimer")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("insights.ecg.disclaimer")
    }
}
