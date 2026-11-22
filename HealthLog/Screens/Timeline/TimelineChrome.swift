import GameController
import SwiftUI
import UIKit

/// When the timeline's controls step aside for the board, and when they come
/// back.
///
/// Held across (a window under 480 pt high, ``TimelineDensity/short``) every
/// control stands in the one bar at the top: the X, the period and the menu
/// of lines and lanes. After a few quiet seconds that bar fades away and the
/// board takes its height; a touch anywhere on the page, a scroll, a pinch,
/// the pointer or a key brings it back. Like the photo viewer, so nobody has
/// to be told.
///
/// Upright the bar stays: the board scrolls there and every scroll would
/// bring the bar back, it would flicker instead of giving room; and the
/// period floats at the foot over content that scrolls under it anyway.
///
/// Nothing hides while a finger rests on the page or the page scrolls, nor
/// ever when an assistive technology runs or the text is at an accessibility
/// size: the controls a person needs to reach stay put. A touch on the bar
/// itself (the menu of lines and lanes, a period) keeps the bar until the next
/// touch on the page: a menu that hangs from it stays open as long as it
/// likes, and SwiftUI tells nobody when a menu opens or closes.
struct TimelineChromeState: Equatable {
    /// What keeps the controls on screen while it lasts.
    enum Hold: Hashable {
        /// A finger on the page.
        case touch
        /// The page scrolling, by finger, trackpad or momentum.
        case scroll
        /// The last touch was on the bar, not on the page.
        case bar
    }

    /// How long the page rests before the controls fade.
    static let restDuration: Duration = .seconds(3.5)
    /// The pointer moving restarts the rest at most this often, so a moving
    /// mouse does not rebuild the page on every event.
    static let pointerRestartInterval: TimeInterval = 1

    private(set) var isHidden = false
    /// Counts every restart of the rest; a timer only hides for its own.
    private(set) var generation = 0
    private(set) var holds: Set<Hold> = []
    private var lastPointerRestart: Date = .distantPast

    /// Whether the controls hide at all on this page.
    nonisolated static func autoHides(
        density: TimelineDensity,
        showsBoard: Bool,
        assistiveTechnology: Bool,
        accessibilityTextSize: Bool
    ) -> Bool {
        density == .short && showsBoard && !assistiveTechnology && !accessibilityTextSize
    }

    /// Any interaction: the controls come back and the rest starts again.
    mutating func interact() {
        isHidden = false
        generation += 1
    }

    mutating func hold(_ hold: Hold) {
        holds.insert(hold)
        interact()
    }

    /// The hold ends; the rest starts from now.
    mutating func release(_ hold: Hold) {
        guard holds.remove(hold) != nil else { return }
        generation += 1
    }

    /// A finger came down at a point inside or outside the page.
    mutating func touchBegan(onPage: Bool) {
        if onPage {
            holds.remove(.bar)
            hold(.touch)
        } else {
            hold(.bar)
        }
    }

    mutating func touchesEnded() {
        release(.touch)
    }

    /// Whether a touch at `point` (window coordinates) is on the page and not
    /// on the bar: below the page's top safe area. The sides and the foot
    /// count as page: held across the board runs edge to edge under the side
    /// insets, and a tap on its names there is a tap on the page.
    nonisolated static func isOnPage(_ point: CGPoint, frame: CGRect, safeArea: EdgeInsets) -> Bool {
        point.y >= frame.minY + safeArea.top
    }

    /// The pointer moved over the page at `now`. Returns whether anything
    /// changed, so a caller can skip writing the state back.
    mutating func pointerMoved(at now: Date) -> Bool {
        guard isHidden || now.timeIntervalSince(lastPointerRestart) >= Self.pointerRestartInterval else { return false }
        lastPointerRestart = now
        interact()
        return true
    }

    /// The rest started for `generation` is over: hide, if nothing moved
    /// since, nothing holds the controls and the page hides at all.
    mutating func restEnded(generation ended: Int, autoHides: Bool) {
        guard autoHides, holds.isEmpty, ended == generation else { return }
        isHidden = true
    }

    /// The page stopped hiding (turned upright, VoiceOver came on): show.
    mutating func autoHidesChanged(_ autoHides: Bool) {
        if !autoHides { isHidden = false }
        generation += 1
    }
}

extension View {
    /// The timeline's controls in the top bar fade after a rest when
    /// `autoHides`; see ``TimelineChromeState``.
    func timelineChrome(_ chrome: Binding<TimelineChromeState>, autoHides: Bool, store: TimelineStore?) -> some View {
        modifier(TimelineChromeModifier(chrome: chrome, autoHides: autoHides, store: store))
    }
}

private struct TimelineChromeModifier: ViewModifier {
    @Binding var chrome: TimelineChromeState
    let autoHides: Bool
    let store: TimelineStore?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The page in window coordinates, with its safe areas.
    @State private var page = PageGeometry()

    private struct PageGeometry: Equatable {
        var frame: CGRect = .zero
        var safeArea = EdgeInsets()
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: PageGeometry.self) { proxy in
                PageGeometry(frame: proxy.frame(in: .global), safeArea: proxy.safeAreaInsets)
            } action: { page = $0 }
            .toolbarVisibility(chrome.isHidden ? .hidden : .automatic, for: .navigationBar)
            .persistentSystemOverlays(chrome.isHidden ? .hidden : .automatic)
            // Every touch in the window, the bar's included: a page gesture
            // never hears a tap on the bar.
            .background {
                TimelineWindowTouches { began, point in
                    if began {
                        let onPage = TimelineChromeState.isOnPage(point, frame: page.frame, safeArea: page.safeArea)
                        change { $0.touchBegan(onPage: onPage) }
                    } else {
                        change { $0.touchesEnded() }
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                change { phase == .idle ? $0.release(.scroll) : $0.hold(.scroll) }
            }
            .onContinuousHover { phase in
                guard autoHides, case .active = phase else { return }
                var next = chrome
                if next.pointerMoved(at: .now) { change { $0 = next } }
            }
            // A choice made by keyboard shortcut or from the menu, a pinch on
            // the trackpad: the page changed, the controls come back.
            .onChange(of: store?.period) { _, _ in change { $0.interact() } }
            .onChange(of: store?.window) { _, _ in change { $0.interact() } }
            .onChange(of: autoHides, initial: true) { _, on in change { $0.autoHidesChanged(on) } }
            .task(id: chrome.generation) {
                guard autoHides else { return }
                let generation = chrome.generation
                try? await Task.sleep(for: TimelineChromeState.restDuration)
                guard !Task.isCancelled else { return }
                change { $0.restEnded(generation: generation, autoHides: autoHides) }
            }
            .task(id: autoHides) {
                guard autoHides else { return }
                await TimelineKeyPresses.observe { change { $0.interact() } }
            }
    }

    /// Applies a step; a change of visibility glides, or with Reduce Motion
    /// switches in place without any movement.
    private func change(_ step: (inout TimelineChromeState) -> Void) {
        var next = chrome
        step(&next)
        guard next != chrome else { return }
        if next.isHidden != chrome.isHidden, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.35)) { chrome = next }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { chrome = next }
        }
    }
}

/// Every key pressed on a hardware keyboard while the page is on screen,
/// whatever has the focus.
@MainActor
enum TimelineKeyPresses {
    /// Calls `pressed` for each key press until the task is cancelled.
    static func observe(_ pressed: () -> Void) async {
        let (presses, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        install(continuation)
        // A keyboard connected while the page is open.
        let connections = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: .GCKeyboardDidConnect) {
                install(continuation)
            }
        }
        for await _ in presses {
            pressed()
        }
        connections.cancel()
        continuation.finish()
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
    }

    private static func install(_ continuation: AsyncStream<Void>.Continuation) {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { _, _, _, isPressed in
            if isPressed { continuation.yield() }
        }
    }
}

/// Reports every finger coming down anywhere in the window (with its point in
/// window coordinates) and the last one lifting, without taking part in any
/// gesture: the recognizer never recognizes, so the board's taps, drags and
/// pinches, the page's scroll and the bar's buttons run as before.
struct TimelineWindowTouches: UIViewRepresentable {
    let onTouch: (_ began: Bool, _ point: CGPoint) -> Void

    func makeUIView(context _: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.recognizer.onTouch = onTouch
        return view
    }

    func updateUIView(_ view: AnchorView, context _: Context) {
        view.recognizer.onTouch = onTouch
    }

    static func dismantleUIView(_ view: AnchorView, coordinator _: ()) {
        view.recognizer.view?.removeGestureRecognizer(view.recognizer)
    }

    /// Hangs the recognizer on the window it stands in.
    final class AnchorView: UIView {
        let recognizer = TimelineTouchRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }
}

/// See ``TimelineWindowTouches``.
final class TimelineTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: ((Bool, CGPoint) -> Void)?
    private var touching = Set<ObjectIdentifier>()

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        touching.formUnion(touches.map(ObjectIdentifier.init))
        for touch in touches {
            onTouch?(true, touch.location(in: nil))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        touching.subtract(touches.map(ObjectIdentifier.init))
        guard touching.isEmpty else { return }
        onTouch?(false, .zero)
        state = .failed
    }

    /// Whatever ended the sequence, the page hears that the fingers are gone.
    override func reset() {
        super.reset()
        if !touching.isEmpty {
            touching.removeAll()
            onTouch?(false, .zero)
        }
    }
}
