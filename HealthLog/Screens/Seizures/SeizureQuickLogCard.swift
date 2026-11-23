import SwiftUI

/// **The quick log** (server v1.48.0, web `quick-log-card.tsx`): one card for
/// a carer with a phone in one hand. The person's own seizure types as chips
/// (the last one used picked), one large start/stop button and the time since
/// the start. Once the time passes the type's threshold (server-resolved:
/// Trinka's t1, the usual duration plus two minutes, or five minutes) the
/// type's own plan appears with a call button for the emergency number;
/// before that the panel says nothing at all. "Rescue given" stamps the time
/// with the plan's drug and dose. Everything else is added afterwards in the
/// details sheet. The plan itself is set on the web.
struct SeizureQuickLogCard: View {
    let store: SeizuresStore
    var onAddDetails: (SeizureEventDTO) -> Void
    var onLogPast: () -> Void
    var onManageTypes: () -> Void

    @State private var isStopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            typeChips
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = store.timer?.elapsed(at: context.date) ?? 0
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    clock(elapsed: elapsed)
                    controls
                    if SeizurePresentation.isOverThreshold(
                        elapsed: elapsed,
                        alert: runningType?.alert,
                        isRunning: store.timer?.isRunning == true
                    ) {
                        SeizureThresholdPanel(type: runningType)
                    }
                }
            }
            if let error = store.lastError, store.timer != nil {
                HLFormErrorText(error)
            }
            recordedLine
            safetyLine
                .hlText(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("seizures.quick.safety")
            footerActions
        }
        .padding(.vertical, HLSpace.xs)
    }

    /// The safety advice, with the region's number when it is known.
    private var safetyLine: Text {
        if let number = SeizurePresentation.emergencyNumber() {
            return Text("seizures.safety.timer \(number)")
        }
        return Text("seizures.safety.timerLocal")
    }

    /// The type of the running timer, else the picked one.
    private var runningType: SeizureTypeDTO? {
        store.diary?.type(id: store.timer?.typeProfileId ?? store.pickedTypeId)
    }

    @ViewBuilder
    private var typeChips: some View {
        let types = store.types
        if types.isEmpty {
            HLLinkButton("seizures.types.newTitle", systemImage: "plus", alignment: .leading, action: onManageTypes)
                .accessibilityIdentifier("seizures.quick.addType")
        } else {
            HLFlowLayout {
                ForEach(types) { type in
                    HLChip(verbatim: type.displayName, isSelected: (store.timer?.typeProfileId ?? store.pickedTypeId) == type.id) {
                        store.pick(typeId: type.id)
                    }
                    .accessibilityIdentifier("seizures.quick.type")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("seizures.quick.typeGroup"))
        }
    }

    private func clock(elapsed: Int) -> some View {
        VStack(spacing: HLSpace.xxs) {
            Text(verbatim: SeizureDateFormat.clock(elapsed))
                .hlText(.heroValue)
                .contentTransition(.numericText())
                .accessibilityLabel(Text("seizures.quick.elapsedLabel"))
                .accessibilityValue(Text(verbatim: SeizureDateFormat.clock(elapsed)))
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("seizures.quick.elapsed")
            if let started = store.timer?.startedAt {
                Text("seizures.quick.startedAt \(HLTimeFormat.time(started))")
                    .hlText(.footnote)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var controls: some View {
        if store.timer == nil {
            HLButton("seizures.quick.start", systemImage: "play.fill") { store.startTimer() }
                .accessibilityIdentifier("seizures.quick.start")
        } else {
            VStack(spacing: HLSpace.sm) {
                // A stopped timer whose save failed keeps its end; the button
                // then only sends the same seizure again.
                if store.timer?.isRunning == false {
                    HLButton("seizures.quick.saveAgain", systemImage: "arrow.clockwise", isLoading: isStopping) {
                        Task { await stop() }
                    }
                    .accessibilityIdentifier("seizures.quick.stop")
                } else {
                    HLButton("seizures.quick.stop", systemImage: "stop.fill", isLoading: isStopping) {
                        Task { await stop() }
                    }
                    .accessibilityIdentifier("seizures.quick.stop")
                }
                if store.timer?.isRunning == true, let name = SeizurePresentation.rescueName(runningType) {
                    HLButton(rescueTitle(name: name), systemImage: SeizureSymbols.rescue, variant: .secondary) {
                        store.stampRescue()
                    }
                    .accessibilityIdentifier("seizures.quick.rescue")
                }
            }
        }
    }

    private func rescueTitle(name: String) -> Text {
        let count = store.timer?.rescue.count ?? 0
        return count == 0
            ? Text("seizures.quick.rescueGiven \(name)")
            : Text("seizures.quick.rescueGivenCount \(count)")
    }

    @ViewBuilder
    private var recordedLine: some View {
        if store.timer == nil, let recorded = store.lastRecorded {
            HLAdaptiveStack(spacing: HLSpace.sm) { stacked in
                Text("seizures.quick.recordedLine \(SeizurePresentation.duration(recorded.durationSec))")
                    .hlText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if !stacked { Spacer(minLength: HLSpace.sm) }
                HLButton("seizures.quick.addDetails", variant: .secondary) { onAddDetails(recorded) }
                    .fixedSize()
                    .accessibilityIdentifier("seizures.quick.addDetails")
            }
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        if store.timer == nil {
            HLLinkButton("seizures.quick.logPast", systemImage: "square.and.pencil", action: onLogPast)
                .accessibilityIdentifier("seizures.quick.logPast")
        } else {
            // Ends nothing stored: the running timer and its start time go.
            HLDeleteButton(
                "seizures.quick.discard",
                form: .page,
                action: .confirmed(
                    title: "seizures.quick.discardTitle",
                    message: "seizures.quick.discardConfirm",
                    word: "seizures.quick.discard",
                    symbol: "xmark.circle"
                ) {
                    store.discardTimer()
                }
            )
            .accessibilityIdentifier("seizures.quick.discard")
        }
    }

    private func stop() async {
        isStopping = true
        defer { isStopping = false }
        await store.stopTimer()
    }
}

/// The plan once the timer has passed the threshold: why it shows, the
/// type's own plan text (or that none is saved), the call button and where
/// the plan is edited. It never says it is safe to wait.
struct SeizureThresholdPanel: View {
    let type: SeizureTypeDTO?

    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        let number = SeizurePresentation.emergencyNumber()
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Label {
                Text(verbatim: SeizurePresentation.thresholdLine(type?.alert ?? .generic))
                    .hlText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HLColor.statusWarn)
            }
            .accessibilityFocused($focused)
            if let plan = type?.plan {
                Text(verbatim: plan)
                    .hlText(.prose)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("seizures.quick.plan")
            } else {
                Text("seizures.quick.noPlan")
                    .hlText(.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let number, let url = SeizurePresentation.callURL(number) {
                Link(destination: url) {
                    HLButtonLabel(Text("seizures.quick.call \(number)"), systemImage: "phone.fill", variant: .destructive)
                }
                .accessibilityIdentifier("seizures.quick.call")
            } else {
                Text("seizures.quick.callLocal")
                    .hlText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("seizures.quick.callLocal")
            }
            Text("seizures.plan.webHint")
                .hlText(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            HLSourcesLink(topic: .seizures)
        }
        .padding(HLSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HLSurface.tertiary, in: .rect(cornerRadius: HLRadius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("seizures.quick.threshold")
        .onAppear { focused = true }
    }
}
