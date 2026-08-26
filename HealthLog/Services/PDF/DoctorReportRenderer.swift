import CoreGraphics
import Foundation
import PDFKit
#if canImport(UIKit)
    import UIKit
#endif

/// **Local Doctor Report — PDFKit renderer (T-7).**
///
/// Pure-actor PDF renderer. Consumes a `DoctorReportSpec` (Sendable), draws
/// each non-nil section onto a single multi-page `Data` blob, and writes
/// the blob to `FileManager.default.temporaryDirectory`. The caller (Store
/// or test) owns the file lifecycle — the actor never holds an `URL`.
///
/// **MainActor hop:** the renderer is an actor in its own isolation domain.
/// Section painting that depends on `@MainActor`-only APIs (currently
/// none — the cover/vitals/medications/mood paths only use `CGContext`
/// + `UIFont` which are thread-safe on iOS 13+) runs on the actor itself.
/// The Charts-via-`ImageRenderer` path lives in Commit 3 and will explicitly
/// hop to `@MainActor` before producing the chart bitmap.
///
/// **PDFKit metadata sanitization** (T-7 phase brief): only `Creator`
/// + `Author` are set, both to "HealthLog". No user PII in metadata —
/// patient name only appears in the visible cover page.
///
/// **Privacy** (T-7 phase brief): zero server round-trip, zero new
/// permission, file written under `.completeFileProtection`. Caller is
/// responsible for cleanup after ShareLink dismissal (mirrors the existing
/// `DoctorReportStore.persist(data:)` pattern from the server path).
public actor DoctorReportRenderer {
    public init() {}

    // MARK: - Public entrypoints

    /// Renders a spec into a multi-page PDF and writes the result to a
    /// freshly-named temp file. Returns the file URL.
    public func render(_ spec: DoctorReportSpec) async throws -> URL {
        let data = try await renderData(spec)
        return try persist(data: data)
    }

    /// Renders a spec into raw PDF data. Used by the renderer-roundtrip
    /// tests (Commit 5) so they can re-load the bytes through
    /// `PDFDocument(data:)` without going through the filesystem.
    ///
    /// **MainActor hop:** if the spec has a charts block, the chart
    /// images are pre-baked on the MainActor (Apple's `ImageRenderer`
    /// is MainActor-bound on iOS 16+) before any CGContext drawing
    /// starts. The bitmap pool is then consumed synchronously inside
    /// the `UIGraphicsPDFRenderer` callback.
    public func renderData(_ spec: DoctorReportSpec) async throws -> Data {
        let pageElements = paginate(spec: spec)
        let metadata: [CFString: Any] = [
            kCGPDFContextCreator: PDFMeta.creator,
            kCGPDFContextAuthor: PDFMeta.author,
            kCGPDFContextTitle: PDFMeta.title(for: spec.cover.locale)
        ]
        #if canImport(UIKit)
            // Pre-render chart bitmaps on @MainActor.
            let chartImages: [ChartImage] = if let chartsBlock = spec.charts {
                await MainActor.run {
                    DoctorReportChartRenderer.renderImages(chartsBlock)
                }
            } else {
                []
            }
            let format = UIGraphicsPDFRendererFormat()
            format.documentInfo = metadata.reduce(into: [String: Any]()) { acc, pair in
                acc[pair.key as String] = pair.value
            }
            let renderer = UIGraphicsPDFRenderer(bounds: PDFPage.usLetter, format: format)
            return renderer.pdfData { context in
                let cgContext = context.cgContext
                let drawer = SectionDrawer(spec: spec, chartImages: chartImages)
                for element in pageElements {
                    context.beginPage()
                    drawer.draw(element: element, into: cgContext, pageBounds: PDFPage.usLetter)
                }
            }
        #else
            throw HLError.unknown("PDF rendering requires UIKit")
        #endif
    }

    // MARK: - Pagination

    /// Walks the spec top-to-bottom and emits one `PageElement` per page.
    /// Sections that overflow a single page get split here (Commit 2 ships
    /// single-page cover + vitals; Commit 3 adds the multi-page charts /
    /// medications / mood paths).
    public func paginate(spec: DoctorReportSpec) -> [PageElement] {
        var elements: [PageElement] = []
        elements.append(.cover(spec.cover, footer: spec.footer))
        if let vitals = spec.vitals {
            elements.append(.vitals(vitals, footer: spec.footer))
        }
        if let charts = spec.charts {
            elements.append(.charts(charts, footer: spec.footer))
        }
        if let medications = spec.medications {
            elements.append(.medications(medications, footer: spec.footer))
        }
        if let adherence = spec.adherence {
            elements.append(.adherence(adherence, footer: spec.footer))
        }
        if let mood = spec.mood {
            elements.append(.mood(mood, footer: spec.footer))
        }
        return elements
    }

    // MARK: - File persistence

    private func persist(data: Data) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay]
        let ts = formatter.string(from: .now)
        // Append a UUID stub so successive renders within the same day
        // don't clobber an earlier file the ShareLink may still own.
        let stub = UUID().uuidString.prefix(8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("healthlog-doctor-report-\(ts)-\(stub).pdf")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

// MARK: - Page element enum

/// One enum case per page emitted by `DoctorReportRenderer.paginate`.
/// Sendable so the renderer (an actor) can carry these across isolation
/// boundaries safely.
public enum PageElement: Sendable {
    case cover(DoctorReportSpec.Cover, footer: DoctorReportSpec.Footer)
    case vitals(DoctorReportSpec.VitalsSummary, footer: DoctorReportSpec.Footer)
    case charts(DoctorReportSpec.ChartsBlock, footer: DoctorReportSpec.Footer)
    case medications(DoctorReportSpec.MedicationsBlock, footer: DoctorReportSpec.Footer)
    case adherence(DoctorReportSpec.AdherenceBlock, footer: DoctorReportSpec.Footer)
    case mood(DoctorReportSpec.MoodBlock, footer: DoctorReportSpec.Footer)
}

// MARK: - PDF page geometry

/// US-Letter at 72 dpi. Matches the default Apple PDF page size — every
/// modern medical practice prints to either Letter or A4, both fit in
/// the same content area at the 36 pt safe margin.
public enum PDFPage {
    public static let usLetter = CGRect(x: 0, y: 0, width: 612, height: 792)
    public static let margin: CGFloat = 36
    public static var contentWidth: CGFloat {
        usLetter.width - margin * 2
    }
}

// MARK: - PDF metadata

/// PDFKit metadata constants. Only Creator + Author + Title are set; no
/// user PII enters the metadata block.
public enum PDFMeta {
    public static let creator = "HealthLog"
    public static let author = "HealthLog"

    public static func title(for locale: ReportLocale) -> String {
        switch locale {
        case .de: "Arztbericht"
        case .en: "Doctor Report"
        }
    }
}
