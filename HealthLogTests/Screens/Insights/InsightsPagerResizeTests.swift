// Hosts the real paged scroll view in the test scene; the SPM library build
// has no app scene.
#if !SWIFT_PACKAGE && canImport(UIKit)

    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// The paged scroll view of Insights in a real window: the page and its
    /// position report survive the window growing from the folded Duo's
    /// width to the open one and back, and the offset stays on a whole page.
    /// Beside a side safe area each page has the width left of it, and the
    /// next page does not show under it.
    @MainActor
    @Suite("Insights pager across a real width change", .serialized)
    struct InsightsPagerResizeTests {
        private let ordered: [InsightsTabSelection] = [
            .overview, .metric(.bloodPressure), .metric(.weight), .metric(.pulse), .special(.mood)
        ]

        @Test("466 to 669 and back: the selection, the position and the snap hold")
        func resizeKeepsThePage() async throws {
            let pages = InsightsPagerPage.pages(from: ordered)
            let pager = InsightsPagerModel()
            pager.pagerOrder = ordered
            let view = InsightsPagedScroll(
                pager: pager,
                pages: pages,
                liveOrderedSelections: ordered,
                activePage: nil
            ) { entry in
                Color.gray.frame(height: 300).accessibilityIdentifier("\(entry.scrollIdentity)")
            }
            let host = UIHostingController(rootView: view)
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 466, height: 678)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            try await Self.settle(host, milliseconds: 300)

            // Go to the weight page the way a pill tap does, without motion.
            pager.selection = .metric(.weight)
            pager.mirrorSelectionIntoScroll(.metric(.weight), pages: pages, reduceMotion: true)
            try await Self.settle(host, milliseconds: 400)
            #expect(pager.selection == .metric(.weight))
            #expect(pager.scrolledID == .metric(.weight))
            let scroll = try #require(Self.scrollView(in: host.view), "no scroll view in the pager")
            #expect(abs(scroll.contentOffset.x - 2 * scroll.bounds.width) <= 1)

            for width in [CGFloat(669), 466, 1032] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: 678)
                // Past the 600 ms backstop of the snap-back.
                try await Self.settle(host, milliseconds: 800)
                #expect(pager.selection == .metric(.weight), "at \(width) pt")
                #expect(pager.scrolledID == .metric(.weight), "at \(width) pt")
                #expect(pager.programmaticScrollTarget == nil, "at \(width) pt")
                #expect(abs(scroll.bounds.width - width) <= 1)
                #expect(
                    abs(scroll.contentOffset.x - 2 * scroll.bounds.width) <= 1,
                    "offset \(scroll.contentOffset.x) at \(width) pt"
                )
            }
        }

        @Test("an upright bar at the side: each page is the width beside it, and no neighbour shows under it")
        func sideSafeAreaHidesTheNeighbour() async throws {
            let pages = InsightsPagerPage.pages(from: ordered)
            let pager = InsightsPagerModel()
            pager.pagerOrder = ordered
            let view = InsightsPagedScroll(
                pager: pager,
                pages: pages,
                liveOrderedSelections: ordered,
                activePage: nil
            ) { _ in
                Color.red.frame(height: 300)
            }
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .white
            // The folded Duo: 466 pt, its bar and clock take the right 84 pt.
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84)
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 466, height: 678)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            try await Self.settle(host, milliseconds: 400)

            let scroll = try #require(Self.scrollView(in: host.view), "no scroll view in the pager")
            let pageWidth = scroll.contentSize.width / CGFloat(pages.count)
            let inset = host.view.safeAreaInsets.right
            #expect(abs(pageWidth - (466 - inset)) <= 1, "page \(pageWidth) pt beside a \(inset) pt inset")

            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let y = host.view.safeAreaInsets.top + 150
            #expect(Self.isRed(image, at: CGPoint(x: 200, y: y)), "the page itself shows")
            #expect(!Self.isRed(image, at: CGPoint(x: 466 - inset / 2, y: y)), "the next page shows under the bar")
        }

        /// Whether the pixel at `point` (in points) is clearly red.
        private static func isRed(_ image: UIImage, at point: CGPoint) -> Bool {
            guard let cgImage = image.cgImage else { return false }
            let scale = image.scale
            let x = Int(point.x * scale), y = Int(point.y * scale)
            guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return false }
            var pixel = [UInt8](repeating: 0, count: 4)
            guard let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
            return pixel[0] > 200 && pixel[1] < 80 && pixel[2] < 80
        }

        private static func settle(_ host: UIViewController, milliseconds: Int) async throws {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(milliseconds))
            host.view.layoutIfNeeded()
        }

        private static func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width {
                return scroll
            }
            for subview in view.subviews {
                if let found = scrollView(in: subview) { return found }
            }
            return nil
        }
    }

#endif
