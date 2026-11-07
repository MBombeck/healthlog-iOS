import Foundation

/// #151 — one calm line over the review list for every limit a server read
/// ran into. Each names what happened in plain words; none blocks saving.
enum LabsOCRLimitLine: Sendable, Equatable, Hashable {
    /// The reader stopped at its output limit; `pages` names the pages it cut
    /// (empty when the report went as one read).
    case truncated(pages: [Int])
    /// Parts of the report produced nothing.
    case unreadPages([Int])
    /// The scan stopped before its last read.
    case stopped(LabsOCRStop)
    /// A long PDF: only the first `read` of `total` pages were read.
    case pageCoverage(read: Int, total: Int)
    /// More readings than one scan carries: the first `kept` of `found`.
    case rowsCapped(kept: Int, found: Int)

    /// The lines for one result, in reading order: what was not read first,
    /// then why, then what was left out of the list.
    static func lines(for result: LabsOCRExtractResult) -> [LabsOCRLimitLine] {
        var lines: [LabsOCRLimitLine] = []
        if let coverage = result.pageCoverage, coverage.read < coverage.total {
            lines.append(.pageCoverage(read: coverage.read, total: coverage.total))
        }
        if let pages = result.truncatedPages {
            lines.append(.truncated(pages: pages))
        }
        if !result.unreadPages.isEmpty {
            lines.append(.unreadPages(result.unreadPages))
        }
        if let stop = result.stoppedBy {
            lines.append(.stopped(stop))
        }
        if let capped = result.rowsCapped, capped.kept < capped.found {
            lines.append(.rowsCapped(kept: capped.kept, found: capped.found))
        }
        return lines
    }

    /// The already-localized sentence.
    var message: String {
        switch self {
        case let .truncated(pages):
            switch pages.count {
            case 0: String(localized: "labs.ocr.limit.truncated")
            case 1: String(localized: "labs.ocr.limit.truncatedPage.\(Self.list(pages))")
            default: String(localized: "labs.ocr.limit.truncatedPages.\(Self.list(pages))")
            }
        case let .unreadPages(pages) where pages.count == 1:
            String(localized: "labs.ocr.limit.unreadPage.\(Self.list(pages))")
        case let .unreadPages(pages):
            String(localized: "labs.ocr.limit.unreadPages.\(Self.list(pages))")
        case .stopped(.budget):
            String(localized: "labs.ocr.limit.stoppedBudget")
        case .stopped(.unavailable):
            String(localized: "labs.ocr.limit.stoppedUnavailable")
        case .stopped(.error):
            String(localized: "labs.ocr.limit.stoppedError")
        case let .pageCoverage(read, total):
            String(localized: "labs.ocr.limit.pageCoverage.\(read).\(total)")
        case let .rowsCapped(kept, found):
            String(localized: "labs.ocr.limit.rowsCapped.\(found).\(kept)")
        }
    }

    /// "2, 3 und 5" / "2, 3 and 5", in the person's language.
    private static func list(_ pages: [Int]) -> String {
        pages.sorted().map(String.init).formatted(.list(type: .and))
    }
}

/// Why a server read ended without rows. Each case has its own sentence; none
/// leaves a spinner behind.
enum LabsOCRFailure: Sendable, Equatable {
    /// 413 `labs.ocr.fileTooLarge` or 422 `labs.ocr.tooLarge`.
    case tooLarge
    /// 422 `labs.ocr.outputLimit`.
    case outputLimit
    /// 429 `labs.ocr.budgetExceeded`: the day's budget is used up.
    case budgetExceeded
    /// Any other 429: too many reads in a short time.
    case rateLimited
    /// 503 `aiRuns.readerBusy`.
    case readerBusy
    /// 415 `labs.ocr.fileType`.
    case fileType
    /// The run outlived its wait (`aiRuns.timedOut`, `aiRuns.workerUnavailable`).
    case timedOut
    /// No consent (on the device or the server's `consent.ai.required`).
    case consentRequired
    /// Reading is switched off or not permitted for this record.
    case unavailable
    /// No connection.
    case offline
    /// POLISH-A A4 — the upload ran out of background time (app switched away).
    case backgroundEnded
    /// Anything else (`labs.ocr.extractFailed`, `aiRuns.failed`, unreadable).
    case failed

    init(_ error: Error) {
        if error is DocumentAIConsentError {
            self = .consentRequired
            return
        }
        if error is LabUploadInterrupted {
            self = .backgroundEnded
            return
        }
        switch error as? HLError {
        case .rateLimited:
            self = .rateLimited
        case .offline, .network:
            self = .offline
        case .aiUnavailable, .moduleDisabled:
            self = .unavailable
        case let .server(status, code, _):
            self = Self.from(status: status, code: code ?? "")
        default:
            self = .failed
        }
    }

    /// The server codes with a sentence of their own.
    private static let byCode: [String: LabsOCRFailure] = [
        "labs.ocr.fileTooLarge": .tooLarge,
        "labs.ocr.tooLarge": .tooLarge,
        "labs.ocr.outputLimit": .outputLimit,
        "labs.ocr.budgetExceeded": .budgetExceeded,
        "labs.ocr.rateLimited": .rateLimited,
        "aiRuns.readerBusy": .readerBusy,
        "labs.ocr.fileType": .fileType,
        "aiRuns.timedOut": .timedOut,
        "aiRuns.workerUnavailable": .timedOut,
        "consent.ai.required": .consentRequired,
        "module.disabled": .unavailable,
        "ai.record.notPermitted": .unavailable,
        "ai.unavailable": .unavailable,
        "labs.ocr.providerUnsupported": .unavailable
    ]

    private static func from(status: Int, code: String) -> LabsOCRFailure {
        if let known = byCode[code] { return known }
        if code.hasPrefix("assistant.disabled") { return .unavailable }
        switch status {
        case 413: return .tooLarge
        case 415: return .fileType
        default: return .failed
        }
    }

    var messageKey: String {
        switch self {
        case .tooLarge: "labs.ocr.error.tooLarge"
        case .outputLimit: "documents.read.outputLimit"
        case .budgetExceeded: "labs.ocr.error.budgetExceeded"
        case .rateLimited: "labs.ocr.error.rateLimited"
        case .readerBusy: "documents.read.readerBusy"
        case .fileType: "labs.ocr.error.fileType"
        case .timedOut: "labs.ocr.error.timedOut"
        case .consentRequired: "labs.ocr.error.consentRequired"
        case .unavailable: "labs.ocr.error.unavailable"
        case .offline: "labs.ocr.error.offline"
        case .backgroundEnded: "labs.ocr.error.backgroundEnded"
        case .failed: "labs.ocr.error.failed"
        }
    }
}
