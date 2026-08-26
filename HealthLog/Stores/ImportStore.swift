import Foundation
import Observation

/// Drives the CSV data-import surface (`ImportDataScreen`): read a picked CSV,
/// run the server **dry-run** preview (no writes, projected counts), then commit
/// the real import on the user's confirmation. Views → Store → ``ImportService``
/// keeps the file-read + orchestration off the SwiftUI `body`.
///
/// The picked CSV text is held transiently in memory only between preview and
/// commit so the confirmed import writes exactly what was previewed; it is
/// dropped on ``reset()`` / logout.
@MainActor
@Observable
public final class ImportStore {
    /// The import lifecycle. `.previewed` carries the dry-run projection the
    /// screen shows before the user commits; `.done` carries the real result.
    public enum Phase: Equatable {
        case idle
        case previewing
        case previewed(CSVImportResult)
        case importing
        case done(CSVImportResult)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    private let service: ImportService
    /// The CSV text pending commit (set at preview, cleared after commit/reset).
    private var pendingCSV: String?

    public init(service: ImportService) {
        self.service = service
    }

    /// Read the picked CSV file (security-scoped) and run the dry-run preview.
    public func preview(fileURL: URL) async {
        phase = .previewing
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let csv: String
        do {
            let data = try Data(contentsOf: fileURL)
            guard let text = String(data: data, encoding: .utf8) else {
                phase = .failed(String(localized: "import.error.not_utf8"))
                return
            }
            csv = text
        } catch {
            phase = .failed(String(localized: "import.error.read_failed"))
            return
        }
        await preview(csv: csv)
    }

    /// Run the dry-run preview against the given CSV text. Split out from the
    /// file read so it is directly unit-testable with a stub client.
    public func preview(csv: String) async {
        phase = .previewing
        do {
            let result = try await service.importCSV(csv, dryRun: true)
            pendingCSV = csv
            phase = .previewed(result)
        } catch let error as HLError {
            phase = .failed(error.userFacingDescription)
        } catch {
            phase = .failed(String(localized: "import.error.generic"))
        }
    }

    /// Commit the previewed CSV for real (no dry-run). No-op if there is nothing
    /// pending (e.g. the preview failed).
    public func commit() async {
        guard let csv = pendingCSV else { return }
        phase = .importing
        do {
            let result = try await service.importCSV(csv, dryRun: false)
            pendingCSV = nil
            phase = .done(result)
        } catch let error as HLError {
            phase = .failed(error.userFacingDescription)
        } catch {
            phase = .failed(String(localized: "import.error.generic"))
        }
    }

    /// Back to the empty state (the "Import another file" affordance).
    public func reset() {
        pendingCSV = nil
        phase = .idle
    }

    public func clearOnLogout() {
        reset()
    }
}
