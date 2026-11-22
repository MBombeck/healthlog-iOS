@testable import HealthLog
import SwiftUI
import Testing

/// The Settings page scaffold stacks its cards eagerly.
///
/// With a lazy stack, the Share screen froze the app (main thread at 100 %
/// inside `LazySubviewPlacements.placeSubviews` → `LazyStack.place`) when it
/// left the screen — Back, or any tab switch — while a card's top edge sat a
/// few points below the visible bottom edge. The viewport change on leaving
/// made that card cross the edge, and the stack never settled on whether to
/// realize it. `InsightsAfterShareScrollHangUITest` is the behavioural proof;
/// this suite pins the structural decision so a later "perf" change cannot
/// quietly bring the lazy stack back to a scaffold that holds a handful of
/// cards and gains nothing from laziness.
@Suite("HLSettingsPage eager stack (G1)")
@MainActor
struct HLSettingsPageEagerStackTests {
    @Test("the settings page stands on the shared page frame")
    func settingsPageUsesSharedFrame() {
        let page = HLSettingsPage(title: "Account") {
            HLCard("Profile") {
                Text("Body")
            }
        }
        let bodyType = String(reflecting: type(of: page.body))
        #expect(bodyType.contains("HLPage"), "HLSettingsPage left the shared page frame: \(bodyType)")
    }

    @Test("the page frame stacks its cards in a VStack, never a LazyVStack")
    func pageBodyIsEager() {
        let page = HLPage {
            HLCard("Profile") {
                Text("Body")
            }
        }
        let bodyType = String(reflecting: type(of: page.body))
        #expect(!bodyType.contains("LazyVStack"), "HLPage is lazy again: \(bodyType)")
        #expect(bodyType.contains("VStack"), "HLPage lost its card stack: \(bodyType)")
    }
}
