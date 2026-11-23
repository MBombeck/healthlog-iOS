import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// When the timeline's controls fade held across, and what brings them back.
@Suite("Timeline — controls step aside held across")
struct TimelineChromeTests {
    @Test("only a short window with a board hides, never with an assistive technology or at an accessibility text size")
    func autoHides() {
        func hides(
            _ density: TimelineDensity,
            board: Bool = true,
            assistive: Bool = false,
            axText: Bool = false
        ) -> Bool {
            TimelineChromeState.autoHides(
                density: density, showsBoard: board, assistiveTechnology: assistive, accessibilityTextSize: axText
            )
        }
        #expect(hides(.short))
        // Upright the bar stays: the board scrolls and the bar would flicker.
        #expect(!hides(.regular))
        // Loading, empty, failed or module off: the X and the way on stay.
        #expect(!hides(.short, board: false))
        #expect(!hides(.short, assistive: true))
        #expect(!hides(.short, axText: true))
    }

    @Test("after the rest the controls hide; any interaction brings them back and starts the rest again")
    func restAndInteraction() {
        var chrome = TimelineChromeState()
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(chrome.isHidden)
        let before = chrome.generation
        chrome.interact()
        #expect(!chrome.isHidden)
        #expect(chrome.generation == before + 1)
    }

    @Test("a rest that an interaction overtook hides nothing")
    func staleRest() {
        var chrome = TimelineChromeState()
        let started = chrome.generation
        chrome.interact()
        chrome.restEnded(generation: started, autoHides: true)
        #expect(!chrome.isHidden)
    }

    @Test("a page that does not hide never hides")
    func neverWithoutAutoHide() {
        var chrome = TimelineChromeState()
        chrome.restEnded(generation: chrome.generation, autoHides: false)
        #expect(!chrome.isHidden)
    }

    @Test(
        "a finger on the page, a running scroll or a touch on the bar keep the controls; the rest starts when it ends",
        arguments: [TimelineChromeState.Hold.touch, .scroll, .bar]
    )
    func holds(hold: TimelineChromeState.Hold) {
        var chrome = TimelineChromeState()
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        chrome.hold(hold)
        #expect(!chrome.isHidden, "the hold brings the controls back")
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(!chrome.isHidden, "nothing hides while it holds")
        let held = chrome.generation
        chrome.release(hold)
        #expect(chrome.generation == held + 1, "the release starts a new rest")
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(chrome.isHidden)
    }

    @Test("two holds at once: the controls stay until both end")
    func overlappingHolds() {
        var chrome = TimelineChromeState()
        chrome.hold(.touch)
        chrome.hold(.scroll)
        chrome.release(.touch)
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(!chrome.isHidden)
        chrome.release(.scroll)
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(chrome.isHidden)
    }

    @Test("releasing what does not hold restarts nothing")
    func releaseWithoutHold() {
        var chrome = TimelineChromeState()
        let generation = chrome.generation
        chrome.release(.bar)
        #expect(chrome.generation == generation)
    }

    @Test("the pointer brings hidden controls back at once, and restarts a running rest at most once a second")
    func pointer() {
        var chrome = TimelineChromeState()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let first = chrome.pointerMoved(at: start)
        let soon = chrome.pointerMoved(at: start.addingTimeInterval(0.4))
        let later = chrome.pointerMoved(at: start.addingTimeInterval(1.1))
        #expect(first)
        #expect(!soon, "a moving pointer does not rebuild the page every event")
        #expect(later)
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(chrome.isHidden)
        let whileHidden = chrome.pointerMoved(at: start.addingTimeInterval(1.2))
        #expect(whileHidden, "hidden, the first move shows them")
        #expect(!chrome.isHidden)
    }

    @Test("when the page stops hiding (turned upright, VoiceOver on) the controls come back")
    func stopsHiding() {
        var chrome = TimelineChromeState()
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        chrome.autoHidesChanged(false)
        #expect(!chrome.isHidden)
    }

    @Test("a touch on the bar (a menu, a period) keeps it until the next touch on the page; then the rest runs")
    func barTouch() {
        var chrome = TimelineChromeState()
        chrome.touchBegan(onPage: false)
        chrome.touchesEnded()
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(!chrome.isHidden, "an open menu hangs from the bar")
        chrome.touchBegan(onPage: true)
        chrome.touchesEnded()
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(chrome.isHidden)
    }

    @Test("a finger resting on the page holds the controls until it lifts")
    func fingerOnPage() {
        var chrome = TimelineChromeState()
        chrome.touchBegan(onPage: true)
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(!chrome.isHidden)
        chrome.touchesEnded()
        chrome.restEnded(generation: chrome.generation, autoHides: true)
        #expect(chrome.isHidden)
    }

    @Test("only the bar at the top is not the page; the side insets and the foot are, the board runs under them")
    func onPage() {
        // iPhone 17 Pro across: 874 x 402, the bar 44 pt at the top, 62 pt beside the island.
        let frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        let insets = EdgeInsets(top: 44, leading: 62, bottom: 21, trailing: 62)
        #expect(TimelineChromeState.isOnPage(CGPoint(x: 400, y: 200), frame: frame, safeArea: insets))
        #expect(!TimelineChromeState.isOnPage(CGPoint(x: 800, y: 22), frame: frame, safeArea: insets), "the menu button")
        #expect(TimelineChromeState.isOnPage(CGPoint(x: 26, y: 200), frame: frame, safeArea: insets), "the names beside the island")
        #expect(TimelineChromeState.isOnPage(CGPoint(x: 400, y: 395), frame: frame, safeArea: insets))
        // The bar hidden: its height belongs to the page.
        let hidden = EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
        #expect(TimelineChromeState.isOnPage(CGPoint(x: 400, y: 22), frame: frame, safeArea: hidden))
        // Not measured yet: every touch is the page, the bar never sticks.
        #expect(TimelineChromeState.isOnPage(CGPoint(x: 400, y: 22), frame: .zero, safeArea: EdgeInsets()))
    }

    @Test("the rest lasts three and a half seconds")
    func restDuration() {
        #expect(TimelineChromeState.restDuration == .seconds(3.5))
    }
}
