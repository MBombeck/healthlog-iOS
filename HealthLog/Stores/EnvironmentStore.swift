import Foundation
import Observation

/// `@MainActor @Observable` store backing the native environmental-context
/// display surface (Build 7 Item 7.7). Loads the module overview via
/// ``EnvironmentRepository`` (`GET /api/environment`) and holds the in-memory
/// snapshot: the coarse home, the travel overrides, the observation-coverage
/// summary, and the licence-mandated Open-Meteo attribution.
///
/// **Module-gated (default-ON).** A `403 module.disabled` flips ``isDisabled`` so
/// the surface renders the neutral disabled hint instead of an error (mirrors
/// ``NutrientStore`` / ``IllnessStore``).
///
/// **Render-only.** The store never derives weather itself — the server owns the
/// observations (and consumes them for correlations). This surface only reflects
/// what the overview reports: where the data is anchored and how much of it
/// exists. There is no air-quality / pollen / UV data in the contract.
///
/// **Attribution invariant.** ``attribution`` is ALWAYS a non-empty Open-Meteo
/// credit — seeded to the canonical string and only ever replaced by a non-empty
/// server value — so the CC BY 4.0 obligation holds even before the first load
/// resolves and across a disabled / failed load.
@MainActor
@Observable
public final class EnvironmentStore {
    /// The coarse home location, or `nil` when the user has not set one.
    public private(set) var home: EnvironmentHomeDTO?
    /// The manual travel overrides (newest-first, as served). Empty when none.
    public private(set) var travel: [EnvironmentTravelDTO] = []
    /// The observation-coverage summary (day count + latest day / fetch instant).
    public private(set) var context = EnvironmentContextSummaryDTO(days: 0, latestDate: nil, latestFetchedAt: nil)
    /// The licence-mandated Open-Meteo credit. Seeded to the canonical string so
    /// it is present from the first frame; never overwritten with an empty value.
    public private(set) var attribution: String = EnvironmentOverviewDTO.defaultAttribution

    public private(set) var isLoading = false
    /// True after a `403 module.disabled` — the `environment` module is OFF.
    public private(set) var isDisabled = false
    /// `true` once a load has resolved (success OR disabled), so the surface can
    /// tell "not loaded yet" from "loaded, genuinely empty".
    public private(set) var hasLoaded = false
    public private(set) var lastError: String?

    private let repository: EnvironmentRepository
    private var isReloading = false

    public init(repository: EnvironmentRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    /// Whether the account has configured a home location (a home with usable
    /// coordinates). Drives the "set a home to start" empty hint vs. the summary.
    public var hasHome: Bool {
        guard let home else { return false }
        return home.lat != nil && home.lon != nil
    }

    /// Whether the overview carries anything worth showing beyond the attribution
    /// (a home or at least one stored observation day). When false and loaded, the
    /// surface shows the neutral "no data yet" hint (still WITH the attribution).
    public var hasContent: Bool {
        hasHome || context.days > 0 || !travel.isEmpty
    }

    // MARK: - Load

    /// Load the module overview. Re-entrant-safe (a concurrent call is coalesced).
    /// A `403 module.disabled` flips ``isDisabled`` instead of surfacing an error.
    /// The attribution is only ever replaced by a non-empty server value.
    public func load() async {
        guard !isReloading else { return }
        isReloading = true
        isLoading = true
        defer {
            isLoading = false
            isReloading = false
            hasLoaded = true
        }
        do {
            let overview = try await repository.overview()
            home = overview.home
            travel = overview.travel
            context = overview.context
            if !overview.attribution.isEmpty {
                attribution = overview.attribution
            }
            isDisabled = false
            lastError = nil
        } catch {
            handle(error)
        }
    }

    // MARK: - Private

    private func handle(_ error: Error) {
        if EnvironmentRepository.isEnvironmentDisabled(error) {
            isDisabled = true
            lastError = nil
        } else {
            lastError = LogSanitizer.redact(String(describing: error))
        }
    }
}

// MARK: - LogoutClearable

extension EnvironmentStore: LogoutClearable {
    /// Wipe the per-user environment snapshot on logout so the next user never
    /// inherits the predecessor's home / travel / coverage. The attribution is
    /// reset to the canonical string (a constant, not user data) so it stays
    /// present for the next session. Idempotent.
    public func clearOnLogout() {
        home = nil
        travel = []
        context = EnvironmentContextSummaryDTO(days: 0, latestDate: nil, latestFetchedAt: nil)
        attribution = EnvironmentOverviewDTO.defaultAttribution
        isLoading = false
        isReloading = false
        isDisabled = false
        hasLoaded = false
        lastError = nil
    }
}
