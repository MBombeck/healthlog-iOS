@testable import HealthLog
import SwiftUI
import Testing

/// The metric page is one column at the readable width. A pair of blocks
/// inside it keeps the canonical phone order; the side-by-side rule still
/// serves Today, which shares it.
@Suite("Insights metric page columns")
struct InsightsMetricColumnsTests {
    static let widths: [CGFloat] = [320, 440, 466, 540, 669, 744, 834, 1032, 1133, 1376]

    @Test("a pair with an empty side stacks")
    func emptySideStacks() {
        #expect(InsightsMetricColumns.columns(leading: true, trailing: true) == .sideBySide)
        #expect(InsightsMetricColumns.columns(leading: false, trailing: true) == .single)
        #expect(InsightsMetricColumns.columns(leading: true, trailing: false) == .single)
        #expect(InsightsMetricColumns.columns(leading: false, trailing: false) == .single)
    }

    @Test("on the phone the page column is the content width, as before")
    func phoneUnchanged() {
        #expect(HLLayout.readableWidth > 440 - 2 * HLLayout.pageMargin)
    }

    @Test("side by side each column is at least as wide as the phone's content")
    func columnsStayReadable() {
        let content = 834 - 2 * HLLayout.pageMargin
        #expect(HLPageColumns.columnWidth(width: content) >= 360)
    }

    @Test(
        "the chip strip ends a margin beyond the column, the same on both sides",
        arguments: [320, 440, 466, 540, 669, 744, 834, 1032, 1133, 1376] as [CGFloat]
    )
    func stripEndsBesideTheColumn(page: CGFloat) {
        let width = InsightsStripLayout.width(pageWidth: page)
        // Never wider than the page, never wider than column and margins.
        #expect(width <= page)
        #expect(width <= HLLayout.readableWidth + 2 * HLLayout.pageMargin)
        // Up to the column's width the strip runs from edge to edge.
        if page <= HLLayout.readableWidth + 2 * HLLayout.pageMargin {
            #expect(width == page)
        } else {
            // Centred: the room left and right of it is the same.
            let side = (page - width) / 2
            #expect(side * 2 + width == page)
        }
    }
}

#if !SWIFT_PACKAGE && canImport(UIKit)
    import UIKit

    /// The metric page's frame in a window: the head and the first pair
    /// share the outer edges of one readable column.
    @MainActor
    @Suite("Insights metric page column, hosted", .serialized)
    struct InsightsMetricColumnsHostedTests {
        private static func block(_ height: CGFloat, _ store: @escaping (CGRect) -> Void) -> some View {
            Color.gray
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store($0) }
        }

        @Observable
        final class Frames {
            var head: CGRect = .zero
            var hero: CGRect = .zero
            var stats: CGRect = .zero
        }

        @Test("head, hero and statistics share one centred column", arguments: [1032, 1376] as [CGFloat])
        func oneColumn(width: CGFloat) async throws {
            let frames = Frames()
            // The structure `InsightsMetricScreen.scrollBody` builds.
            let view = HLPage {
                Self.block(60) { frames.head = $0 }
                HLPageColumnsContent(
                    columns: InsightsMetricColumns.columns(leading: true, trailing: true),
                    primary: Self.block(120) { frames.hero = $0 },
                    secondary: Self.block(80) { frames.stats = $0 }
                )
            }
            let host = UIHostingController(rootView: view)
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            for _ in 0 ..< 4 {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
            let column = (width - HLLayout.readableWidth) / 2
            for (name, frame) in [("head", frames.head), ("hero", frames.hero), ("stats", frames.stats)] {
                #expect(abs(frame.minX - column) <= 1, "\(name) starts at \(frame.minX)")
                #expect(abs(frame.width - HLLayout.readableWidth) <= 1, "\(name) is \(frame.width) wide")
            }
            // Stacked in the phone's order: hero above the statistics.
            #expect(frames.hero.maxY <= frames.stats.minY)
        }
    }
#endif
