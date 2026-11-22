@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    @Test("statistic rows: all cells side by side, two per row at the accessibility sizes")
    func statGridColumns() {
        #expect(HLStatGrid.columns(for: 4, at: .large) == 4)
        #expect(HLStatGrid.columns(for: 3, at: .xxxLarge) == 3)
        #expect(HLStatGrid.columns(for: 4, at: .accessibility2) == 2)
        #expect(HLStatGrid.columns(for: 1, at: .accessibility2) == 1)
        let cells = (1 ... 3).map { HLStatCell(label: "L\($0)", value: "\($0)") }
        #expect(HLStatGrid.rows(cells, columns: 2).map(\.count) == [2, 1])
        #expect(HLStatTile.labelLineLimit == 2)
    }

    @Test("a label that needs a second line keeps it, and its neighbours take the same height")
    func statGridEqualHeights() throws {
        let cells = [
            HLStatCell(label: "Mittlere Schwankung", value: "1", unit: "Tage"),
            HLStatCell(label: "Ø", value: "28", unit: "Tage"),
            HLStatCell(label: "Max", value: "31")
        ]
        let short = cells.map { HLStatCell(label: "Ø", value: $0.value, unit: $0.unit) }
        let grid = try DesignContractMeasure.size(of: HLStatGrid(cells: cells), width: 300)
        let plain = try DesignContractMeasure.size(of: HLStatGrid(cells: short), width: 300)
        #expect(grid.height > plain.height, "the long label wraps instead of shrinking away")

        let heights = try E2Pixels.surfaceRuns(
            in: HLStatGrid(cells: cells).environment(\.colorScheme, .light),
            width: 300,
            columns: [4, 107, 210],
            color: E2Pixels.RGB(red: 0xE9, green: 0xE6, blue: 0xE0)
        )
        #expect(Set(heights).count == 1, "cell heights \(heights)")
    }
}

/// Reads plain colours back from a rendered view, for blocks whose surface
/// is the thing under test.
@MainActor
enum E2Pixels {
    /// A plain colour, 0 to 255 per channel.
    struct RGB {
        let red: Int
        let green: Int
        let blue: Int
    }

    /// For each x, the number of rows whose pixel is `color` (±2 per channel).
    static func surfaceRuns(
        in view: some View,
        width: CGFloat,
        columns: [Int],
        color: RGB
    ) throws -> [Int] {
        let renderer = ImageRenderer(
            content: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
        )
        renderer.scale = 1
        let image = try #require(renderer.uiImage?.cgImage, "the view did not render")
        let columnsCount = image.width
        let rows = image.height
        var pixels = [UInt8](repeating: 0, count: columnsCount * rows * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: columnsCount,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: columnsCount * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: columnsCount, height: rows))
        return columns.map { column in
            (0 ..< rows).filter { row in
                let offset = (row * columnsCount + column) * 4
                return abs(Int(pixels[offset]) - color.red) <= 2
                    && abs(Int(pixels[offset + 1]) - color.green) <= 2
                    && abs(Int(pixels[offset + 2]) - color.blue) <= 2
                    && pixels[offset + 3] > 250
            }.count
        }
    }
}
