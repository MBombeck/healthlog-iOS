import Foundation
import Observation

/// `@Observable` wrapper over ``EcgRepository`` — hydrates the Insights **ECG**
/// surface (web `/insights/ecg`, server v1.28.50).
///
/// **Metadata only.** The store holds the recording LIST; a waveform is fetched
/// on demand by the detail screen and never retained here.
///
/// **Data gate = the pill gate.** ``hasRecordings`` mirrors the server's own
/// `hasRecordings` flag and is what `liveAvailableSpecials` gates the ECG pill
/// on. An account with no recordings therefore sees no pill and no page —
/// exactly like the web, and unlike a surface that would sit there empty.
///
/// **Regulatory framing.** Everything the store exposes is the RECORDING
/// DEVICE's own output. HealthLog never re-classifies; see ``EcgListDTO``.
///
/// **Server-derived (paired only).** Pure server read, double-gated
/// (`insights` module + `insightStatus` assistant surface) — the call site
/// additionally gates on a cloud surface being available so nothing appears in
/// standalone / no-server.
@MainActor
@Observable
public final class EcgStore {
    /// The decoded recording list, or `nil` when the read is gated / absent.
    public private(set) var list: EcgListDTO?
    public private(set) var isLoading: Bool = false
    /// `true` once a load has settled at least once this session.
    public private(set) var hasSettledOnce: Bool = false
    /// `true` when the last read threw a genuine transport error. A gate is not
    /// a failure and never sets this.
    public private(set) var loadFailed: Bool = false

    private let repo: EcgRepository

    public init(repo: EcgRepository) {
        self.repo = repo
    }

    /// The surface's data gate — the ECG pill and page exist only when this is
    /// `true`. Mirrors the server flag rather than re-deriving it.
    public var hasRecordings: Bool {
        list?.hasRecordings ?? false
    }

    /// The recordings, newest first (server order, never re-sorted).
    public var recordings: [EcgRecordingDTO] {
        list?.recordings ?? []
    }

    /// The most recent recording — the pulse-page cross-link's one datum.
    public var latest: EcgRecordingDTO? {
        list?.latest
    }

    /// Loads the list. Idempotent per session unless `force` is set.
    public func load(force: Bool = false) async {
        if hasSettledOnce, !force { return }
        await fetch()
    }

    public func refresh() async {
        await fetch()
    }

    public func clearOnLogout() {
        list = nil
        hasSettledOnce = false
        loadFailed = false
    }

    private func fetch() async {
        isLoading = true
        defer {
            isLoading = false
            hasSettledOnce = true
        }
        do {
            list = try await repo.fetchList()
            loadFailed = false
        } catch {
            // Keep whatever is already painted (a transport blip must not wipe
            // a visible list), but remember the failure for the calm note.
            loadFailed = true
        }
    }

    /// Fetches one recording's waveform. Never cached; `nil` for an unknown or
    /// foreign id, or a gated read.
    public func detail(id: String) async throws -> EcgDetailDTO? {
        try await repo.fetchDetail(id: id)
    }
}
