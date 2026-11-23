import SwiftUI
import UIKit

/// **Zeitleiste**: the record laid out like a chart at the foot of a hospital
/// bed. Conditions and medications with their dose changes on top, every
/// chosen value under them, one time axis for all of it, today marked. A tap
/// (or a press and drag, or the pointer) picks a moment and the card under
/// the board says what that week or month held.
///
/// Contents, rules and sources are the web's (`/timeline`, `GET
/// /api/timeline`); the form is the app's own. The page reads only with the
/// opt-in `timeline` module on; off, it explains itself and offers the switch.
struct TimelineScreen: View {
    @Environment(\.appContainer) private var appContainer
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    /// Set by the shell: a phone in compact width on iOS 27 opens this page across.
    @Environment(\.hlOpensAcross) private var opensAcross
    @State private var isSwitchingOn = false

    /// The store lives in the router's timeline session, so a fold that
    /// moves the page keeps its window and its chosen period.
    private var store: TimelineStore? {
        router.timeline.store
    }

    var body: some View {
        TimelinePage(store: store, moduleOn: moduleOn, isSwitchingOn: isSwitchingOn, switchOn: switchOn)
            .navigationTitle(Text("timeline.title"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: loadKey) {
                guard let store = resolvedStore() else { return }
                // While two fingers zoom, the window changes many times a
                // second; the read waits until the hand rests.
                if store.read != nil { try? await Task.sleep(for: .milliseconds(350)) }
                guard !Task.isCancelled else { return }
                await store.load(moduleOn: moduleOn)
            }
            .onChange(of: moduleOn, initial: true) { _, on in
                HLLog.ui.notice("Zeitleiste: Seite steht, Modul \(String(describing: on), privacy: .public)")
                // Only the person's own opening turns the phone, never a
                // screen mounted again because the window changed size.
                guard TimelineAcrossCover.opensAcross(moduleOn: on, compactPhone: opensAcross),
                      router.timeline.takeOpenRequest() else { return }
                // Presented on the next turn of the main actor, once the page
                // stands in its window: a cover from a page not yet shown is
                // dropped by UIKit, and with it the page under it. The session
                // allows the turn, puts the cover up and asks for the turn.
                let session = router.timeline
                session.turns = TimelineAcrossCover.sceneTurns
                Task { @MainActor in session.openAcross() }
            }
            // The X of the full screen leaves the page under it too.
            .onChange(of: router.timeline.closeRequests) { _, _ in dismiss() }
            .fullScreenCover(
                isPresented: Binding(
                    get: { router.timeline.showsAcross },
                    set: { router.timeline.coverPresentationChanged($0) }
                ),
                content: {
                    TimelineAcrossCover(
                        session: router.timeline,
                        store: store,
                        moduleOn: moduleOn,
                        isSwitchingOn: isSwitchingOn,
                        switchOn: switchOn
                    )
                }
            )
            .accessibilityIdentifier("timeline.screen")
    }

    /// The module map's `timeline` key; `nil` until the map has loaded. The
    /// page reads unless it is `false` (``TimelineStore/reads(moduleOn:)``),
    /// the server's own answer decides the rest.
    private var moduleOn: Bool? {
        appContainer?.moduleGate.modules?["timeline"]
    }

    private var loadKey: LoadKey {
        LoadKey(
            request: store?.request,
            values: store?.values ?? [],
            // Whether the page reads, not the raw answer: the map arriving
            // with `true` after the page read on `nil` asks for nothing new.
            reads: TimelineStore.reads(moduleOn: moduleOn),
            hasStore: store != nil,
            refresh: router.refreshRequestCount
        )
    }

    private struct LoadKey: Equatable {
        let request: TimelinePeriod.Request?
        let values: [String]
        let reads: Bool
        let hasStore: Bool
        let refresh: Int
    }

    private func resolvedStore() -> TimelineStore? {
        if let store { return store }
        guard let api = appContainer?.api else { return nil }
        let created = TimelineStore(repository: TimelineRepository(api: api))
        router.timeline.store = created
        return created
    }

    private func switchOn() async {
        guard let gate = appContainer?.moduleGate, let store = resolvedStore() else { return }
        isSwitchingOn = true
        await store.switchOn { await gate.setEnabled(wireKey: "timeline", enabled: true) }
        isSwitchingOn = false
    }
}

/// The timeline's page itself, the same in the stack and in the phone's
/// turned full screen: the board, the summary of the chosen period, the
/// settings menu and the floating period bar.
struct TimelinePage: View {
    let store: TimelineStore?
    let moduleOn: Bool?
    let isSwitchingOn: Bool
    let switchOn: () async -> Void
    /// In the turned full screen, held upright: say how to see the whole board.
    var showsRotateHint = false

    @Environment(\.unitPreferences) private var units
    /// The page's whole height, safe areas included: under 480 pt (a phone
    /// held across) the rows grow shorter, the subtitle goes and the period
    /// bar moves aside. Measured with the insets, so moving the bar between
    /// the bottom and the top bar never changes the answer it came from.
    @State private var height: CGFloat = 0
    /// Held across, the bar at the top steps aside after a rest.
    @State private var chrome = TimelineChromeState()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @Environment(\.dynamicTypeSize) private var typeSize

    private var density: TimelineDensity {
        TimelineDensity.forHeight(height)
    }

    private var autoHidesChrome: Bool {
        TimelineChromeState.autoHides(
            density: density,
            showsBoard: store.map(showsPeriodBar) ?? false,
            assistiveTechnology: voiceOver || switchControl,
            accessibilityTextSize: typeSize.isAccessibilitySize
        )
    }

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                TimelineDensity.pageHeight(
                    content: proxy.size.height, top: proxy.safeAreaInsets.top, bottom: proxy.safeAreaInsets.bottom
                )
            } action: { height = $0 }
            .hlPageActions(pageActions)
            // The board scrolls under the status bar, the tab bar and the
            // period bar: the system's soft edge at both ends.
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if let store, showsPeriodBar(store), density != .short {
                    HLFloatingPeriodControl(selection: periodBinding(store), accessibilityLabelText: "timeline.period.label")
                }
            }
            .toolbar {
                // Held across, the height is too short for a floating bar
                // over the board: the period stands in the bar at the top.
                // The same one control, in its own capsule, without the
                // bar's glass around it.
                if let store, showsPeriodBar(store), density == .short {
                    ToolbarItem(placement: .principal) {
                        HLFloatingPeriodControl(selection: periodBinding(store), accessibilityLabelText: "timeline.period.label")
                            .controlSize(.small)
                            // The top bar offers the principal item less than
                            // the segments need; this much keeps every label
                            // whole, "Alles" included.
                            .frame(minWidth: TimelinePeriodBarWidth.minimum(
                                labels: TimelinePeriod.allCases.map(\.label),
                                labelWidth: TimelinePeriodBarWidth.labelWidth
                            ))
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .timelineChrome($chrome, autoHides: autoHidesChrome, store: store)
    }

    private func periodBinding(_ store: TimelineStore) -> Binding<TimelinePeriod> {
        Binding(
            get: { store.period },
            set: { choice in withAnimation(.snappy) { store.choose(choice) } }
        )
    }

    // MARK: - States

    /// The shared page scaffold, edge to edge (the board wants the width).
    private var content: some View {
        HLPage(readable: false) {
            if let store {
                page(store)
            } else {
                TimelineSkeleton()
            }
        }
        // The last line and the legend scroll clear of the floating period
        // bar and the tab bar under it.
        .contentMargins(
            .bottom,
            density == .short ? TimelineMetrics.shortBottomClearance : TimelineMetrics.bottomClearance,
            for: .scrollContent
        )
    }

    @ViewBuilder
    private func page(_ store: TimelineStore) -> some View {
        switch store.phase {
        case .idle, .loading:
            TimelineSkeleton()
        case .moduleOff:
            TimelineModuleOffCard(isSwitching: isSwitchingOn) { await switchOn() }
        case .refused:
            HLEmptyState(icon: "lock", title: "timeline.refused.title", message: "timeline.refused.message")
        case .failed:
            HLEmptyState(icon: "exclamationmark.triangle", title: "timeline.failed.title") {
                HLButton("timeline.failed.retry", variant: .secondary) {
                    Task { await store.load(moduleOn: moduleOn) }
                }
            }
        case let .loaded(read):
            loaded(read, store: store)
        }
    }

    @ViewBuilder
    private func loaded(_ read: TimelineRead, store: TimelineStore) -> some View {
        let wording = wording(store)
        let content = TimelineBoardContent.make(
            read: read,
            window: store.window,
            today: store.today,
            chosenValues: store.values,
            hiddenLanes: store.hiddenLanes,
            wording: wording
        )
        if content.isEmpty, TimelineStore.isEmpty(read) {
            HLEmptyState(icon: "calendar.day.timeline.left", title: "timeline.empty.title", message: "timeline.empty.message") {
                if store.period != .all {
                    HLButton("timeline.empty.showAll", variant: .secondary) { store.choose(.all) }
                }
            }
        } else {
            TimelineBoardView(
                content: content, store: store, wording: wording, showsRotateHint: showsRotateHint, density: density
            )
            // The rows rebuild only when what they draw changes.
            .equatable()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timeline.board")
            .opacity(store.isRefreshing ? 0.7 : 1)
            .animation(.easeOut(duration: 0.2), value: store.isRefreshing)
            TimelineSummaryCard(store: store, read: read, wording: wording)
            TimelineLegend(
                hasThin: content.values.contains { $0.track.points.contains(where: \.isThin) },
                hasBridges: content.values.contains { !$0.track.bridges.isEmpty },
                hasRange: content.values.contains { $0.track.band != nil }
            )
        }
    }

    /// The settings menu of the page: which lines and lanes the board shows.
    private var pageActions: HLTabHeaderActions {
        guard let store, store.read != nil else { return .none }
        return [.settingsMenu(label: "timeline.choices.title", identifier: Self.choicesIdentifier(inCover: showsRotateHint)) {
            TimelineChoicesMenu(store: store, wording: wording(store))
        }]
    }

    /// The settings menu on the page and in the turned full screen are two
    /// buttons on screen at once (the page stays under the cover), so each
    /// has its own identifier.
    nonisolated static func choicesIdentifier(inCover: Bool) -> String {
        inCover ? "timeline.across.choices" : "timeline.choices"
    }

    private func wording(_ store: TimelineStore) -> TimelineWording {
        TimelineWording(read: store.read, units: units)
    }

    private func showsPeriodBar(_ store: TimelineStore) -> Bool {
        switch store.phase {
        case .loaded: true
        case .loading: store.read != nil
        default: false
        }
    }
}

/// The phone's turned full screen (iOS 27): upright there is too little room
/// for a chart of years, so the timeline opens across, with the full board
/// and its column of names, and turns back upright when it closes with the X.
/// This one screen asks for the turn, because its content needs the width
/// (`OrientationPolicy`); the iPad and the open Duo keep their page.
struct TimelineAcrossCover: View {
    let session: TimelineSession
    let store: TimelineStore?
    let moduleOn: Bool?
    let isSwitchingOn: Bool
    let switchOn: () async -> Void

    var body: some View {
        HLSheetScaffold(
            "timeline.title",
            size: .cover,
            closeIdentifier: "timeline.across.close",
            onClose: { session.closeAcross() },
            content: {
                TimelinePage(
                    store: store,
                    moduleOn: moduleOn,
                    isSwitchingOn: isSwitchingOn,
                    switchOn: switchOn,
                    showsRotateHint: true
                )
            }
        )
        // No turn in onAppear or onDisappear: SwiftUI may take the cover down
        // and put it up again, the session's open state holds the turn.
    }

    /// Whether the page opens across: the module not known to be off, and
    /// the shell says this is a phone in compact width on iOS 27.
    nonisolated static func opensAcross(moduleOn: Bool?, compactPhone: Bool) -> Bool {
        TimelineStore.reads(moduleOn: moduleOn) && compactPhone
    }

    /// The scene's policy as the session's turns (iOS 27; before, the plist
    /// keeps the phone upright and nothing turns).
    static var sceneTurns: TimelineTurns {
        guard #available(iOS 27.0, *) else { return .inert }
        return TimelineTurns(
            allow: { OrientationPolicy.allowLandscape($0) },
            // Asked at once; a refusal is asked once more when the scene
            // reads its mask (``OrientationPolicy/maskAnswered(_:)``).
            requestAcross: { OrientationPolicy.requestRotation(to: .landscape, retryWhenAllowed: true) },
            requestUpright: { OrientationPolicy.requestRotation(to: .portrait) }
        )
    }
}

/// The page while the opt-in module is off: what the timeline is and the
/// switch to turn it on, in place, as on the web's modules hub.
struct TimelineModuleOffCard: View {
    let isSwitching: Bool
    let switchOn: () async -> Void

    var body: some View {
        HLEmptyState(
            icon: "calendar.day.timeline.left",
            title: "timeline.moduleOff.title",
            message: "timeline.moduleOff.message"
        ) {
            HLButton("timeline.moduleOff.action", variant: .secondary, isLoading: isSwitching) {
                Task { await switchOn() }
            }
            .accessibilityIdentifier("timeline.moduleOff.action")
        }
    }
}

/// The page's first paint: the shape of a board, not a spinner.
struct TimelineSkeleton: View {
    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLSkeleton(width: 220, height: 14)
                ForEach(0 ..< 6, id: \.self) { _ in
                    HLSkeleton(height: 36)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("timeline.loading"))
    }
}

/// How to read the lines, in one quiet line: hollow points and dashes.
struct TimelineLegend: View {
    let hasThin: Bool
    let hasBridges: Bool
    var hasRange = false

    var body: some View {
        if hasThin || hasBridges || hasRange {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                if hasThin {
                    Label {
                        Text("timeline.legend.thin")
                    } icon: {
                        Circle().strokeBorder(HLText.secondary, lineWidth: 1.25).frame(width: 7, height: 7)
                    }
                }
                if hasRange {
                    Label {
                        Text("timeline.legend.rangeLine")
                    } icon: {
                        ZStack(alignment: .top) {
                            Rectangle()
                                .fill(HLText.secondary.opacity(0.12))
                            Rectangle()
                                .fill(HLText.secondary.opacity(0.5))
                                .frame(height: 0.5)
                        }
                        .frame(width: 14, height: 7)
                    }
                }
                if hasBridges {
                    Label {
                        Text("timeline.legend.bridge")
                    } icon: {
                        Rectangle()
                            .stroke(HLText.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .frame(width: 14, height: 0.5)
                    }
                }
            }
            .hlText(.footnote)
            .padding(.horizontal, HLSpace.xs)
        }
    }
}

/// The width the period bar needs in the top bar held across: six equal
/// segments, each as wide as the longest label with its side inset, plus the
/// capsule's own insets (``HLFloatingPeriodControl``'s paddings). Derived
/// from the labels, so every language keeps its words whole.
enum TimelinePeriodBarWidth {
    static func minimum(labels: [String], labelWidth: (String) -> CGFloat) -> CGFloat {
        let widest = labels.map(labelWidth).max() ?? 0
        let segment = (widest + 2 * HLSpace.xs).rounded(.up)
        return CGFloat(labels.count) * segment + 2 * HLSpace.xs + 2 * HLSpace.lg
    }

    /// A label's width in the chosen segment's type (subheadline, semibold)
    /// at the reader's text size.
    static func labelWidth(_ label: String) -> CGFloat {
        let size = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        return (label as NSString).size(withAttributes: [.font: font]).width
    }
}

extension EnvironmentValues {
    /// Whether a page that needs the width opens across in a full screen:
    /// a phone in compact width on iOS 27. Injected by the shell.
    @Entry var hlOpensAcross = false
}
