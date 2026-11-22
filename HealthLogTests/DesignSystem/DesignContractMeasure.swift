@testable import HealthLog
import SwiftUI
import Testing

/// Lays a view out at a fixed width and text size and reports the size it
/// takes. A measurement, not a bitmap comparison: it holds across SDK
/// versions as long as the building block keeps its measures.
@MainActor
enum DesignContractMeasure {
    /// - Parameter width: the width the view is given, or `nil` for the width
    ///   it takes on its own.
    static func size(
        of view: some View,
        width: CGFloat? = 320,
        typeSize: DynamicTypeSize = .large,
        language: String = "en"
    ) throws -> CGSize {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .fixedSize(horizontal: width == nil, vertical: true)
                .dynamicTypeSize(typeSize)
                .environment(\.locale, Locale(identifier: language))
        )
        renderer.scale = 1
        return try #require(renderer.uiImage, "the view did not render").size
    }

    /// A flat block in a colour no building block draws, to find a place in a
    /// rendered view again.
    static var marker: Color {
        Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1)
    }

    /// Where ``marker`` stands in the rendered view, in points from the view's
    /// upper left corner, and the size of the view around it.
    static func markerFrame(
        in view: some View,
        width: CGFloat = 320,
        typeSize: DynamicTypeSize = .large
    ) throws -> (frame: CGRect, size: CGSize) {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(typeSize)
                .environment(\.locale, Locale(identifier: "en"))
        )
        renderer.scale = 1
        let image = try #require(renderer.uiImage?.cgImage, "the view did not render")
        let columns = image.width
        let rows = image.height
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: columns,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: columns * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))

        var minX = columns, minY = rows, maxX = -1, maxY = -1
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let offset = (row * columns + column) * 4
                guard pixels[offset] > 200, pixels[offset + 1] < 60, pixels[offset + 2] > 200 else { continue }
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        try #require(maxX >= 0, "the marker is not in the picture")
        let frame = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (frame, CGSize(width: columns, height: rows))
    }
}
