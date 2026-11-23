@testable import HealthLog
import SwiftUI
import Testing

/// A list in a sheet keeps clear of the system column on the side where it
/// stands, read from the safe area; the Duo's outer screen put the column's
/// reserve on the left of the measure, medication and profile sheets.
@Suite("Page margins in a sheet")
struct SheetPageMarginTests {
    @Test("the covered edge in a sheet is the side with the larger safe area")
    func edgeFromSafeArea() {
        // A sheet inset 8 pt in the window: the position rule said "leading".
        #expect(HLPageMargins.hiddenEdge(listMinX: 8, layoutDirection: .leftToRight) == .leading)
        #expect(HLPageMargins.hiddenEdge(
            leadingSafeArea: 0, trailingSafeArea: 72, listMinX: 8, layoutDirection: .leftToRight
        ) == .trailing)
        #expect(HLPageMargins.hiddenEdge(
            leadingSafeArea: 72, trailingSafeArea: 0, listMinX: 8, layoutDirection: .leftToRight
        ) == .leading)
        // Equal insets: the position rule, as outside a sheet.
        #expect(HLPageMargins.hiddenEdge(
            leadingSafeArea: 0, trailingSafeArea: 0, listMinX: 0, layoutDirection: .leftToRight
        ) == .trailing)
    }

    @Test("the reserve lands on the covered side, the open side keeps the page margin")
    func insetsOnCoveredSide() {
        let edge = HLPageMargins.hiddenEdge(leadingSafeArea: 0, trailingSafeArea: 72, listMinX: 8, layoutDirection: .leftToRight)
        let insets = HLPageMargins.listInsets(width: 382, scrollWidth: 454, hiddenEdge: edge)
        #expect(insets.leading == HLLayout.pageMargin)
        #expect(insets.trailing == 72 + HLLayout.pageMargin)
    }
}
