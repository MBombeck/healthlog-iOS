import Foundation

// #149 item 3 / #151 (server v1.43.11, limits v1.46 and v1.47) — a lab
// report read by the server instead of on the device.
//
// `GET /api/labs/ocr/capability` decides whether the scan sheet offers the
// server read at all. `POST /api/labs/ocr/extract` queues the read (202, a run
// polled through `GET /api/ai-runs/{id}`, result `OcrExtractResponse`), and
// `POST /api/labs/ocr/commit` writes only the rows the person confirmed.
// Every field the review screen does not strictly need decodes tolerantly, so
// a forward-compatible field or an older server never fails the read.

/// `GET /api/labs/ocr/capability` (`data`).
struct LabsOCRCapability: Decodable, Sendable, Equatable {
    /// How the server reads a report.
    enum Mode: String, Sendable, Equatable {
        /// The image (or PDF) itself goes to the server.
        case vision
        /// Only the text recognised on the device goes to the server.
        case text
    }

    let available: Bool
    let mode: Mode?
    let pdfSupported: Bool

    init(available: Bool, mode: Mode?, pdfSupported: Bool) {
        self.available = available
        self.mode = mode
        self.pdfSupported = pdfSupported
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        let rawMode = try? c.decodeIfPresent(String.self, forKey: .mode)
        mode = rawMode.flatMap(Mode.init(rawValue:))
        pdfSupported = (try? c.decodeIfPresent(Bool.self, forKey: .pdfSupported)) ?? false
    }

    /// The server read is offered only when the server says it can read a
    /// report AND names a mode this build knows.
    var offersServerRead: Bool {
        available && mode != nil
    }

    private enum CodingKeys: String, CodingKey {
        case available, mode, pdfSupported
    }
}

/// The per-field confidence the reader reports (0 to 1).
struct LabsOCRConfidence: Decodable, Sendable, Equatable {
    let analyte: Double
    let value: Double
    let unit: Double
    let range: Double

    init(analyte: Double, value: Double, unit: Double, range: Double) {
        self.analyte = analyte
        self.value = value
        self.unit = unit
        self.range = range
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        analyte = (try? c.decodeIfPresent(Double.self, forKey: .analyte)) ?? 1
        value = (try? c.decodeIfPresent(Double.self, forKey: .value)) ?? 1
        unit = (try? c.decodeIfPresent(Double.self, forKey: .unit)) ?? 1
        range = (try? c.decodeIfPresent(Double.self, forKey: .range)) ?? 1
    }

    /// Below this a field is worth a second look on the review screen.
    static let reviewThreshold = 0.6

    var isWeak: Bool {
        min(analyte, value, unit, range) < Self.reviewThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case analyte, value, unit, range
    }
}

/// One proposed reading (`OcrExtractedRow`).
struct LabsOCRRow: Decodable, Sendable, Equatable {
    let analyte: String
    let value: Double?
    let valueText: String?
    let unit: String?
    let referenceLow: Double?
    let referenceHigh: Double?
    /// The reference window exactly as printed ("3,5 - 5,0", "negativ").
    let referenceText: String?
    let takenAt: String?
    let confidence: LabsOCRConfidence?
    /// v1.43 — the marker this row was matched to automatically.
    let biomarkerId: String?
    /// The unit the matched marker is tracked in.
    let markerUnit: String?
    /// A live reading this row repeats.
    let duplicateOf: String?

    init(
        analyte: String,
        value: Double? = nil,
        valueText: String? = nil,
        unit: String? = nil,
        referenceLow: Double? = nil,
        referenceHigh: Double? = nil,
        referenceText: String? = nil,
        takenAt: String? = nil,
        confidence: LabsOCRConfidence? = nil,
        biomarkerId: String? = nil,
        markerUnit: String? = nil,
        duplicateOf: String? = nil
    ) {
        self.analyte = analyte
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.referenceText = referenceText
        self.takenAt = takenAt
        self.confidence = confidence
        self.biomarkerId = biomarkerId
        self.markerUnit = markerUnit
        self.duplicateOf = duplicateOf
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        analyte = (try? c.decodeIfPresent(String.self, forKey: .analyte)) ?? ""
        value = try? c.decodeIfPresent(Double.self, forKey: .value)
        valueText = Self.text(c, .valueText)
        unit = Self.text(c, .unit)
        referenceLow = try? c.decodeIfPresent(Double.self, forKey: .referenceLow)
        referenceHigh = try? c.decodeIfPresent(Double.self, forKey: .referenceHigh)
        referenceText = Self.text(c, .referenceText)
        takenAt = Self.text(c, .takenAt)
        confidence = try? c.decodeIfPresent(LabsOCRConfidence.self, forKey: .confidence)
        biomarkerId = Self.text(c, .biomarkerId)
        markerUnit = Self.text(c, .markerUnit)
        duplicateOf = Self.text(c, .duplicateOf)
    }

    private static func text(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        guard let raw = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case analyte, value, valueText, unit, referenceLow, referenceHigh, referenceText
        case takenAt, confidence, biomarkerId, markerUnit, duplicateOf
    }
}

/// Why a scan stopped before its last read (`stoppedBy`).
enum LabsOCRStop: String, Sendable, Equatable {
    /// The day's reading budget ran out.
    case budget
    /// Reading was switched off for the record while the scan ran.
    case unavailable
    /// The check before a read failed, so the scan stopped.
    case error
}

/// The run result of a `LABS_OCR_EXTRACT` (`OcrExtractResponse`), with every
/// honest limit the server names.
struct LabsOCRExtractResult: Decodable, Sendable, Equatable {
    let reportDate: String?
    let rows: [LabsOCRRow]
    /// The pages whose read stopped at the reader's output limit; empty when
    /// the report went as one read. `nil` when nothing was cut.
    let truncatedPages: [Int]?
    /// Pages that produced nothing.
    let unreadPages: [Int]
    let stoppedBy: LabsOCRStop?
    /// The first `read` of `total` pages (a PDF longer than a scan reads).
    let pageCoverage: PageCoverage?
    /// The first `kept` of `found` readings (more than one scan carries).
    let rowsCapped: RowsCapped?

    struct PageCoverage: Decodable, Sendable, Equatable {
        let read: Int
        let total: Int
    }

    struct RowsCapped: Decodable, Sendable, Equatable {
        let kept: Int
        let found: Int
    }

    init(
        reportDate: String? = nil,
        rows: [LabsOCRRow],
        truncatedPages: [Int]? = nil,
        unreadPages: [Int] = [],
        stoppedBy: LabsOCRStop? = nil,
        pageCoverage: PageCoverage? = nil,
        rowsCapped: RowsCapped? = nil
    ) {
        self.reportDate = reportDate
        self.rows = rows
        self.truncatedPages = truncatedPages
        self.unreadPages = unreadPages
        self.stoppedBy = stoppedBy
        self.pageCoverage = pageCoverage
        self.rowsCapped = rowsCapped
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reportDate = try? c.decodeIfPresent(String.self, forKey: .reportDate)
        rows = ((try? c.decodeIfPresent([Tolerant<LabsOCRRow>].self, forKey: .rows)) ?? [])
            .compactMap(\.value)
            .filter { !$0.analyte.isEmpty }
        if let truncated = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .truncated) {
            truncatedPages = (try? truncated.decodeIfPresent([Int].self, forKey: .pages)) ?? []
        } else {
            truncatedPages = nil
        }
        unreadPages = (try? c.decodeIfPresent([Int].self, forKey: .unreadPages)) ?? []
        let rawStop = try? c.decodeIfPresent(String.self, forKey: .stoppedBy)
        stoppedBy = rawStop.flatMap(LabsOCRStop.init(rawValue:))
        pageCoverage = try? c.decodeIfPresent(PageCoverage.self, forKey: .pageCoverage)
        rowsCapped = try? c.decodeIfPresent(RowsCapped.self, forKey: .rowsCapped)
    }

    private enum CodingKeys: String, CodingKey {
        case reportDate, rows, truncated, pages, unreadPages, stoppedBy, pageCoverage, rowsCapped
    }
}

/// Decodes one element of an array without failing the whole array.
private struct Tolerant<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// `POST /api/labs/ocr/commit` body: the rows a person confirmed (1 to 400).
struct LabsOCRCommitRequest: Encodable, Sendable, Hashable {
    struct Row: Encodable, Sendable, Hashable {
        let analyte: String
        let value: Double?
        let valueText: String?
        let unit: String?
        let referenceLow: Double?
        let referenceHigh: Double?
        let referenceText: String?
        let takenAt: String
        let biomarkerId: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(analyte, forKey: .analyte)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(valueText, forKey: .valueText)
            try c.encodeIfPresent(unit, forKey: .unit)
            try c.encodeIfPresent(referenceLow, forKey: .referenceLow)
            try c.encodeIfPresent(referenceHigh, forKey: .referenceHigh)
            try c.encodeIfPresent(referenceText, forKey: .referenceText)
            try c.encode(takenAt, forKey: .takenAt)
            try c.encodeIfPresent(biomarkerId, forKey: .biomarkerId)
        }

        private enum CodingKeys: String, CodingKey {
            case analyte, value, valueText, unit, referenceLow, referenceHigh, referenceText, takenAt, biomarkerId
        }
    }

    /// The server's per-commit ceiling.
    static let maxRows = 400

    let rows: [Row]
}

/// `POST /api/labs/ocr/commit` (`data`): what was written and what was skipped.
struct LabsOCRCommitResult: Decodable, Sendable, Equatable {
    struct Skipped: Decodable, Sendable, Equatable {
        let analyte: String
        /// `duplicate`, `unit_mismatch`, `unknown_biomarker`, or a newer reason.
        let reason: String
    }

    let insertedCount: Int
    let skipped: [Skipped]

    init(insertedCount: Int, skipped: [Skipped]) {
        self.insertedCount = insertedCount
        self.skipped = skipped
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        insertedCount = ((try? c.decodeIfPresent([Tolerant<IgnoredObject>].self, forKey: .inserted)) ?? []).count
        skipped = ((try? c.decodeIfPresent([Tolerant<Skipped>].self, forKey: .skipped)) ?? []).compactMap(\.value)
    }

    private struct IgnoredObject: Decodable {}

    private enum CodingKeys: String, CodingKey {
        case inserted, skipped
    }
}
