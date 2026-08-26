import Foundation
import Observation

/// v0.7.1 W-TARGETS-EDITOR — `@Observable` wrapper over
/// `UserThresholdsRepository`.
///
/// Drives the personal-target *editor* — the editable `{ min, max }` band per
/// metric that the read-only "Ziele" surface (`InsightsTargetsStore`) renders
/// the consistency strip against. The screen (`TargetsScreen` →
/// `TargetEditorSheet`) reads `overrides`/`effective` here and writes through
/// `updateThreshold(_:to:)`.
///
/// **Write path:** optimistic — the edited band updates `overrides` locally
/// before the PUT so the editor reflects the change immediately. On server
/// failure the snapshot rolls back. The repo enqueues the patch on the outbox
/// for replay when the failure is retriable (offline / 5xx / 429), so the
/// edit survives an app restart and lands when connectivity returns.
@MainActor
@Observable
public final class UserThresholdsStore {
    /// Resolved (default + override) band per metric key.
    public private(set) var effective: [String: ThresholdRange] = [:]
    /// User-set overrides only.
    public private(set) var overrides: [String: ThresholdRange] = [:]
    public private(set) var isLoading: Bool = false
    public private(set) var isSaving: Bool = false
    public private(set) var error: HLError?
    public private(set) var lastLoadedAt: Date?

    private let repo: UserThresholdsRepository

    public init(repo: UserThresholdsRepository) {
        self.repo = repo
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let dto = try await repo.fetch()
            effective = dto.effective
            overrides = dto.overrides
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

    public func clearOnLogout() {
        effective = [:]
        overrides = [:]
        error = nil
        isSaving = false
        lastLoadedAt = nil
    }

    /// The current band for a metric — the override if set, else the effective
    /// (default-merged) range. `nil` only when neither is known (metric the
    /// server didn't emit).
    public func band(for metric: ThresholdMetric) -> ThresholdRange? {
        overrides[metric.rawValue] ?? effective[metric.rawValue]
    }

    // MARK: - Editor write path

    /// Validate + optimistically persist a single metric's band. Returns
    /// `true` on success so the caller can trigger a success haptic. On
    /// failure the local snapshot rolls back and `error` is set; the repo has
    /// already enqueued an outbox replay if the failure was retriable.
    ///
    /// Validation mirrors the server's `thresholdsUpdateSchema`: the band must
    /// sit inside the metric's physiological bounds and `min < max`. Invalid
    /// input never reaches the network — `error` is set to a 422-shaped
    /// `.server` so `ErrorBanner` surfaces the same copy the server would.
    @discardableResult
    public func updateThreshold(_ metric: ThresholdMetric, to band: ThresholdRange) async -> Bool {
        guard let validated = Self.validate(band, for: metric) else {
            error = .server(
                status: 422,
                code: "thresholds.invalid_range",
                message: String(localized: "Value outside the valid range.")
            )
            return false
        }

        let previousOverrides = overrides
        let previousEffective = effective
        // Optimistic: reflect the edit in both maps before the round-trip.
        overrides[metric.rawValue] = validated
        effective[metric.rawValue] = validated

        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let echo = try await repo.update([metric.rawValue: validated])
            overrides = echo.overrides
            return true
        } catch let err as HLError {
            // Durably-enqueued failures (retriable OR a transient-refresh 401)
            // are already on the Outbox — keep the optimistic value so the
            // editor stays consistent with what will eventually replay; only
            // roll back on a definitive rejection (422 / unknown) where the
            // write will never land.
            if err.shouldPersistToOutbox {
                error = err
                return false
            }
            overrides = previousOverrides
            effective = previousEffective
            error = err
            return false
        } catch {
            overrides = previousOverrides
            effective = previousEffective
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// Pure validation — `nonisolated` so it can be unit-tested without the
    /// live store. Returns the band unchanged when valid, `nil` when the
    /// metric's bounds or the `min < max` invariant are violated. Mirrors the
    /// server's `rangeSchemaFor` + `.refine(min < max)`.
    public nonisolated static func validate(
        _ band: ThresholdRange,
        for metric: ThresholdMetric
    ) -> ThresholdRange? {
        let bounds = metric.bounds
        guard band.min >= bounds.min, band.min <= bounds.max,
              band.max >= bounds.min, band.max <= bounds.max,
              band.min < band.max else
        {
            return nil
        }
        return band
    }
}
