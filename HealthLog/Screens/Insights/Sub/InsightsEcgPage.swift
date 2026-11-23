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
/// container does). Header anatomy is the shared `HLTabHeader` so the top
/// region never jumps across the pager.
struct InsightsEcgPage: View {
    @Environment(EcgStore.self) private var store
    /// The empty state routes to Settings → Apple-Health-Import. Read
    /// OPTIONALLY: this page is pushed
    /// from several stacks (Insights pager, Dashboard pulse drill-down) and is
    /// constructed bare in tests and previews, where a non-optional read traps.
    @Environment(AppRouter.self) private var router: AppRouter?
    /// Container access for the device-local ECG upload switch. The
    /// `appContainer` environment key is already optional, so this page keeps
    /// building bare in tests and previews.
    @Environment(\.appContainer) private var container

    var body: some View {
        content
            .task {
                if store.list == nil { await store.load() }
            }
    }

    /// In the Insights pager the head is pinned above the strip.
    @Environment(\.insightsInPager) private var inPager

    /// The page's head: pinned above the strip in the pager, at the top
    /// of the content elsewhere.
    private var pageHeader: some View {
        HLTabHeader(
            "insights.ecg.title",
            titleIdentifier: "insights.page.header.title.ecg",
            actions: [.info(InsightsSpecialPageInfo.ecg(), identifier: "insights.ecg.info")]
        )
    }

    /// The page stands in every state, so the title does not jump when the
    /// recordings arrive.
    private var content: some View {
        HLPage {
            // Title and list. The attribution at the foot of the list says
            // what a sub-line would repeat. No coach here: the page shows a
            // device's result and must not invite a reading of the trace.
            if !inPager {
                pageHeader
            }
            HLStateContainer(phase) {
                HLSkeleton(.rect, height: 120, cornerRadius: HLRadius.card)
            } empty: {
                emptyState
            } content: {
                recordingsList

                if store.loadFailed {
                    Text("insights.ecg.loadError")
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        .hlPullToRefresh { await store.refresh() }
        // In the pager the head stands fixed at the top, over the strip.
        .insightsPageHead(enabled: inPager) { pageHeader }
    }

    /// Recordings, the first read, or nothing on record. The empty state
    /// stands in the free area like on every page of the pager.
    private var phase: HLLoadPhase {
        if store.hasRecordings { return .loaded }
        if store.list == nil, store.isLoading { return .loading }
        return .empty
    }

    private var recordingsList: some View {
        HLCard(layout: .rows) {
            ForEach(store.recordings, id: \.id) { recording in
                row(for: recording)
            }
            // Who produced these results, at the foot of the
            // list it attributes, with its references.
            EcgAttributionFooter()
                .padding(.vertical, HLSpace.sm)
        }
        .accessibilityIdentifier("insights.ecg.list")
    }

    /// One recording row. Tappable ONLY when a waveform exists — a `ts-`
    /// fallback event carries a verdict but no signal, so its row is a plain
    /// line rather than a push into an empty screen. A data row: the whole
    /// row opens, without a chevron.
    @ViewBuilder
    private func row(for recording: EcgRecordingDTO) -> some View {
        if EcgPresentation.isOpenable(recording) {
            EcgRecordingRow(recording: recording)
                .hlRowLink { EcgDetailScreen(recording: recording) }
                .accessibilityIdentifier("insights.ecg.row.\(recording.id)")
        } else {
            EcgRecordingRow(recording: recording)
                .accessibilityIdentifier("insights.ecg.row.\(recording.id)")
        }
    }

    /// Calm, **honest** empty state.
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
    ///
    /// One lockup, like every empty page: symbol, title, the honest sentence,
    /// then the ways in as buttons of one style, the first-hand reason (the
    /// switched-off upload) above the archive. The archive's three steps
    /// open on request under the buttons, quiet, without a card around them.
    private var emptyState: some View {
        HLEmptyState(
            icon: "waveform.path.ecg",
            title: "insights.ecg.empty.title",
            message: "insights.ecg.empty.body"
        ) {
            VStack(spacing: HLLayout.buttonGap) {
                uploadOffNote
                HLButton(
                    "insights.ecg.empty.cta",
                    systemImage: "tray.and.arrow.down.fill",
                    variant: .secondary
                ) {
                    router?.requestAppleHealthImport()
                }
                .accessibilityIdentifier("insights.ecg.empty.importCta")
                importSteps
            }
        }
        .accessibilityIdentifier("insights.ecg.empty")
    }

    /// **The second reason this surface can be empty, and the only one
    /// the user can do something about.**
    ///
    /// Since server v1.35.3 there IS a live path from Apple Health to the
    /// record, and it hangs on a switch that starts OFF. So an empty surface
    /// now has two honest readings — "nothing was ever uploaded" (the body
    /// above, still true) and "the upload is switched off" — and only the
    /// second one has an action behind it.
    ///
    /// **UI-Standard R2, category "Leerzustand": one line, and only when it is
    /// true.** Switch on → the line is absent. Switch off → one sentence
    /// naming the condition, plus the way to the switch (R4).
    @ViewBuilder
    private var uploadOffNote: some View {
        if container?.ecgHealthSyncStore.enabled == false {
            VStack(spacing: HLLayout.buttonGap) {
                Text("insights.ecg.empty.uploadOff")
                    .hlText(.factLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HLButton(
                    "insights.ecg.empty.uploadOffCta",
                    systemImage: "heart.text.square",
                    variant: .secondary
                ) {
                    router?.requestAppleHealthSettings()
                }
                .accessibilityIdentifier("insights.ecg.empty.uploadOffCta")
            }
            .accessibilityIdentifier("insights.ecg.empty.uploadOff")
        }
    }

    /// The archive route spelled out: three steps behind its title.
    private var importSteps: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                pathStep(number: 1, text: "insights.ecg.empty.pathStep1")
                pathStep(number: 2, text: "insights.ecg.empty.pathStep2")
                pathStep(number: 3, text: "insights.ecg.empty.pathStep3")
            }
            .padding(.top, HLSpace.sm)
        } label: {
            Text("insights.ecg.empty.pathTitle")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.secondary)
        }
        .tint(HLText.secondary)
        .padding(.top, HLSpace.xs)
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
                .hlText(.factLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

/// One list row: when it was recorded, the DEVICE's result under it, and the
/// device's average heart rate on the right. Every value is rendered verbatim
/// — nothing is recomputed.
struct EcgRecordingRow: View {
    let recording: EcgRecordingDTO

    var body: some View {
        HLRow(
            title: Text(verbatim: HLDateFormat.dateTime(recording.recordedAt)),
            detail: Text(verbatim: EcgPresentation.resultLabel(for: recording.verdict)),
            value: recording.averageHeartRate.map { Text(verbatim: EcgPresentation.bpmValue($0)) }
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Attribution

/// The permanent, non-dismissible ECG attribution, at the foot of the card
/// whose results it attributes (the list on the page, the result on the
/// detail), with the device makers' references beside it.
///
/// **Do NOT soften or make this dismissible.** It is the copy contract that
/// keeps the surface an awareness view of the DEVICE's own certified result
/// rather than a HealthLog reading of an ECG.
///
/// **UI-Standard R17 — was hier gekürzt wurde und was nicht.** Der Satz
/// trägt die ZUSCHREIBUNG („das Ergebnis stammt von deinem Aufzeichnungsgerät;
/// HealthLog liest oder interpretiert EKG-Aufzeichnungen nicht"); der
/// Pauschalteil „und stellt keine Diagnose" lebt am Ack-Sheet und in
/// Einstellungen → Über diese App.
///
/// Was a ghost card of its own with an `info.circle` that opened
/// nothing; now one footnote and one "Quellen" inside the card it belongs to.
///
/// **Achtung, Repo-Grenze:** der Wortlaut war bis hierher wortgleich mit dem
/// Web-Katalog (`insights.ecg.disclaimer`). Bis das Web-Repo nachzieht, driften
/// die beiden Fassungen um genau diesen Nachsatz auseinander.
struct EcgAttributionFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("insights.ecg.disclaimer")
                .hlText(.rowSubtitle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("insights.ecg.disclaimer")
            // 1.0.3 (App Review 1.4.1) — the device maker's own ECG /
            // irregular-rhythm documentation, beside the attribution.
            HLSourcesLink(topic: .ecgRhythm)
        }
    }
}
