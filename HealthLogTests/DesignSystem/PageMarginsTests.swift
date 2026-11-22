@testable import HealthLog
import SwiftUI
import Testing

/// The side margins of every list and form: the page margin up to the
/// readable width, then as much as centres the rows at 720 pt.
@Suite("Page margins from the measured width")
struct PageMarginsTests {
    @Test(
        "the margin is the page margin or centres the readable width",
        arguments: zip(AdaptiveWidths.all, [16, 16, 16, 16, 16, 16, 57, 156, 206.5, 328] as [CGFloat])
    )
    func side(width: CGFloat, expected: CGFloat) {
        #expect(HLPageMargins.side(width: width) == expected)
    }

    @Test("the phone keeps its 16 pt, measured or not")
    func phoneUnchanged() {
        #expect(HLPageMargins.side(width: 440) == HLLayout.pageMargin)
        #expect(HLPageMargins.side(width: nil) == HLLayout.pageMargin)
        #expect(HLPageMargins.contentWidth(width: 440) == 408)
    }

    @Test("the content never grows over the readable width", arguments: AdaptiveWidths.all)
    func contentWidth(width: CGFloat) {
        let content = HLPageMargins.contentWidth(width: width)
        #expect(content <= HLLayout.readableWidth)
        #expect(content == min(width - 2 * HLLayout.pageMargin, HLLayout.readableWidth))
    }

    @Test("a readable page caps its content at the readable width, a page of tiles does not")
    func pageCap() {
        #expect(HLPage<EmptyView>.maximumContentWidth(readable: true) == HLLayout.readableWidth)
        #expect(HLPage<EmptyView>.maximumContentWidth(readable: false) == nil)
    }

    @Test("without a sidebar a list keeps the page margins", arguments: AdaptiveWidths.all)
    func listWithoutSidebar(width: CGFloat) {
        let insets = HLPageMargins.listInsets(width: width, scrollWidth: width)
        #expect(insets.leading == HLPageMargins.side(width: width))
        #expect(insets.trailing == HLPageMargins.side(width: width))
    }

    @Test("beside a sidebar the stretch under it comes on top of the leading margin")
    func listBesideSidebar() {
        // iPad mini landscape: the list is 853 pt wide, its scroll view 1133.
        let insets = HLPageMargins.listInsets(width: 853, scrollWidth: 1133)
        let side = HLPageMargins.side(width: 853)
        #expect(abs(insets.leading - (280 + side)) < 0.001)
        #expect(abs(insets.trailing - side) < 0.001)
        // Unmeasured: the page margin.
        #expect(HLPageMargins.listInsets(width: nil, scrollWidth: nil).leading == HLLayout.pageMargin)
    }
}

#if !SWIFT_PACKAGE && canImport(UIKit)
    import UIKit

    /// A real list with `hlPageMargins()` in a window: where its row stands.
    @MainActor
    @Suite("Page margins in a hosted list", .serialized)
    struct PageMarginsHostedTests {
        @Observable
        final class FrameBox {
            var frame: CGRect = .zero
        }

        @Test("the row stands in the centred readable column, the list scrolls full width", arguments: [1032, 1376] as [CGFloat])
        func rowStandsInTheColumn(width: CGFloat) async throws {
            let box = FrameBox()
            let view = List {
                Color.clear
                    .frame(height: 44)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.frame = $0 }
                    .listRowInsets(EdgeInsets())
            }
            .hlPageMargins()
            let host = UIHostingController(rootView: view)
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            for _ in 0 ..< 4 {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
            let column = (width - HLLayout.readableWidth) / 2
            #expect(abs(box.frame.minX - column) <= 1, "row at \(box.frame.minX), column at \(column)")
            #expect(abs(box.frame.maxX - (width - column)) <= 1, "row ends at \(box.frame.maxX)")
        }
    }
#endif
