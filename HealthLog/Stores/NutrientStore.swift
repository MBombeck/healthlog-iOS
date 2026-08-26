import Foundation
import Observation

/// `@MainActor @Observable` store backing the native nutrient read/display
/// surfaces (Build 7.6, GH #48). Loads the per-nutrient day-total window
/// (`GET /api/nutrients`) + lazily the per-nutrient day-series with its resolved
/// EFSA reference (`GET /api/nutrients/daily`), and drives the manual water
/// quick-add (`POST /api/nutrients/water`) with an optimistic total.
///
/// **Module-gated (default OFF).** The `nutrients` module is opt-in; a
/// `403 module.disabled` flips ``isDisabled`` so the surface renders the
/// enable-in-settings hint instead of an error (mirrors ``IllnessStore``).
///
/// **Render-only.** The store never resolves an EFSA reference itself — the
/// value + its sex-resolution come from the server's `/daily` response
/// (`null` when the profile sex is unknown; the surface then hides the
/// reference line). Units ride each row from the wire, never hardcoded.
///
/// **Sync-status.** Screens mount the shared ``HLSyncStatusFooter`` (reads the
/// app-wide `SyncStateStore` from the environment); this store only exposes
/// ``isLoading`` — no ad-hoc spinner.
@MainActor
@Observable
public final class NutrientStore {
    /// Per-nutrient window rows (latest day total + days-with-data), catalog
    /// order as served. Empty until the first load, or when no nutrient carries
    /// data in the window.
    public private(set) var rows: [NutrientOverviewRowDTO] = []
    /// The window (days) the current `rows` summarize.
    public private(set) var windowDays: Int = 14
    /// Per-nutrient day-series + resolved reference, populated on demand by the
    /// detail surface via ``loadDaily(_:)``.
    public private(set) var dailyByCode: [NutrientCode: NutrientDailySeriesDTO] = [:]

    public private(set) var isLoading = false
    /// Codes whose `/daily` series is currently in flight (detail spinner).
    public private(set) var loadingDaily: Set<NutrientCode> = []
    /// True after a `403 module.disabled` — the `nutrients` module is OFF.
    public private(set) var isDisabled = false
    public private(set) var lastError: String?

    /// **N2 — this process has already run the nutrient read-authorization
    /// request.** Deliberately in-memory and NOT persisted: HealthKit refuses to
    /// report whether a READ permission was granted, so any persisted flag would
    /// record only *our own act*, never the truth — and a stale one would then
    /// suppress the re-ask that recovers a permission reset in iOS Settings.
    /// Re-asking costs nothing (iOS raises the sheet only for types that are
    /// still undetermined), so one process-lifetime guard against a redundant
    /// round-trip per screen visit is the whole mechanism. Mirrors
    /// ``CycleStore``'s `importerActive`.
    public private(set) var hasRequestedAuthorization = false
    /// True while ``prepareHealthKitAccessIfNeeded()`` is running its first
    /// authorization request + sync of this process. Drives the *working* render
    /// of the empty surface — see ``NutrientEmptyState/preparing``.
    public private(set) var isPreparingHealthKitAccess = false

    private let repository: NutrientReadRepository
    /// Server-authoritative `nutrients` module state. `nil` in the test doubles
    /// that only exercise the read paths.
    private let moduleGate: ModuleGate?
    /// The HealthKit read-authorization seam (GH #48 dietary catalog).
    private let healthKit: AnyHealthKitWriter?
    /// The day-totals upload coordinator, kicked right after authorization so a
    /// freshly granted permission lands its 30-day backfill immediately.
    private let dailySync: (any NutrientDailySyncing)?
    private var isReloading = false

    public init(
        repository: NutrientReadRepository,
        moduleGate: ModuleGate? = nil,
        healthKit: AnyHealthKitWriter? = nil,
        dailySync: (any NutrientDailySyncing)? = nil
    ) {
        self.repository = repository
        self.moduleGate = moduleGate
        self.healthKit = healthKit
        self.dailySync = dailySync
    }

    /// The default water quick-add chip amounts (mL) — matches the web card.
    public static let waterQuickAddAmountsMl: [Double] = [200, 300, 500]

    /// **14-04 (F1) — the window the Ernährung screen reads.**
    ///
    /// `GET /api/nutrients` returns one row per nutrient **with data inside the
    /// requested window** and omits the rest, and the screen used to ask for the
    /// server's own default of 14 days. That is the whole of F1: an account
    /// whose newest nutrient day is a fortnight old holds data the server will
    /// happily serve, the web app's Nährstoffe entry is gated on a NINETY-day
    /// window and therefore shows it, and iOS asked a question narrow enough to
    /// get "nothing" back — then told the reader Apple Health had not delivered.
    ///
    /// 90 is the web's own gate, not a number invented here, and it is the same
    /// route with a different `days` — no new endpoint (L1).
    public nonisolated static let overviewWindowDays = 90
    /// The server's own default, and the fallback if a deployed server refuses
    /// the widened window (see ``readOverview(days:)``).
    public nonisolated static let serverDefaultWindowDays = 14

    // MARK: - Derived

    /// The current water row, if the window carries water data.
    public var waterRow: NutrientOverviewRowDTO? {
        rows.first { $0.nutrient == .water }
    }

    /// Latest-day water total in mL (0 when no water row yet).
    public var waterLatestAmountMl: Double {
        waterRow?.latestAmount ?? 0
    }

    /// Whether the server says the opt-in `nutrients` module is ON for this
    /// user. Follows the app-wide `!= false` idiom: an absent / not-yet-loaded
    /// module map means "don't claim it is off" (``ModuleGate`` fails open), so
    /// the surface never accuses the user of a switch they did not flip.
    public var isModuleEnabled: Bool {
        moduleGate?.isEnabled(.nutrients) != false
    }

    // MARK: - HealthKit access lifecycle (N2)

    /// **N2 — the state-driven counterpart to the settings toggle.**
    ///
    /// Until N2 the dietary read-authorization was requested at exactly one
    /// place: the moment somebody flipped the `nutrients` switch
    /// (`SettingsModulesScreen`). The module state, however, lives on the
    /// **server**. An account that already has `nutrients` ON, met by a device
    /// where the app was freshly installed, therefore never asked — and a
    /// HealthKit read type that was never requested answers exactly like an
    /// empty one: no samples, no error. The coordinator ran, found nothing and
    /// reported nothing, which is precisely how the operator's dietary data
    /// stayed on the phone.
    ///
    /// So the request now hangs on the STATE, not on the act: module on +
    /// nothing asked yet on this device ⇒ ask. It is driven from the nutrient
    /// surface's `.task` rather than from the coordinator, because the
    /// coordinator also runs from the foreground sweep and the background task —
    /// a permission sheet that appears while somebody is doing something else
    /// entirely is worse than no sheet at all. On the nutrient screen the sheet
    /// is explained by the screen behind it. This is the ``CycleStore``
    /// `refreshGateLifecycle` shape, and it is deliberately additive: the
    /// toggle's own call stays, because it is the fastest path for somebody
    /// standing right there.
    ///
    /// A refused request is unknowable and is treated as such — the error (if
    /// any) is logged and the flow continues, because the server stays the
    /// source of truth and the sync simply finds nothing. Nothing here ever
    /// claims a permission was denied, and nothing re-asks in a loop.
    public func prepareHealthKitAccessIfNeeded() async {
        guard isModuleEnabled else { return }
        guard !hasRequestedAuthorization else { return }
        // Set BEFORE the first suspension so a second `.task` on the same tick
        // cannot slip a duplicate request through (CycleStore's `importerActive`
        // ordering). Set even when the request throws: we asked, and whether it
        // was granted is not knowable either way.
        hasRequestedAuthorization = true
        isPreparingHealthKitAccess = true
        defer { isPreparingHealthKitAccess = false }
        do {
            try await healthKit?.requestNutrientAuthorizationIfNeeded()
        } catch {
            HLLog.healthKit.error(
                "nutrient HK auth failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
        await dailySync?.triggerNutrientSync()
        // The sweep may just have uploaded up to 30 days of day-totals; re-read
        // so the surface shows them instead of the empty state it painted a
        // moment ago.
        await load(days: windowDays)
    }

    /// **N2 — the one action the "module is off" empty state offers.**
    ///
    /// Flips the module ON server-side and then walks the same path the
    /// switchboard walks: request the dietary read authorization, run a first
    /// sync, re-read. One destination that actually resolves the condition
    /// rather than a sentence about where the switch lives (UI-Standard R4).
    /// Mirrors ``DocumentsOptInView``'s enable-CTA.
    public func enableModuleAndPrepare() async {
        guard let moduleGate else { return }
        _ = await moduleGate.setEnabled(.nutrients, enabled: true)
        guard isModuleEnabled else { return }
        // The previous read may have been a `403 module.disabled`; the module is
        // on now, so that verdict is stale.
        isDisabled = false
        await prepareHealthKitAccessIfNeeded()
        await load(days: windowDays)
    }

    // MARK: - Reads

    /// Load the per-nutrient window summary. Re-entrant-safe (a concurrent call
    /// is coalesced). A `403 module.disabled` flips ``isDisabled`` instead of
    /// surfacing an error.
    public func load(days: Int = NutrientStore.overviewWindowDays) async {
        guard !isReloading else { return }
        isReloading = true
        isLoading = true
        defer {
            isLoading = false
            isReloading = false
        }
        do {
            let overview = try await readOverview(days: days)
            rows = overview.nutrients
            // The server echoes the window it actually used, so a deployment
            // that clamps `days` corrects the figure the empty state names
            // without anyone having to guess it.
            windowDays = overview.windowDays
            isDisabled = false
            lastError = nil
        } catch {
            handle(error)
        }
    }

    /// **14-04 (F1)** — read the window, and degrade honestly if the deployed
    /// server refuses it.
    ///
    /// The `days` parameter is part of the published route, but its ceiling is
    /// not stated in the contract evidence available here (the sibling
    /// `/api/nutrients/daily` caps at 90; this route documents only its default
    /// of 14). A deployment that validates the parameter more tightly would
    /// answer `400`/`422`, and turning today's "empty" into "error" would be a
    /// worse screen than the one this plan is fixing. So exactly one retry, at
    /// the server's own default, and only for a client-side rejection —
    /// `403 module.disabled` is NOT one of these and still flows straight
    /// through to the module state.
    private func readOverview(days: Int) async throws -> NutrientOverviewDTO {
        do {
            return try await repository.overview(days: days)
        } catch let error as HLError where Self.isWindowRejection(error) && days != Self.serverDefaultWindowDays {
            // The interpolated value is a day-count from a client constant —
            // a request shape, never an identifier and never a reading — so it
            // is operator-grade in the sense the rule guards.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.api.notice(
                "nutrients: window \(days, privacy: .public) d refused — re-reading at the server default"
            )
            return try await repository.overview(days: Self.serverDefaultWindowDays)
        }
    }

    /// A client-side rejection of the request itself. Deliberately narrow: 403
    /// is the module gate and belongs to ``handle(_:)``, and 5xx is the server
    /// failing rather than refusing.
    nonisolated static func isWindowRejection(_ error: HLError) -> Bool {
        if case let .server(status, _, _) = error {
            return status == 400 || status == 422
        }
        return false
    }

    /// Fetch (or refresh) one nutrient's day-series + reference for the detail
    /// surface. Idempotent per code; a `403` flips ``isDisabled``.
    public func loadDaily(_ code: NutrientCode, days: Int = 30) async {
        loadingDaily.insert(code)
        defer { loadingDaily.remove(code) }
        do {
            let series = try await repository.dailySeries(nutrient: code, days: days)
            dailyByCode[code] = series
            isDisabled = false
        } catch {
            handle(error)
        }
    }

    // MARK: - Water quick-add

    /// Increment today's manual water total by `amountMl` (a quick-add chip).
    /// Optimistically bumps the displayed water total; on a confirmed online
    /// write it reloads the authoritative summed total, on an offline (queued)
    /// write it keeps the optimistic bump, and on a hard reject / disabled it
    /// rolls back.
    public func addWater(amountMl: Double) async {
        guard amountMl > 0 else { return }
        applyWaterDelta(amountMl)
        do {
            _ = try await repository.quickAddWater(amountMl: amountMl, mode: .add)
            // Server now holds it — reload the true (APPLE_HEALTH + MANUAL) total.
            await load(days: windowDays)
        } catch {
            if NutrientReadRepository.isNutrientsDisabled(error) {
                applyWaterDelta(-amountMl)
                isDisabled = true
            } else if let hl = error as? HLError, hl.shouldPersistToOutbox {
                // Queued offline — keep the optimistic bump, surface no error.
                lastError = nil
            } else {
                applyWaterDelta(-amountMl)
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Private

    /// Apply a signed delta to the water row's latest-day total (optimistic).
    /// Inserts a today-keyed water row when none exists yet (first-ever add).
    /// Clamps at zero.
    private func applyWaterDelta(_ deltaMl: Double) {
        if let idx = rows.firstIndex(where: { $0.nutrient == .water }) {
            let existing = rows[idx]
            let next = max(0, existing.latestAmount + deltaMl)
            rows[idx] = NutrientOverviewRowDTO(
                nutrient: .water,
                unit: existing.unit,
                latestDay: existing.latestDay,
                latestAmount: next,
                daysWithData: existing.daysWithData
            )
        } else if deltaMl > 0 {
            rows.append(NutrientOverviewRowDTO(
                nutrient: .water,
                unit: "ml",
                latestDay: Self.todayKey(),
                latestAmount: deltaMl,
                daysWithData: 1
            ))
        }
    }

    private func handle(_ error: Error) {
        if NutrientReadRepository.isNutrientsDisabled(error) {
            isDisabled = true
            lastError = nil
        } else {
            lastError = error.localizedDescription
        }
    }

    /// `yyyy-MM-dd` for the current local day — the same day-key rule the sync
    /// path uses for `stats:` keys.
    private static func todayKey(now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - LogoutClearable

extension NutrientStore: LogoutClearable {
    /// Wipe the per-user nutrient snapshot on logout (day totals + series are
    /// PHI-adjacent). Idempotent.
    public func clearOnLogout() {
        rows = []
        dailyByCode = [:]
        loadingDaily = []
        windowDays = 14
        isLoading = false
        isDisabled = false
        lastError = nil
        // N2 — the next user on this device must run the lifecycle again. The
        // HealthKit prompt itself will stay silent for already-determined types,
        // but the first sync it kicks carries the NEW user's per-user backfill,
        // which would otherwise wait for a foreground sweep.
        hasRequestedAuthorization = false
        isPreparingHealthKitAccess = false
    }
}
