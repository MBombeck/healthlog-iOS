import Foundation
@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// The phone's turned full screen: it opens only when the person opens the
/// timeline, never because a fold or a narrowed window mounted the page
/// again; the shell decides where it may open; UIKit's refusal handler is
/// safe on any thread.
@Suite("Timeline — opening across", .serialized)
@MainActor
struct TimelineAcrossTests {
    static let regular = ShellLayout(sizeClass: .regular, enabledSections: Set(SidebarDestination.allCases))
    static let compact = ShellLayout(sizeClass: .compact, enabledSections: Set(SidebarDestination.allCases))

    @Test("a deep link is the person's opening: answered once, then no more")
    func deepLinkOpensOnce() {
        let router = AppRouter()
        router.apply(.timeline, isAuthenticated: true)
        #expect(router.timeline.takeOpenRequest())
        #expect(!router.timeline.takeOpenRequest())
    }

    @Test("open as a sidebar tab, then the window turns compact: the page moves to More without turning across")
    func foldDoesNotOpenAcross() {
        let router = AppRouter()
        router.applyShellLayout(Self.regular)
        router.openSidebarDestination(.timeline)
        #expect(router.selectedTab == .section(.timeline))
        router.applyShellLayout(Self.compact)
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 1)
        // The page mounted again on More finds no opening to answer.
        #expect(!router.timeline.takeOpenRequest())
        #expect(!TimelineAcrossCover.opensAcross(moduleOn: true, compactPhone: false))
    }

    @Test("the store lives in the session: a remount keeps the window, a sign-out drops it")
    func storeSurvivesRemount() {
        let router = AppRouter()
        let store = TimelineStore { _, _, _, _ in
            TimelineRead(zoom: .all, range: TimelineRange(from: "", to: "", dataFrom: nil), lanes: [], bucket: .month, series: [])
        }
        router.timeline.store = store
        store.choose(.week)
        router.applyShellLayout(Self.regular)
        router.applyShellLayout(Self.compact)
        #expect(router.timeline.store === store)
        #expect(router.timeline.store?.period == .week)
        router.timeline.noteOpened()
        router.resetNavigationForSignOut()
        #expect(router.timeline.store == nil)
        #expect(!router.timeline.takeOpenRequest())
    }

    @Test("the full screen is the session's: a remounted page keeps it, its X closes it and the page under it")
    func coverStateLivesInSession() {
        let session = TimelineSession()
        session.openAcross()
        #expect(session.showsAcross)
        #expect(session.closeRequests == 0)
        session.closeAcross()
        #expect(!session.showsAcross)
        #expect(session.closeRequests == 1)
        session.openAcross()
        session.reset()
        #expect(!session.showsAcross)
    }

    @Test("the permission to turn lives as long as the full screen: a rebuilt cover keeps it, only the X takes it back")
    func permissionSurvivesRebuild() {
        let session = TimelineSession()
        let log = TurnLog()
        session.turns = log.turns
        session.openAcross()
        #expect(log.moves == ["allow", "across"])
        // SwiftUI takes the cover down and puts it up again: its binding
        // reports false, then true. Nothing turns, nothing is taken back.
        session.coverPresentationChanged(false)
        session.coverPresentationChanged(true)
        session.openAcross()
        #expect(session.showsAcross)
        #expect(log.moves == ["allow", "across"])
        // The X: upright first, then the permission taken back.
        session.closeAcross()
        #expect(log.moves == ["allow", "across", "upright", "disallow"])
        // A sign-out without the cover up turns nothing.
        session.reset()
        #expect(log.moves.count == 4)
    }

    @Test("a refused turn is asked again exactly once, as soon as the scene's mask allows it")
    func refusedTurnRetriedOnce() {
        var retry = OrientationRetry(pending: .landscape)
        // The mask still upright: the turn waits.
        #expect(retry.answered(.portrait) == nil)
        #expect(retry.pending == .landscape)
        // The permission stands again: asked once more.
        #expect(retry.answered(.allButUpsideDown) == .landscape)
        // And never a second time.
        #expect(retry.answered(.allButUpsideDown) == nil)
        #expect(retry.pending == nil)
    }

    @Test("the menu on the page and the one in the full screen have their own identifiers")
    func choicesIdentifiers() {
        #expect(TimelinePage.choicesIdentifier(inCover: false) == "timeline.choices")
        #expect(TimelinePage.choicesIdentifier(inCover: true) == "timeline.across.choices")
    }

    @Test("unless the module is known to be off, and only on the shell's word that this is a compact phone")
    func decision() {
        #expect(TimelineAcrossCover.opensAcross(moduleOn: true, compactPhone: true))
        // The map not loaded yet: the page reads, so it turns as well.
        #expect(TimelineAcrossCover.opensAcross(moduleOn: nil, compactPhone: true))
        #expect(!TimelineAcrossCover.opensAcross(moduleOn: false, compactPhone: true))
        #expect(!TimelineAcrossCover.opensAcross(moduleOn: true, compactPhone: false))
        #expect(EnvironmentValues().hlOpensAcross == false)
    }

    @Test("UIKit's refusal handler runs off the main thread without trapping")
    func errorHandlerOffMain() async {
        let ran = await Task.detached {
            let handler = OrientationPolicy.geometryErrorHandler(retry: true)
            handler(NSError(domain: "UISceneErrorDomain", code: 101))
            OrientationPolicy.geometryErrorHandler(retry: false)(NSError(domain: "UISceneErrorDomain", code: 101))
            return true
        }.value
        #expect(ran)
    }

    /// Keeps the crashing form from coming back: the turn request may not
    /// get a closure literal written in the main-actor policy.
    @Test("the turn request takes the handler from its factory, never a closure literal")
    func noClosureLiteralAtGeometryRequest() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthLog/App/HLSceneDelegate.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.range(of: #"requestGeometryUpdate\([^)]*\)\s*\{"#, options: .regularExpression) == nil)
        #expect(source.range(of: #"errorHandler:\s*\{"#, options: .regularExpression) == nil)
        #expect(source.contains("errorHandler: geometryErrorHandler("))
    }
}

/// Records the session's turns in order.
@MainActor
private final class TurnLog {
    var moves: [String] = []

    var turns: TimelineTurns {
        TimelineTurns(
            allow: { [weak self] in self?.moves.append($0 ? "allow" : "disallow") },
            requestAcross: { [weak self] in self?.moves.append("across") },
            requestUpright: { [weak self] in self?.moves.append("upright") }
        )
    }
}
