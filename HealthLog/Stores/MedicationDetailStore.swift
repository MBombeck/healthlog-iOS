import Foundation
import Observation

/// Per-screen state for `MedicationDetailScreen`. Hydrates the GLP-1 extras,
/// paginated intake history, and brand-resolved catalog drug record.
///
/// Concurrency: `@MainActor @Observable`; SwiftUI views read `medication`,
/// `details`, `intakes`, `drug` directly. Data-fetch is structured-concurrency
/// `async let` so the three GETs run in parallel.
@MainActor
@Observable
public final class MedicationDetailStore {
    /// v0.14.8 — became mutable so the detail screen's Edit flow can refresh
    /// the hero name/dose + ScheduleSection in place after a `PUT` save
    /// (operator brief 2026-06-07: a corrected plan must be "sofort sichtbar").
    /// Updated via ``updateMedication(_:)`` from `MedicationsStore`'s reloaded
    /// list; `load()` still only refreshes the GLP-1 / intake / compliance
    /// payloads.
    public private(set) var medication: Medication
    public private(set) var details: Glp1DetailsDTO?
    /// `internal(set)` (not `private(set)`) for the same reason `efficacy` is:
    /// the T-4 optimistic-mutation family that writes it lives in
    /// `MedicationDetailStore+IntakeMutations.swift` (15-01 W-FILELEN split),
    /// and Swift's `private` is file-scoped. Nothing outside this store's own
    /// files writes it.
    public internal(set) var intakes: [PaginatedIntakeEvent] = []
    public private(set) var intakesMeta: PaginatedIntakeMeta?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    public private(set) var hasMoreIntakes: Bool = false

    /// **v0.6.2.3 B1 — server-canonical 30-day compliance payload.**
    ///
    /// Fetched in `load()` alongside `details` + `intakes` from
    /// `GET /api/medications/[id]/compliance`. The screen reads
    /// `compliance30.rate`/`taken`/`totalExpected` for the KPI tile
    /// and `dailyCompliance` for the 14-day Verlauf glyph track.
    ///
    /// Why server-side: client-side derivation from the loaded
    /// `intakes` set undercounts past slots for cadences whose
    /// expected-vs-actual ratio drifts inside the page window —
    /// most painfully weekly schedules where Lisinopril shows
    /// "0 von 2 pünktlich" against an actually-multi-week history.
    /// The server already runs the full expected-dose projection
    /// against the schedules + complete intake stream, so reading
    /// its numbers directly puts both the iOS and web cards on the
    /// same source of truth.
    public private(set) var compliance: MedicationCompliancePayload?

    /// **W3-MEDCONTRACT (v0.14.8) — server dose-history ledger.**
    ///
    /// `GET /api/medications/{id}/dose-history` — the ONE unified per-slot
    /// read-model the server compliance % and the web Verlauf tab consume,
    /// era-aware since v1.16.3: after a schedule edit, past days are judged
    /// against the schedule that was live THEN (`scheduleRevisions`), which
    /// no client-side projection from the *current* schedule can reproduce.
    /// When present it is authoritative for every past-slot surface on this
    /// screen (KPI, glyph track, Verlauf list); `nil` (older server ≤
    /// v1.15.17, standalone mode, fetch hiccup) keeps the existing local
    /// derivation as the fallback. Local math stays in charge of *future*
    /// projection (b162 dose-safety: ledger `upcoming` rows never read as
    /// taken) and of the card's `nextDueOverdue` composition (b175 — both
    /// untouched, they compose with the ledger rather than replace it).
    public private(set) var doseHistory: MedicationDoseHistoryEnvelope?

    /// **v1.28 (GH iOS #45) — server-authoritative medication-efficacy view.**
    ///
    /// `GET /api/medications/{id}/efficacy` — the resolved "Wirkung" DTO: the
    /// target metric/lab, its series with start/dose-change/pause markers, the
    /// before/after-start comparison, and the cadence-aware adherence lane, ALL
    /// computed by the server's compliance engine. Association-only; the client
    /// never recomputes any figure here. `nil` = feature absent (route not on a
    /// ≤ v1.27 server, standalone, or a fetch hiccup) → the section
    /// self-suppresses. `internal(set)` so the `+Efficacy` extension's
    /// ``reloadEfficacy()`` can refresh it after a retarget PUT.
    public internal(set) var efficacy: MedicationEfficacyDTO?

    /// **W-COMPLIANCE-INV (v0.14.8) — paint gate for the compliance KPI.**
    ///
    /// `false` until the first `load()` has fully settled (every parallel GET
    /// — including the compliance payload + the dose-history ledger — has
    /// either landed or failed). While `false`, `complianceKPIState()` reads
    /// `.pending` so the KPI tile paints a placeholder instead of the
    /// client-side interim derivation. This kills the operator-reported
    /// 100 → 60 → 50 value-jump on screen-open: paint 1 used to read 100 %
    /// (empty `intakes` → `total == 0` → ratio 1.0), paints 2..N re-derived
    /// from each partially-drained intake page, and only the LAST paint
    /// showed the server ledger. Flips exactly once; a later `.refreshable`
    /// reload keeps the previous (server) values painting — stale-but-stable
    /// beats a placeholder flash mid-screen.
    public private(set) var hasSettledComplianceLoad: Bool = false

    /// **14-02 (A3) — has the intake collection finished arriving?**
    ///
    /// `false` from the start of every `load()` until `drainRemainingIntakes()`
    /// returns (and unconditionally on any exit, so it cannot strand). While it
    /// is `false` the intake set is still growing and is therefore not a curve:
    /// ``pkDoseEvents()`` returns `[]` and ``drugLevelSection`` reads
    /// `.loading`. This is the difference the drug-level section never had, and
    /// its absence is why the section drew one curve per drain page and then
    /// jumped when the last one landed.
    public private(set) var hasSettledIntakeCollection: Bool = false

    /// **14-02 (A3) — what the drug-level section renders.** Three states, one
    /// of them new: `.loading` (reserved height), `.empty`, `.curve`. Published
    /// exactly once per settled intake input.
    /// `internal(set)` (not `private(set)`) for the same reason `efficacy` is:
    /// the `+PK` extension that owns the compute lives in another file of the
    /// same module (W-FILELEN split), and it is the only writer.
    public internal(set) var drugLevelSection: DrugLevelSection = .loading

    /// Publication fence for the memoized PK compute. Bumped at the top of
    /// every `load()`; a curve whose compute started under an older generation
    /// publishes nothing.
    @ObservationIgnored private var pkGenerationCounter: UInt64 = 0

    /// Read-only view of the fence for the `+PK` extension.
    var pkGeneration: UInt64 {
        pkGenerationCounter
    }

    /// 14-02 — test seam: fires once per curve COMPUTATION (not per
    /// publication), so "computed once per settled input" is countable without
    /// reading a private field.
    @ObservationIgnored var onDrugLevelCurveComputed: (@MainActor () -> Void)?

    /// **W-COMPLIANCE-INV Task 2 — generic per-medication inventory.**
    ///
    /// `GET /api/medications/[id]/inventory` — the SAME per-item list the
    /// web's "Bestand" tab (v1.15.18) renders **for ALL medications** (pill
    /// packs count too; the route has no GLP-1 gate, only an ownership
    /// guard). Pre-fix iOS only surfaced inventory through the GLP-1-gated
    /// `details?.inventory` aggregate + `PenInventoryView`, so a stored
    /// tablet/injection inventory was invisible on the detail screen.
    /// `nil` = fetch unavailable (standalone / not yet loaded / error);
    /// `[]` = server answered with no items (section stays hidden).
    public private(set) var inventoryItems: [MedicationInventoryItemDTO]?

    /// Whether the generic inventory section should render: at least one
    /// item stored server-side, regardless of `treatmentClass`.
    public var hasGenericInventory: Bool {
        !(inventoryItems ?? []).isEmpty
    }

    /// Drug-id resolved from `medication.name` via the catalog. `nil` when
    /// the brand is unknown (catalog miss) — caller renders an unknown-drug
    /// state instead of falling back to a default curve (MDR boundary).
    public let drug: GLP1DrugCatalog.DrugRecord?

    private let repo: MedicationsRepository
    /// Server seam for the generic inventory read. `nil` in standalone /
    /// unit tests — the section then never renders from this store (the
    /// GLP-1 local pen mechanism stays available independently).
    private let therapyRepo: MedicationTherapyLogRepository?

    /// **W-TZ-MED (v0.15.2) — server-profile day-anchoring zone.** The Verlauf
    /// glyph track buckets each server dose/intake row into a calendar day; that
    /// bucketing must use the SAME profile IANA zone the rest of the med stack
    /// anchors on (`MedicationsStore.profileTimeZone`, `DashboardStore`,
    /// `ComplianceReconciler`, `MedicationDayKey`), NOT the device TZ — else a
    /// traveling user (device TZ ≠ profile TZ) sees a dose on the wrong day.
    /// Provider closure (mirrors the sibling stores) so a later settings
    /// hydration is honoured; defaults to `.current` and each
    /// `MedicationDetailScreen` call-site points it at the live store provider.
    /// A nil/unknown profile zone resolves to `.current` (device-TZ fallback).
    private let profileTimeZoneProvider: () -> TimeZone

    /// Resolved server-profile day-anchoring zone, falling back to `.current`.
    var profileTimeZone: TimeZone {
        profileTimeZoneProvider()
    }

    /// Gregorian calendar pinned to the profile zone — the default Verlauf
    /// day-bucketing calendar (tests still inject an explicit one).
    /// `internal` (not `private`) so the `+Compliance.swift` extension can
    /// bucket against it (same-module split — W-FILELEN).
    var profileCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = profileTimeZone
        return calendar
    }

    /// Initial + page-load size for the paginated intake history.
    ///
    /// **v0.6.2.1 F4 — bumped from 7 → 30.** The detail screen derives
    /// two analytics surfaces from the loaded intake set:
    /// `verlaufGlyphs()` (14-day track) and `complianceSummary()`
    /// (30-day KPI labelled "Letzte 30 Tage"). With page-size 7, a
    /// medication scheduled multiple times per day exhausted the page
    /// inside a few days, and the missed-day events that the operator
    /// expected to populate the analytics windows lived behind a
    /// "Mehr laden" tap they never made. The compliance KPI then
    /// undercounted total past-due slots (Lisinopril screenshot
    /// 2026-05-24 15:50 — read "0 von 2 pünktlich" against an
    /// actually-multi-week history).
    ///
    /// 30 covers a 1×-daily medication's full 30-day KPI window in
    /// one round-trip, and a 2×-daily medication's 14-day glyph
    /// window. Higher cadences still need a "Mehr laden" tap, which
    /// is acceptable (rare cadence + UX seam already present).
    private let intakesPageSize: Int = 30

    public init(
        medication: Medication,
        repo: MedicationsRepository,
        therapyRepo: MedicationTherapyLogRepository? = nil,
        // W-TZ-MED — the Verlauf day-bucketing zone. Defaults to `.current`
        // (device TZ) so existing call-sites + unit tests are byte-unchanged;
        // the detail screen wires it to the live `MedicationsStore`
        // profile-zone provider so a traveling user buckets on the profile day.
        profileTimeZoneProvider: @escaping () -> TimeZone = { .current }
    ) {
        self.medication = medication
        self.repo = repo
        self.therapyRepo = therapyRepo
        self.profileTimeZoneProvider = profileTimeZoneProvider
        if let id = GLP1DrugCatalog.detectDrugID(fromMedicationName: medication.name) {
            drug = GLP1DrugCatalog.drug(for: id)
        } else {
            drug = nil
        }
    }

    /// Whether the chart entry-point should render at all. False for
    /// non-GLP-1 medications (treatmentClass != "GLP1") and for GLP-1
    /// medications whose brand we can't match in the catalog.
    public var isGLP1Recognised: Bool {
        guard medication.treatmentClass == "GLP1" else { return false }
        return drug != nil
    }

    /// Whether the surface should render the unknown-drug empty state — i.e.
    /// the server says this is a GLP-1 medication but we can't match the
    /// brand in the local catalog (new drug, typo, etc.).
    public var isUnknownGLP1Brand: Bool {
        medication.treatmentClass == "GLP1" && drug == nil
    }

    /// Load the GETs in parallel. Safe to call repeatedly — overwrites
    /// `details`, `compliance`, and the first page of `intakes`.
    public func load() async {
        isLoading = true
        error = nil
        // 14-02 (A3) — a new load supersedes any curve still being computed for
        // the previous input, and the section returns to its reserved-height
        // loading branch rather than holding a curve built from a set that is
        // about to be replaced.
        pkGenerationCounter &+= 1
        hasSettledIntakeCollection = false
        drugLevelSection = .loading
        defer { isLoading = false }
        // 14-02 (A3) — unconditional, and declared before anything can throw:
        // the section may not strand on `.loading` on ANY exit path. 13-03
        // found this shape three times over; it does not get to happen a
        // fourth.
        defer { hasSettledIntakeCollection = true }
        defer { settleDrugLevelSectionIfStillLoading() }
        // W-COMPLIANCE-INV — the KPI may paint as soon as this load attempt
        // has settled, whether it produced server payloads (→ server-canonical
        // numbers) or not (offline / old server → clearly-marked fallback).
        defer { hasSettledComplianceLoad = true }
        do {
            async let details = repo.glp1Details(medicationID: medication.id)
            async let intakes = repo.intakeHistory(
                medicationID: medication.id,
                limit: intakesPageSize,
                offset: 0
            )
            // v0.6.2.3 B1 — load the server-canonical compliance payload
            // alongside intakes so the KPI tile + Verlauf track render
            // numbers that agree with the web card surface. Throws are
            // swallowed locally so a single 5xx on this endpoint doesn't
            // gate the whole screen; the renderer falls back to the
            // legacy client-derived view in that case.
            async let compliance = repo.compliance(medicationID: medication.id)
            // W3-MEDCONTRACT — fetch the dose-history ledger in the same
            // parallel fan-out. Tolerant: any throw (route absent on ≤
            // v1.15.17, standalone, transient 5xx) leaves `doseHistory`
            // nil and the legacy client-side derivation stays in charge.
            async let doseHistory = repo.doseHistory(medicationID: medication.id)
            // v1.28 (GH iOS #45) — fetch the server-authoritative efficacy
            // ("Wirkung") view in the same parallel fan-out. `efficacy(...)`
            // never throws (route absent / standalone / transport error → nil),
            // so the section simply self-suppresses; no `try` needed.
            async let efficacy = repo.efficacy(medicationID: medication.id)
            // W-COMPLIANCE-INV Task 2 — generic per-medication inventory for
            // ALL treatment classes (web "Bestand" tab parity). Tolerant: a
            // throw / missing seam leaves `inventoryItems` nil → no section.
            async let inventory = fetchInventory()
            // The /glp1 endpoint is only meaningful for GLP-1-classed
            // medications. For non-GLP-1 we still load `intakes` (the
            // history card is generic) but skip the GLP-1 details fetch
            // to avoid an avoidable 404 / empty-payload roundtrip.
            if medication.treatmentClass == "GLP1" {
                self.details = try await details
            } else {
                // Discard the GLP-1 task — caller doesn't need it. We start
                // the request anyway to keep parallelism simple; the server
                // returns either the medication's empty doseChanges/intakes
                // or 404, both swallowed.
                _ = try? await details
                self.details = nil
            }
            let intakesPage = try await intakes
            self.intakes = intakesPage.events
            intakesMeta = intakesPage.meta
            hasMoreIntakes = intakesPage.events.count == intakesPageSize
            // v0.10.0 B17b — auto-drain the remaining intake pages so the
            // Verlauf list + the client-derived glyph fallback see the
            // FULL history, not just the first 30. The operator saw "die
            // Sachen unter Verlauf werden nicht gezogen" (build 90): a
            // 2×-daily med exhausts page-1 inside ~15 days, so the missed
            // older slots lived behind a "Mehr laden" tap nobody makes.
            // Mirrors the MoodRepository B16 offset-drain (0cd50273) with
            // a hard page cap so a runaway total can't spin forever.
            await drainRemainingIntakes()
            // 14-02 (A3) — the drain IS the drug-level section's input, and it
            // has just settled. Compute the curve once, here, off the render
            // path; the remaining awaits below belong to other sections and
            // must not hold the curve back.
            hasSettledIntakeCollection = true
            await recomputeDrugLevelSection()
            // Awaiting `compliance` last keeps the existing fail-fast
            // contract on `details` + `intakes` intact while allowing the
            // compliance fetch to fail silently — `as? HLError` would
            // demote the error path, but a `try?` here keeps the screen
            // usable when only this endpoint hiccups.
            self.compliance = try? await compliance
            self.doseHistory = try? await doseHistory
            self.efficacy = await efficacy
            inventoryItems = await inventory
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// W-COMPLIANCE-INV Task 2 — generic inventory read. `nil` when no
    /// server seam is wired (standalone) or the round-trip failed; the
    /// caller keeps the previous value only across transient errors inside
    /// `load()` by overwriting with the fresh result.
    private func fetchInventory() async -> [MedicationInventoryItemDTO]? {
        guard let therapyRepo else { return nil }
        return try? await therapyRepo.inventory(medicationID: medication.id)
    }

    /// **C2 (v1.16.10–.12) — refetch the supply list alone (one GET).** Called
    /// after every supply mutation AND after any intake-mutation success so the
    /// on-device runway converges onto the server's decremented stock instead of
    /// showing a stale figure (web parity: "every intake path refetches").
    /// A throw keeps the previous list in place (stale-but-stable).
    public func reloadInventory() async {
        guard let therapyRepo else { return }
        if let refreshed = try? await therapyRepo.inventory(medicationID: medication.id) {
            inventoryItems = refreshed
        }
    }

    /// **C2 — register a new supply container.** Optimistic: posts then
    /// refetches. A retriable error is enqueued by the repo (Outbox) and
    /// rethrown so the caller can keep the sheet open / show a banner.
    public func registerContainer(_ body: MedicationInventoryCreate) async throws {
        guard let therapyRepo else { return }
        defer { Task { await reloadInventory() } }
        _ = try await therapyRepo.createInventoryItem(medicationID: medication.id, body: body)
    }

    /// **C2 — patch one container (correct remaining units / first-use /
    /// used-up / expiry / notes).** Posts then refetches.
    public func updateContainer(itemID: String, patch: MedicationInventoryPatch) async throws {
        guard let therapyRepo else { return }
        defer { Task { await reloadInventory() } }
        _ = try await therapyRepo.updateInventoryItem(
            medicationID: medication.id,
            itemID: itemID,
            patch: patch
        )
    }

    /// **C2 / L2 — delete a container.** Posts then refetches.
    public func deleteContainer(itemID: String) async throws {
        guard let therapyRepo else { return }
        defer { Task { await reloadInventory() } }
        try await therapyRepo.deleteInventoryItem(medicationID: medication.id, itemID: itemID)
    }

    /// W3-MEDCONTRACT — refresh the dose-history ledger alone (one GET).
    /// Called after every retro-mutation / pin / unpin so the Verlauf list
    /// converges onto the server's re-attributed truth instead of trusting
    /// a local re-derivation. A throw keeps the previous ledger in place
    /// (stale-but-consistent beats a surprise fallback flip mid-screen).
    public func reloadDoseHistory() async {
        if let refreshed = try? await repo.doseHistory(medicationID: medication.id) {
            doseHistory = refreshed
        }
    }

    /// v1.28 (GH iOS #45) — refresh the efficacy ("Wirkung") view alone. Called
    /// after a retarget PUT so the re-resolved target + series repaint. A `nil`
    /// result (route absent / hiccup) suppresses the section rather than
    /// throwing — the same graceful contract as `load()`.
    public func reloadEfficacy() async {
        efficacy = await repo.efficacy(medicationID: medication.id)
    }

    /// v1.28 (GH iOS #45) — pin (or clear) the efficacy target, then re-fetch
    /// the resolved view so the chart + before/after retarget. Interactive
    /// write (one idempotency key inside the repo). A failure records `error`
    /// (surfaced by the screen's `ErrorBanner`) rather than throwing, so the
    /// retarget picker stays a fire-and-forget tap — matching the sync-callback
    /// idiom of the other detail sections. There is no separate GET for the
    /// target: the current pin is read straight off the efficacy DTO, hence the
    /// reload on success.
    public func setEfficacyTarget(_ selection: EfficacyTargetSelection) async {
        do {
            _ = try await repo.setEfficacyTarget(medicationID: medication.id, selection: selection)
            await reloadEfficacy()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// v0.14.8 — replace the screen's `medication` with a freshly-edited copy
    /// (same `id`) so the hero name/dose + ScheduleSection re-render in place
    /// after the Edit sheet saves. Guards on matching `id` so a stale caller
    /// can't swap the screen onto a different medication.
    public func updateMedication(_ updated: Medication) {
        guard updated.id == medication.id else { return }
        medication = updated
    }

    /// Append the next paginated page of intakes onto `intakes`. No-op when
    /// the previous page was short (server returned < pageSize).
    public func loadMoreIntakes() async {
        guard hasMoreIntakes, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repo.intakeHistory(
                medicationID: medication.id,
                limit: intakesPageSize,
                offset: intakes.count
            )
            intakes.append(contentsOf: page.events)
            intakesMeta = page.meta
            hasMoreIntakes = page.events.count == intakesPageSize
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Hard cap on auto-drain pages — `30 * 80 = 2400` intakes, far beyond
    /// any realistic per-medication history, so a bogus `meta.total` can't
    /// spin the loop forever. Mirrors `MoodRepository.maxPages`.
    private static let maxDrainPages = 80

    /// v0.10.0 B17b — pull every remaining intake page after the first so
    /// `intakes` holds the complete history. Drives both the Verlauf list
    /// and the client-derived glyph fallback. No-op when the first page
    /// already covered everything (`hasMoreIntakes == false`).
    private func drainRemainingIntakes() async {
        var pages = 0
        while hasMoreIntakes, pages < Self.maxDrainPages {
            pages += 1
            // Stop once we've reached the server's reported total.
            if let total = intakesMeta?.total, intakes.count >= total {
                hasMoreIntakes = false
                break
            }
            do {
                let page = try await repo.intakeHistory(
                    medicationID: medication.id,
                    limit: intakesPageSize,
                    offset: intakes.count
                )
                guard !page.events.isEmpty else {
                    hasMoreIntakes = false
                    break
                }
                intakes.append(contentsOf: page.events)
                intakesMeta = page.meta
                hasMoreIntakes = page.events.count == intakesPageSize
            } catch {
                // A mid-drain failure leaves the pages we did fetch in
                // place; surface nothing (the first page already painted).
                hasMoreIntakes = false
                break
            }
        }
    }

    #if DEBUG
        /// Test-only seam — replaces `intakes` + `details` + `compliance`
        /// for state-machine snapshots. Production path is `load()` /
        /// `loadMoreIntakes()`.
        @MainActor
        // swiftlint:disable:next identifier_name
        func _testInject(
            intakes: [PaginatedIntakeEvent],
            details: Glp1DetailsDTO? = nil,
            compliance: MedicationCompliancePayload? = nil,
            doseHistory: MedicationDoseHistoryEnvelope? = nil,
            inventoryItems: [MedicationInventoryItemDTO]? = nil,
            settled: Bool = true
        ) {
            self.intakes = intakes
            self.details = details
            self.compliance = compliance
            self.doseHistory = doseHistory
            self.inventoryItems = inventoryItems
            // W-COMPLIANCE-INV — injected state represents a finished load by
            // default; pass `settled: false` to pin the pre-paint gate.
            hasSettledComplianceLoad = settled
            // 14-02 (A3) — an injection IS a settled collection: there is no
            // drain behind it. `settled: false` pins the still-collecting side.
            hasSettledIntakeCollection = settled
        }
    #endif
}
