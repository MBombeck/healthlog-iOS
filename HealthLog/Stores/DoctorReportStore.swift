import Foundation
import Observation

@MainActor
@Observable
public final class DoctorReportStore {
    public private(set) var pdfURL: URL?
    public private(set) var isWorking: Bool = false
    public private(set) var error: HLError?
    /// The raw error of the last attempt, kept alongside ``error`` so a typed
    /// non-`HLError` failure (today: ``HealthRecordExportError/unknownLeaf``)
    /// survives for the screen to branch on. `nil` after a success.
    public private(set) var failure: (any Error)?

    private let service: DoctorReportService
    private var previousURL: URL?

    public init(service: DoctorReportService) {
        self.service = service
    }

    /// - Parameter selection: the scope to render (CU-11). The server requires
    ///   it; there is no default, and an empty selection legally means *no
    ///   health data*. The last failure is kept in ``failure`` so the screen can
    ///   distinguish the `422 export.selection.unknown_leaf` contract mismatch
    ///   (rebuild the selection, retry) from a transport error (fall back to the
    ///   on-device renderer).
    /// - Parameter practiceName: CU-35 (2) — the optional practice the report is
    ///   addressed to, or `nil` when the field is blank. Never invented here:
    ///   an absent value means the user left the box empty, which is a valid
    ///   answer and not a reason to reach for the last-used one.
    public func generate(
        days: Int,
        locale: String,
        selection: ReportSelection,
        practiceName: String? = nil
    ) async {
        isWorking = true
        error = nil
        failure = nil
        defer { isWorking = false }
        do {
            let data = try await service.downloadPDF(
                days: days,
                locale: locale,
                selection: selection,
                practiceName: practiceName
            )
            // Vorheriges PDF aufräumen, damit der temporaryDirectory nicht wächst.
            if let prev = previousURL {
                try? FileManager.default.removeItem(at: prev)
            }
            let url = try persist(data: data)
            previousURL = url
            pdfURL = url
        } catch let err as HLError {
            error = err
            failure = err
        } catch {
            self.error = .unknown(String(describing: error))
            failure = error
        }
    }

    public func clearOnLogout() {
        if let url = pdfURL {
            try? FileManager.default.removeItem(at: url)
        }
        pdfURL = nil
        previousURL = nil
        error = nil
        failure = nil
    }

    private func persist(data: Data) throws -> URL {
        let ts = Date.now.formatted(.iso8601.year().month().day())
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("healthlog-report-\(ts).pdf")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
