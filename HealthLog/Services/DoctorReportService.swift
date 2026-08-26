import Foundation

/// Server-rendered doctor-report PDF download (siehe ADR-002).
///
/// **v0141 W-DATAPARITY (P3) — canonical route.** The legacy
/// `POST /api/doctor-report/pdf` route was removed server-side (the route file
/// calls it the "legacy doctor-report route"), so every server render 404'd and
/// the screen silently fell back to the poorer on-device renderer. The PDF is
/// now produced by the canonical flagship export route
/// `POST /api/export/health-record` with `format: "pdf"`
/// (`src/app/api/export/health-record/route.ts:206-230`, rendered via
/// `renderDoctorReportPdfBytes`) — the same route `ExportService` already uses
/// for the FHIR / ZIP formats. The on-device renderer stays a genuine fallback
/// for a network error (wired in `UnifiedSharingStore.produce(_:)`), not the
/// default path.
public actor DoctorReportService {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Render the doctor-report PDF server-side.
    ///
    /// - Parameter selection: the leaf inclusion list (CU-01/CU-11). **Required
    ///   by the server** since v1.32.39 — this call sent no `selection` at all
    ///   until CU-11 and therefore `422`d on every attempt, which is why the
    ///   screen silently fell through to the on-device renderer. There is no
    ///   default here on purpose: a scope has to be stated by whoever chose it.
    ///   An empty selection is legal and means *no health data*.
    /// - Parameter practiceName: CU-35 (2) — the optional practice the report is
    ///   addressed to. Omitted from the body entirely when `nil` (the schema is
    ///   `.strict()`, so a stray `null` would be a 422). Sending it is also what
    ///   makes the server remember it as `lastReportPracticeName` for the next
    ///   prefill.
    public func downloadPDF(
        days: Int,
        locale: String = "de",
        selection: ReportSelection,
        practiceName: String? = nil
    ) async throws -> Data {
        // Strict `exportSelectionSchema` body: `{ format: "pdf", selection,
        // range: { days }, locale }` + the optional `practiceName`. `range` and
        // `locale` are still accepted (both `.optional()` on the schema, both
        // listed in the OpenAPI under the same `additionalProperties: false`
        // object).
        let request = HealthRecordExportRequest(
            format: .pdf,
            selection: selection,
            range: HealthRecordExportRequest.Range(days: days),
            locale: locale,
            practiceName: practiceName
        )
        let body = try JSONEncoder.hlDefault.encode(request)
        let req: APIRequest<Data> = APIRequest(
            method: .post,
            path: "/api/export/health-record",
            body: body,
            extraHeaders: ["Accept": "application/pdf"]
        )
        do {
            let (data, response) = try await api.download(req)
            guard response.value(forHTTPHeaderField: "Content-Type")?.contains("application/pdf") == true else {
                throw HLError.server(status: response.statusCode, code: nil, message: "Erwartete application/pdf")
            }
            return data
        } catch {
            // Surfaces `422 export.selection.unknown_leaf` as the typed
            // contract-mismatch it is, so the panel can rebuild the selection
            // from a fresh capabilities read instead of showing a raw error.
            throw HealthRecordExportError.mapped(error)
        }
    }
}
