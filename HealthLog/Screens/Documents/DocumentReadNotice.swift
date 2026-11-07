import Foundation

/// #151 — why the automatic read of a document did not produce a summary,
/// said in one calm sentence where the "being read" spinner would otherwise
/// stand. Each case is something the person cannot fix by waiting on this
/// screen, so none of them spins.
enum DocumentReadNotice: Equatable {
    /// `503 aiRuns.readerBusy`: the reader is busy, try again later.
    case readerBusy
    /// `422 documents.inbound.outputLimit`: the read was cut off before a
    /// single complete value came back.
    case outputLimit
    /// `lastIndexOutcome: resource-limit`: too large or complex to read. The
    /// server does not retry it, and the app does not either.
    case tooLarge

    /// The notice for a failed automatic read, `nil` for any other failure
    /// (those stay quiet, as before).
    static func from(error: Error) -> DocumentReadNotice? {
        if DocumentsRepository.isReaderBusy(error) { return .readerBusy }
        if DocumentsRepository.isOutputLimit(error) { return .outputLimit }
        return nil
    }

    var message: String {
        switch self {
        case .readerBusy: String(localized: "documents.read.readerBusy")
        case .outputLimit: String(localized: "documents.read.outputLimit")
        case .tooLarge: String(localized: "documents.read.tooLarge")
        }
    }
}
