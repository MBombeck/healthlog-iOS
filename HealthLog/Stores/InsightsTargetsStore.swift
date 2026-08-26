import Foundation
import Observation

/// `@Observable` wrapper over `InsightsTargetsRepository`. Drives the
/// "Ziele" / personal-targets surface — every target the user has
/// configured rendered with current value, 30-day average, trend, and
/// the 7-day consistency strip.
///
/// **Chart-relevant:** the `consistency7d` per-target buckets are the
/// dataset the iOS target tiles render as the in-band / near-band /
/// out-band dot strip. The endpoint is the single source the iOS
/// surface should consume — no client-side recomputation.
@MainActor
@Observable
public final class InsightsTargetsStore {
    public private(set) var response: InsightsTargetsResponseDTO?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    public private(set) var lastLoadedAt: Date?

    private let repo: InsightsTargetsRepository

    public init(repo: InsightsTargetsRepository) {
        self.repo = repo
    }

    public var targets: [InsightsTargetsResponseDTO.TargetItem] {
        response?.targets ?? []
    }

    public var pageSummary: InsightsTargetsResponseDTO.PageSummary? {
        response?.pageSummary
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            response = try await repo.fetch()
            lastLoadedAt = Date()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func refresh() async {
        await load()
    }

    /// Lookup helper: returns the target row for a given `MeasurementType`
    /// raw value (e.g. `"WEIGHT"`), or `nil` if the user has no target
    /// configured for that type.
    public func target(forType raw: String) -> InsightsTargetsResponseDTO.TargetItem? {
        targets.first { $0.type == raw }
    }

    public func clearOnLogout() {
        response = nil
        error = nil
        lastLoadedAt = nil
    }
}
