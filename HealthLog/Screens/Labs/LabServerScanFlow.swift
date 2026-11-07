import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

/// #149 item 3 — the lab-report scan read by the server instead of on the
/// device, when the server can and the person chooses it.
///
/// **When it is offered.** Only when `GET /api/labs/ocr/capability` says the
/// server reads reports, the person has given the document AI consent the
/// document reads require (the same account-bound lease, see
/// ``LabsOCRRepository``), and the `labsOcr` capability is not switched off.
/// Otherwise the sheet stays exactly as before: on the device only.
///
/// **Nothing leaves without a choice.** The switch "Genauer lesen lassen"
/// starts off on every scan. Only while it is on does a photo (JPEG), a PDF
/// (unchanged) or, in `text` mode, the text recognised on the device go out.
///
/// **What comes back** lands in the same ``LabScanReviewList``: every row is
/// checked by the person, and the limits the read ran into stand above the
/// list. A read can be cancelled at any time; a read that ends without rows
/// says why in one sentence, never with a spinner that does not end.
@MainActor
@Observable
final class LabServerScanFlow {
    /// The server's answer, `nil` until it came (or when it could not say).
    private(set) var capability: LabsOCRCapability?
    /// The person's choice for this scan. Off until they switch it on.
    var isChosen = false
    /// A read is running; the sheet shows the cancel button.
    private(set) var isReading = false

    let repository: LabsOCRRepository
    private var task: Task<Void, Never>?

    init(repository: LabsOCRRepository) {
        self.repository = repository
    }

    /// Asks the server once whether it can read reports.
    func loadCapability() async {
        guard capability == nil else { return }
        capability = await repository.capability()
    }

    #if DEBUG
        /// UI-test seam (`-uitest-lab-ocr`): a fixed capability, no network.
        func useFixture(_ fixture: LabsOCRCapability) {
            capability = fixture
        }
    #endif

    /// Whether the server offers the read at all (the sheet adds consent and
    /// the AI capability on top).
    var serverCanRead: Bool {
        capability?.offersServerRead ?? false
    }

    /// Whether a PDF can be chosen: the image itself goes out, and the server
    /// reads PDFs.
    var acceptsPDF: Bool {
        capability?.mode == .vision && capability?.pdfSupported == true
    }

    /// `text` mode: only the text recognised on the device goes out.
    var sendsTextOnly: Bool {
        capability?.mode == .text
    }

    // MARK: - Reads

    /// Things that stop a read before anything was sent.
    enum LocalStop: Error {
        case noText
        case load
    }

    #if canImport(UIKit)
        /// Reads photographed pages. One page goes as a JPEG; several go as one
        /// PDF when the server reads PDFs, else one after the other.
        func read(images: [UIImage], into scan: LabScanStore) {
            guard let mode = capability?.mode else { return }
            let repository = repository
            let pdfSupported = capability?.pdfSupported ?? false
            start(scan: scan) {
                switch mode {
                case .text:
                    let lines = await scan.recognisedLines(in: images)
                    guard !lines.isEmpty else { throw LocalStop.noText }
                    return try await repository.extract(.text(lines.joined(separator: "\n")))
                case .vision:
                    let pages = try images.map(Self.jpeg)
                    guard let first = pages.first else { throw LocalStop.load }
                    if pages.count == 1 { return try await repository.extract(.jpeg(first)) }
                    if pdfSupported, let pdf = Self.pdf(from: pages), pdf.count <= LabsOCRRepository.maxUploadBytes {
                        return try await repository.extract(.pdf(pdf))
                    }
                    return try await Self.readOneByOne(pages) { try await repository.extract(.jpeg($0)) }
                }
            }
        }
    #endif

    /// Reads a PDF the person picked, unchanged.
    func read(pdf: Data, into scan: LabScanStore) {
        let repository = repository
        start(scan: scan) { try await repository.extract(.pdf(pdf)) }
    }

    /// Stops a running read and goes back to the source chooser.
    func cancel(scan: LabScanStore) {
        stop()
        scan.retake()
    }

    /// Stops a running read (the sheet closed).
    func stop() {
        task?.cancel()
        task = nil
        isReading = false
    }

    private func start(scan: LabScanStore, work: @escaping @MainActor () async throws -> LabsOCRExtractResult) {
        task?.cancel()
        scan.ocrRepository = repository
        scan.beginServerRead()
        isReading = true
        task = Task { [weak self] in
            defer { if !Task.isCancelled { self?.isReading = false } }
            do {
                let result = try await work()
                try Task.checkCancellation()
                scan.ingest(server: result)
            } catch {
                // Cancelled by the person: back at the chooser, nothing to say.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                scan.report(Self.failure(for: error))
            }
        }
    }

    nonisolated static func failure(for error: Error) -> LabScanStore.Failure {
        switch error as? LocalStop {
        case .noText: .noText
        case .load: .load
        case nil: .server(LabsOCRFailure(error))
        }
    }

    // MARK: - Several pages without PDF

    /// Reads pages one after the other and merges them into one result. A
    /// page that fails is named as not read; a refusal that would repeat on
    /// every page (budget, rate limit, consent, switched off, offline) ends the
    /// read and names the rest as not read too. Only when no page produced a
    /// row does the first failure end the read.
    nonisolated static func readOneByOne(
        _ pages: [Data],
        read: @Sendable (Data) async throws -> LabsOCRExtractResult
    ) async throws -> LabsOCRExtractResult {
        var parts: [(page: Int, result: LabsOCRExtractResult)] = []
        var unread: [Int] = []
        var firstError: Error?
        for (offset, page) in pages.enumerated() {
            let number = offset + 1
            do {
                let result = try await read(page)
                parts.append((number, result))
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                firstError = firstError ?? error
                unread.append(number)
                let stopsAll: [LabsOCRFailure] = [
                    .budgetExceeded, .rateLimited, .consentRequired, .unavailable, .offline, .backgroundEnded
                ]
                if stopsAll.contains(LabsOCRFailure(error)) {
                    unread.append(contentsOf: (number + 1) ..< (pages.count + 1))
                    break
                }
            }
        }
        if parts.allSatisfy(\.result.rows.isEmpty), let firstError { throw firstError }
        return merge(parts, unread: unread)
    }

    /// One result from the reads of single pages, with the page numbers of
    /// the whole report and the 400-row ceiling of one commit.
    nonisolated static func merge(
        _ parts: [(page: Int, result: LabsOCRExtractResult)],
        unread: [Int]
    ) -> LabsOCRExtractResult {
        var rows = parts.flatMap(\.result.rows)
        let cappedAway = parts.compactMap { $0.result.rowsCapped.map { $0.found - $0.kept } }.reduce(0, +)
        let found = rows.count + cappedAway
        rows = Array(rows.prefix(LabsOCRCommitRequest.maxRows))
        let truncated = parts.filter { $0.result.truncatedPages != nil }.map(\.page)
        let unreadPages = Set(unread + parts.filter { !$0.result.unreadPages.isEmpty }.map(\.page))
        return LabsOCRExtractResult(
            reportDate: parts.lazy.compactMap(\.result.reportDate).first,
            rows: rows,
            truncatedPages: truncated.isEmpty ? nil : truncated,
            unreadPages: unreadPages.sorted(),
            stoppedBy: parts.lazy.compactMap(\.result.stoppedBy).first,
            rowsCapped: found > rows.count ? .init(kept: rows.count, found: found) : nil
        )
    }

    // MARK: - Encoding

    #if canImport(UIKit)
        /// A page as JPEG (never HEIC), made smaller until it fits the
        /// server's ceiling.
        nonisolated static func jpeg(_ image: UIImage) throws -> Data {
            var current = image
            for _ in 0 ..< 5 {
                guard let data = current.jpegData(compressionQuality: 0.85) else { throw LocalStop.load }
                if data.count <= LabsOCRRepository.maxUploadBytes { return data }
                let size = CGSize(width: current.size.width * 0.7, height: current.size.height * 0.7)
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = 1
                current = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    current.draw(in: CGRect(origin: .zero, size: size))
                }
            }
            throw HLError.server(status: 413, code: "labs.ocr.fileTooLarge", message: "page too large")
        }

        /// Several JPEG pages as one PDF, a page each.
        nonisolated static func pdf(from pages: [Data]) -> Data? {
            let images = pages.compactMap(UIImage.init(data:))
            guard images.count == pages.count, let first = images.first else { return nil }
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
            return renderer.pdfData { context in
                for image in images {
                    let bounds = CGRect(origin: .zero, size: image.size)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    image.draw(in: bounds)
                }
            }
        }
    #endif
}
