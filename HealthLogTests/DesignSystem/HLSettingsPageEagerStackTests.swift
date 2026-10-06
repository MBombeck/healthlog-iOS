@testable import HealthLog
import SwiftUI
import Testing

/// G1 — the Settings page scaffold stacks its cards eagerly.
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
    @Test("the page body stacks its cards in a VStack, never a LazyVStack")
    func pageBodyIsEager() {
        let page = HLSettingsPage(title: "Account") {
            HLSettingsCard(icon: "person.fill", title: "Profile") {
                Text("Body")
            }
        }
        let bodyType = String(reflecting: type(of: page.body))
        #expect(!bodyType.contains("LazyVStack"), "HLSettingsPage is lazy again: \(bodyType)")
        #expect(bodyType.contains("VStack"), "HLSettingsPage lost its card stack: \(bodyType)")
    }
}
