import Foundation
import ImageIO
#if canImport(UIKit)
    import UIKit
#endif

/// SUPP-EDIT (1.5.0, #131 P3) — editing a supplement's composition
/// (server v1.43).
///
///   * `GET /api/nutrients/catalog`: the form's nutrients and their input
///     units. Behind the `nutrients` module. A server without the route
///     answers 404: no catalogue, no editing.
///   * `PUT /api/medications/{id}/ingredients`: replaces the composition
///     (0 to 40 lines, `source` `MANUAL` or `LABEL_AI`). Delegable at MANAGE.
///     Interactive with an idempotency key, never in the outbox.
///   * `POST /api/medications/{id}/ingredients/extract`: reads a label photo
///     into a proposal (202, polled through ``AIRunsRepository``). The
///     account's own session only; the photo always goes as JPEG (the server
///     refuses HEIC), at most 10 MB.
actor MedicationIngredientsRepository {
    /// The server's upload ceiling for a label photo.
    static let maxUploadBytes = 10 * 1024 * 1024
    /// The server's line ceiling for one composition.
    static let maxLines = 40

    enum Source: String, Encodable, Sendable {
        case manual = "MANUAL"
        case labelAI = "LABEL_AI"
    }

    struct Line: Encodable, Sendable, Equatable {
        let nutrient: String
        let amount: Double
        let unit: String
    }

    struct PutBody: Encodable, Sendable, Equatable {
        let ingredients: [Line]
        let source: Source
    }

    struct Stored: Decodable, Sendable, Equatable {
        let ingredients: MedicationIngredients
        /// The worker re-counts the day's micronutrients; the nutrient page
        /// shows the new total on its next read.
        let recomputeQueued: Bool

        private enum CodingKeys: String, CodingKey {
            case ingredients, recompute
        }

        private struct Recompute: Decodable {
            let queued: Bool?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ingredients = (try? c.decodeIfPresent(MedicationIngredients.self, forKey: .ingredients)) ?? MedicationIngredients([])
            recomputeQueued = (try? c.decodeIfPresent(Recompute.self, forKey: .recompute))?.queued ?? false
        }
    }

    private let api: APIClientProtocol
    private let runs: AIRunsRepository

    init(api: APIClientProtocol, runs: AIRunsRepository? = nil) {
        self.api = api
        self.runs = runs ?? AIRunsRepository(api: api)
    }

    // MARK: - Catalogue

    func catalog() async throws -> NutrientServerCatalog {
        try await api.send(APIRequest<NutrientServerCatalog>.get("/api/nutrients/catalog"))
    }

    // MARK: - Save

    func save(
        medicationID: String,
        body: PutBody,
        idempotencyKey: IdempotencyKey
    ) async throws -> Stored {
        let request: APIRequest<Stored> = try .put(
            Self.path(medicationID),
            body: body,
            idempotencyKey: idempotencyKey,
            maxRetries: 0
        )
        return try await api.send(request)
    }

    // MARK: - Label photo

    /// Uploads one JPEG and waits for the proposal. Throws the server's typed
    /// refusal (`HLError`), or `CancellationError` when the caller cancelled.
    func readLabel(
        medicationID: String,
        jpeg: Data,
        onStatus: @Sendable (DocumentAIRunStatus) async -> Void = { _ in }
    ) async throws -> SupplementLabelProposal {
        let request = try Self.extractRequest(medicationID: medicationID, jpeg: jpeg)
        let (data, response) = try await api.download(request)
        try Task.checkCancellation()
        if response.statusCode == 202 {
            let accepted: DocumentAIRunAccepted = try DocumentsRepository.decodeEnvelope(data)
            do {
                return try await runs.wait(
                    for: accepted.runId,
                    firstDelay: .milliseconds(accepted.pollAfterMs ?? 1000),
                    onStatus: onStatus
                )
            } catch HLError.rateLimited {
                // A run keeps the budget's code; any other 429 inside a run
                // is a limit, never the budget.
                throw SupplementLabelReadFailure.rateLimited
            }
        }
        return try DocumentsRepository.decodeEnvelope(data)
    }

    /// The multipart trigger. Refuses anything that is not a JPEG before a
    /// byte leaves the phone: the server would refuse HEIC anyway.
    nonisolated static func extractRequest(medicationID: String, jpeg: Data) throws -> APIRequest<Data> {
        guard isJPEG(jpeg) else {
            throw HLError.server(status: 422, code: SupplementLabelReadFailure.fileTypeCode, message: "not a JPEG")
        }
        guard jpeg.count <= maxUploadBytes else {
            throw HLError.server(status: 413, code: SupplementLabelReadFailure.fileTooLargeCode, message: "file too large")
        }
        let boundary = "HLSupplementLabel-\(UUID().uuidString)"
        let body = AvatarRepository.multipartBody(
            fieldName: "file",
            fileName: "label.jpg",
            mimeType: "image/jpeg",
            payload: jpeg,
            boundary: boundary
        )
        // One attempt: a label read is charged against an hourly limit.
        return APIRequest(
            method: .post,
            path: path(medicationID) + "/extract",
            body: body,
            extraHeaders: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
            maxRetries: 0
        )
    }

    nonisolated static func path(_ medicationID: String) -> String {
        let id = medicationID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? medicationID
        return "/api/medications/\(id)/ingredients"
    }

    // MARK: - Encoding seam

    nonisolated static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])
    }

    #if canImport(UIKit)
        /// Any image the photo library hands over (HEIC on an iPhone, PNG,
        /// JPEG) as a JPEG at quality 0.85, made smaller until it fits the
        /// server's ceiling. Never HEIC. The orientation is baked in.
        nonisolated static func labelJPEG(from data: Data, limit: Int = maxUploadBytes) throws -> Data {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { throw SupplementLabelReadFailure.unreadable }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
            var side = max(width, height, 1)
            for _ in 0 ..< 8 {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: side
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                      let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { throw SupplementLabelReadFailure.unreadable }
                if jpeg.count <= limit { return jpeg }
                side = max(1, Int(Double(side) * 0.7))
            }
            throw SupplementLabelReadFailure.fileTooLarge
        }

        /// A camera page as JPEG, through the same seam.
        nonisolated static func labelJPEG(from image: UIImage, limit: Int = maxUploadBytes) throws -> Data {
            guard let first = image.jpegData(compressionQuality: 0.85) else { throw SupplementLabelReadFailure.unreadable }
            if first.count <= limit { return first }
            return try labelJPEG(from: first, limit: limit)
        }
    #endif
}

/// Why a label read ended without a proposal; each has its own sentence.
enum SupplementLabelReadFailure: Error, Equatable {
    /// 422 `…extract.fileType`, or a picked file that is no image.
    case fileType
    /// 413 `…extract.fileTooLarge`, or a photo that cannot be made small enough.
    case fileTooLarge
    /// 429 `…extract.rateLimited`: six reads an hour.
    case rateLimited
    /// 429 `…extract.budgetExceeded`: the day's AI budget.
    case budgetExceeded
    /// A run that failed (`…extract.failed`) or anything not named here.
    case failed
    /// The capability, the module or the record refused (403, no provider).
    case unavailable
    /// The reader is busy (503) or the run did not end in time.
    case busy
    case offline
    /// The picked photo could not be read on the phone.
    case unreadable

    static let fileTypeCode = "medications.ingredients.extract.fileType"
    static let fileTooLargeCode = "medications.ingredients.extract.fileTooLarge"
    static let rateLimitedCode = "medications.ingredients.extract.rateLimited"
    static let budgetExceededCode = "medications.ingredients.extract.budgetExceeded"
    static let failedCode = "medications.ingredients.extract.failed"

    /// `nil` for a cancelled read (the person tapped Cancel or left the page).
    init?(_ error: Error) {
        if error is CancellationError { return nil }
        if let own = error as? SupplementLabelReadFailure {
            self = own
            return
        }
        switch error as? HLError {
        case .canceled: return nil
        case let .rateLimited(retryAfter):
            // The transport drops the code of a 429. The hourly limit carries
            // `Retry-After`; the day's budget does not.
            self = retryAfter == nil ? .budgetExceeded : .rateLimited
        case .offline, .network: self = .offline
        case .moduleDisabled, .aiUnavailable: self = .unavailable
        case let .server(status, code, _):
            self = code.flatMap { Self.byCode[$0] } ?? Self.byStatus[status] ?? .failed
        default: self = .failed
        }
    }

    private static let byCode: [String: SupplementLabelReadFailure] = [
        fileTypeCode: .fileType,
        fileTooLargeCode: .fileTooLarge,
        rateLimitedCode: .rateLimited,
        budgetExceededCode: .budgetExceeded,
        failedCode: .failed,
        "aiRuns.timedOut": .busy,
        "aiRuns.workerUnavailable": .busy,
        "aiRuns.readerBusy": .busy,
        "ai.provider.none": .unavailable
    ]

    private static let byStatus: [Int: SupplementLabelReadFailure] = [
        413: .fileTooLarge, 415: .fileType, 403: .unavailable, 503: .busy
    ]

    /// The sentence the form shows.
    var message: String {
        switch self {
        case .fileType: String(localized: "medications.composition.label.error.fileType")
        case .fileTooLarge: String(localized: "medications.composition.label.error.fileTooLarge")
        case .rateLimited: String(localized: "medications.composition.label.error.rateLimited")
        case .budgetExceeded: String(localized: "medications.composition.label.error.budgetExceeded")
        case .failed: String(localized: "medications.composition.label.error.failed")
        case .unavailable: String(localized: "medications.composition.label.error.unavailable")
        case .busy: String(localized: "medications.composition.label.error.busy")
        case .offline: String(localized: "medications.composition.label.error.offline")
        case .unreadable: String(localized: "medications.composition.label.error.unreadable")
        }
    }
}
