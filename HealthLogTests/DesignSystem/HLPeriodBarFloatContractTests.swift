@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// The period bar floats free, as in 1.5: only the glass capsule stands over
/// the page, no band or backdrop beside it, and the page's content ends above
/// the capsule, so the bar covers nothing.
@MainActor
@Suite("Period bar floats free", .serialized)
struct HLPeriodBarFloatContractTests {
    /// The page height the bar is measured in.
    private static let pageHeight: CGFloat = 300

    @Test("a scrolling page gets the capsule's room as bottom inset, so the bar covers nothing")
    func scrollContentEndsAboveCapsule() async throws {
        let withBar = try await Self.bottomInset(showsBar: true)
        let withoutBar = try await Self.bottomInset(showsBar: false)
        // The capsule (a hit target high) and the room above it.
        #expect(
            withBar - withoutBar >= HLHitTarget.minimum + HLSpace.sm - 1,
            "the page's end stays under the capsule: \(withBar) pt with the bar, \(withoutBar) pt without"
        )
    }

    /// The bottom content inset of a real scroll view under the period bar,
    /// hosted in a window of the test scene.
    private static func bottomInset(showsBar: Bool) async throws -> CGFloat {
        let page = ScrollView {
            Color.gray.frame(height: 2000)
        }
        .hlPeriodBar(selection: .constant(HLTimeRange.standard), isShown: showsBar)
        let host = UIHostingController(rootView: page)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let scroll = try #require(Self.scrollView(in: host.view), "no scroll view on the page")
        return scroll.adjustedContentInset.bottom
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    @Test("beside the capsule the page shows through: no band under the bar")
    func noBandBesideCapsule() async throws {
        let page = ScrollView {
            Color.red.frame(height: 2000)
        }
        .hlPeriodBar(selection: .constant(HLTimeRange.standard))
        let host = UIHostingController(rootView: page)
        host.view.backgroundColor = .white
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        // Beside the capsule, at its height: the page's own content, not a
        // band laid over the bottom edge.
        let capsuleCenter = 874 - host.view.safeAreaInsets.bottom - HLSpace.sm - HLHitTarget.minimum / 2
        for x in [CGFloat(6), 396] {
            #expect(Self.isRed(image, at: CGPoint(x: x, y: capsuleCenter)), "a band covers the page at x \(x)")
        }
    }

    /// Whether the pixel at `point` (in points) is red: the page's content,
    /// perhaps softened at the edge, but not covered by an opaque band.
    private static func isRed(_ image: UIImage, at point: CGPoint) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return pixel[0] > 180 && pixel[1] < 160 && pixel[2] < 160
    }

    @Test("without periods the bar takes no room")
    func hiddenBarTakesNoRoom() throws {
        let page = DesignContractMeasure.marker
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .hlPeriodBar(selection: .constant(HLTimeRange.standard), isShown: false)
            .frame(height: Self.pageHeight)
        let (frame, _) = try DesignContractMeasure.markerFrame(in: page, width: 402)
        #expect(frame.maxY == Self.pageHeight)
    }

    @Test("a compact width publishes no Period menu, so a swipe changes no focused value")
    func compactPublishesNothing() {
        #expect(!HLPeriodCommandPublisher.publishes(
            isShown: true, isOnScreen: true, inPager: true, isActivePage: true, sizeClass: .compact
        ))
        #expect(!HLPeriodCommandPublisher.publishes(
            isShown: true, isOnScreen: true, inPager: false, isActivePage: false, sizeClass: .compact
        ))
        #expect(HLPeriodCommandPublisher.publishes(
            isShown: true, isOnScreen: true, inPager: true, isActivePage: true, sizeClass: .regular
        ))
    }

    @Test("the pager flag is off outside the pager")
    func pagerFlagDefault() {
        #expect(EnvironmentValues().insightsInPager == false)
    }
}
