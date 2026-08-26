import Foundation

/// v0.11 W2-reconcile + v0.13 W5 — on-device standalone medication surface.
/// Split out of the actor's primary file so the type-body stays under the
/// SwiftLint budget; same-module so it reads the actor's `internal` `standalone`
/// gate directly. Paired never reaches these — the entry-point branches in
/// `list()` / `create()` / `update()` / `delete()` / `compliance(*)` /
/// `todayIntakes()` guard on `isStandaloneActive` before any of this runs.
extension MedicationsRepository {
    // MARK: - Per-medication compliance (gated entry point, v0.13 W5 M1)

    /// Per-medication 7- and 30-day compliance. **Standalone (M1):** computed
    /// on-device from the local definition + intake mirror — gating the
    /// `/api/medications/<id>/compliance` route that would otherwise leak the
    /// moment a local med exists. **Paired:** the server-canonical payload from
    /// `src/app/api/medications/[id]/compliance/route.ts` (full intake history,
    /// matching the web `/medications` view). The full 90-day envelope is
    /// decoded so future surfaces can reach `dailyCompliance` without a re-fetch.
    public func compliance(medicationID: String) async throws -> MedicationCompliancePayload {
        if isStandaloneActive { return try await standaloneCardCompliance(medicationID: medicationID) }
        let req: APIRequest<MedicationCompliancePayload> = .get(
            "/api/medications/\(medicationID)/compliance"
        )
        return try await api.send(req)
    }

    /// **Build 6.3 — batched card compliance.** One round trip for every
    /// medication the user owns (`GET /api/medications/compliance`), replacing
    /// the per-card fan-out. Returns the per-card `compliance7` / `compliance30`
    /// / `complianceDisplay` block only (no heatmap). **Standalone:** the server
    /// route would leak, and the on-device path is per-med, so this throws
    /// `.offline` — the store falls back to its bounded per-med fan-out (which is
    /// itself standalone-gated). A ≤ pre-batch server (route absent) 404s → same
    /// fallback. Never client-recomputes: the server value is the only source.
    public func complianceSummary() async throws -> [MedicationComplianceSummaryEntry] {
        if isStandaloneActive { throw HLError.offline }
        let req: APIRequest<[MedicationComplianceSummaryEntry]> = .get("/api/medications/compliance")
        return try await api.send(req)
    }

    // MARK: - Definition CRUD (v0.13 W5)

    /// Active local medication definitions, projected into the server-shaped
    /// `Medication` the UI + recurrence engine consume. Archived rows are
    /// excluded (server parity: `active == false` drops off the active list).
    func standaloneList() async throws -> [Medication] {
        guard let standalone else { return [] }
        let snaps = try await standalone.local.standaloneMedications(includeArchived: false)
        // v0.14 DATA — thread each med's latest *taken* intake from the local
        // mirror into `toDomainMedication(lastTakenAt:)` so the recurrence
        // engine can anchor a rolling / `startsOn==today` cadence inside today's
        // window. Without this anchor the engine projected the next rolling slot
        // off `createdAt` → tomorrow → the due surfaces falsely read "nothing
        // due" (v0.13 W5 regression).
        let intakes = try await standalone.local.standaloneIntakes(medicationId: nil)
        let lastTakenByMed = Self.latestTakenByMedication(intakes)
        return snaps.map { $0.toDomainMedication(lastTakenAt: lastTakenByMed[$0.externalId]) }
    }

    /// Newest `taken` intake timestamp per `medicationId` from the local mirror
    /// — the engine's rolling/overdue anchor. Skipped/missed dispositions are
    /// ignored (a skipped dose is not a "last taken").
    static func latestTakenByMedication(_ intakes: [LocalIntakeSnapshot]) -> [String: Date] {
        var latest: [String: Date] = [:]
        for snap in intakes where (IntakeStatus(rawValue: snap.status) ?? .taken) == .taken {
            if let existing = latest[snap.medicationId], existing >= snap.takenAt { continue }
            latest[snap.medicationId] = snap.takenAt
        }
        return latest
    }

    /// Persist a new medication definition to the local mirror. The full
    /// `[MedicationScheduleDTO]` is encoded so the recurrence engine sees the
    /// exact cadence the user built; `id == externalId` (stable local identity).
    func standaloneCreate(_ body: MedicationCreate) async throws -> Medication {
        guard let standalone else {
            throw HLError.unknown("standaloneCreate ohne Standalone-Gate")
        }
        let snapshot = LocalMedicationSnapshot(
            externalId: UUID().uuidString,
            name: body.name,
            dose: body.dose,
            treatmentClass: body.treatmentClass,
            dosesPerUnit: body.dosesPerUnit,
            category: body.category,
            deliveryForm: body.deliveryForm,
            oneShot: body.oneShot ?? false,
            trackInjectionSites: body.trackInjectionSites ?? false,
            notificationsEnabled: body.notificationsEnabled ?? true,
            startsOn: Self.parseCourseDay(body.startsOn),
            endsOn: Self.parseCourseDay(body.endsOn),
            schedulesJSON: Self.encodeSchedules(body.schedules),
            archived: !(body.active ?? true),
            archivedAt: nil,
            createdAt: .now
        )
        let saved = try await standalone.local.standaloneAddMedication(snapshot)
        return saved.toDomainMedication()
    }

    /// Read-modify-write a local definition by `externalId`. Only the keys the
    /// patch carries change (server RMW parity); a nil `schedules` preserves the
    /// stored cadence (never drops it). Throws when the id is unknown so the
    /// store surfaces the failure rather than silently no-op'ing.
    func standaloneUpdate(id: String, patch: MedicationPatch) async throws -> Medication {
        guard let standalone else {
            throw HLError.unknown("standaloneUpdate ohne Standalone-Gate")
        }
        guard let existing = try await standalone.local.standaloneMedication(externalId: id) else {
            throw HLError.unknown("standaloneUpdate: unbekannte Medikation")
        }
        let merged = LocalMedicationSnapshot(
            externalId: existing.externalId,
            name: patch.name ?? existing.name,
            dose: patch.dose ?? existing.dose,
            treatmentClass: patch.treatmentClass ?? existing.treatmentClass,
            dosesPerUnit: patch.dosesPerUnit ?? existing.dosesPerUnit,
            category: patch.category ?? existing.category,
            deliveryForm: patch.deliveryForm ?? existing.deliveryForm,
            oneShot: patch.oneShot ?? existing.oneShot,
            trackInjectionSites: patch.trackInjectionSites ?? existing.trackInjectionSites,
            notificationsEnabled: patch.notificationsEnabled ?? existing.notificationsEnabled,
            startsOn: patch.startsOn.map(Self.parseCourseDay) ?? existing.startsOn,
            endsOn: patch.endsOn.map(Self.parseCourseDay) ?? existing.endsOn,
            // nil schedules → keep the stored cadence (RMW-safe).
            schedulesJSON: patch.schedules.map(Self.encodeSchedules) ?? existing.schedulesJSON,
            // `active: true` un-archives; `active: false` archives; nil keeps.
            archived: patch.active.map { !$0 } ?? existing.archived,
            archivedAt: (patch.active == true) ? nil : existing.archivedAt,
            createdAt: existing.createdAt
        )
        try await standalone.local.standaloneUpdateMedication(merged)
        return merged.toDomainMedication()
    }

    /// Soft-delete (archive) a local definition by `externalId`.
    func standaloneArchive(id: String) async throws {
        guard let standalone else {
            throw HLError.unknown("standaloneArchive ohne Standalone-Gate")
        }
        try await standalone.local.standaloneArchiveMedication(externalId: id, archivedAt: .now)
    }

    // MARK: - Compliance (v0.13 W5 M2 — recurrence-based denominator)

    /// **M2 — real per-day compliance.** Buckets `taken` doses per calendar day
    /// over the trailing `days` window and computes the scheduled-dose
    /// denominator via `MedicationRecurrenceEngine` over every active local
    /// definition (NOT taken==scheduled, which always read 100%). A day with no
    /// scheduled dose is omitted unless a dose was logged that day (so PRN /
    /// ad-hoc intakes still surface). Paired keeps the server-canonical split.
    func standaloneCompliance(
        days: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) async throws -> [ComplianceDay] {
        guard let standalone else { return [] }
        let start = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: start) else {
            return []
        }
        let medSnaps = try await standalone.local.standaloneMedications(includeArchived: false)
        let medications = medSnaps.map { $0.toDomainMedication() }
        let intakeSnaps = try await standalone.local.standaloneIntakes(medicationId: nil)

        // Scheduled doses per day from the recurrence engine.
        var scheduledByDay: [Date: Int] = [:]
        for medication in medications where medication.active {
            let context = MedicationRecurrenceEngine.Context(
                medication: medication,
                timeZone: calendar.timeZone,
                now: now
            )
            for entry in medication.schedule.entries {
                let occurrences = MedicationRecurrenceEngine.occurrences(
                    in: windowStart ... (start.addingTimeInterval(86400 - 1)),
                    entry: entry,
                    context: context
                )
                for occ in occurrences {
                    let day = calendar.startOfDay(for: occ.at)
                    guard day >= windowStart, day <= start else { continue }
                    scheduledByDay[day, default: 0] += 1
                }
            }
        }

        // Taken doses per day from the intake mirror.
        var takenByDay: [Date: Int] = [:]
        for snap in intakeSnaps where (IntakeStatus(rawValue: snap.status) ?? .taken) == .taken {
            let day = calendar.startOfDay(for: snap.takenAt)
            guard day >= windowStart, day <= start else { continue }
            takenByDay[day, default: 0] += 1
        }

        // Union of scheduled + logged days so neither a missed scheduled dose
        // nor an ad-hoc PRN dose is dropped from the heatmap.
        let allDays = Set(scheduledByDay.keys).union(takenByDay.keys)
        return allDays
            .map { day in
                let taken = takenByDay[day] ?? 0
                // A logged dose with no scheduled slot (PRN) counts itself as
                // its own denominator so the day reads complete, never > 100%.
                let scheduled = max(scheduledByDay[day] ?? 0, taken)
                return ComplianceDay(date: day, scheduled: scheduled, taken: taken)
            }
            .sorted { $0.date < $1.date }
    }

    /// **M1 — on-device per-medication card compliance.** Computes the 7- and
    /// 30-day windows from the local definition + intake mirror via the same
    /// recurrence engine the paired card consumes, so the offline card bar
    /// reflects the real cadence (never a flat 100%). No `/api/*`.
    func standaloneCardCompliance(medicationID: String) async throws -> MedicationCompliancePayload {
        guard let standalone else {
            return MedicationCompliancePayload(
                compliance7: Self.emptyWindow,
                compliance30: Self.emptyWindow
            )
        }
        guard let medSnap = try await standalone.local.standaloneMedication(externalId: medicationID) else {
            return MedicationCompliancePayload(
                compliance7: Self.emptyWindow,
                compliance30: Self.emptyWindow
            )
        }
        let medication = medSnap.toDomainMedication()
        let intakes = try await standalone.local.standaloneIntakes(medicationId: medicationID)
        return MedicationCompliancePayload(
            compliance7: Self.window(medication: medication, intakes: intakes, days: 7),
            compliance30: Self.window(medication: medication, intakes: intakes, days: 30),
            complianceDisplay: Self.complianceDisplay(medication: medication, intakes: intakes)
        )
    }

    // MARK: - Helpers

    private static let emptyWindow = ComplianceWindowResult(
        totalExpected: 0, taken: 0, skipped: 0, missed: 0, rate: 100, streak: 0
    )

    // MARK: - Cadence-scaled display block (v0.14.2 H2)

    /// **v0.14.2 H2 — on-device mirror of the server `buildComplianceDisplay`.**
    /// Offline/standalone never emitted the cadence-scaled `complianceDisplay`,
    /// so a weekly med (Trulicity) showed a misleading pessimistic 7-day rate
    /// offline (the exact 14%/11% pathology the server 30/90 ladder fixes).
    /// This computes the same two-row block locally so the offline card matches
    /// the online card dose-for-dose: pick the first ladder rung whose BOTH
    /// windows hold ≥ `minStableDoses` expected occurrences (else the widest
    /// rung), then read each row's rate from the cadence-correct `window(…)`
    /// (which already divides taken by the engine's real occurrence count).
    private static let complianceWindowLadder: [(short: Int, long: Int)] = [
        (7, 30), (30, 90), (90, 365)
    ]

    /// Server-canonical density floor (`MIN_STABLE_DOSES`,
    /// `src/lib/analytics/compliance.ts`): four expected doses is where a single
    /// miss moves the rate ≤ 25% rather than ±50-100%.
    private static let minStableDoses = 4

    static func complianceDisplay(
        medication: Medication,
        intakes: [LocalIntakeSnapshot],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ComplianceDisplay {
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: calendar.timeZone,
            now: now
        )
        /// Expected-occurrence count over the trailing `days` window — the same
        /// canonical engine the per-window rate uses, so PRN / off-cadence days
        /// never inflate the denominator.
        func expected(days: Int) -> Int {
            let periodStart = now.addingTimeInterval(-Double(days) * 86400)
            var total = 0
            for entry in medication.schedule.entries {
                total += MedicationRecurrenceEngine.occurrences(
                    in: periodStart ... now,
                    entry: entry,
                    context: context
                ).count
            }
            return total
        }

        // Walk densest → sparsest; first rung where BOTH windows clear the floor.
        var chosen = complianceWindowLadder[complianceWindowLadder.count - 1]
        for rung in complianceWindowLadder
            where expected(days: rung.short) >= minStableDoses
            && expected(days: rung.long) >= minStableDoses
        {
            chosen = rung
            break
        }

        let short = window(medication: medication, intakes: intakes, days: chosen.short, now: now, calendar: calendar)
        let long = window(medication: medication, intakes: intakes, days: chosen.long, now: now, calendar: calendar)
        return ComplianceDisplay(
            shortDays: chosen.short,
            longDays: chosen.long,
            short: ComplianceDisplayWindow(
                rate: short.rate,
                taken: short.taken,
                expected: Double(short.totalExpected),
                streak: short.streak
            ),
            long: ComplianceDisplayWindow(
                rate: long.rate,
                taken: long.taken,
                expected: Double(long.totalExpected)
            )
        )
    }

    private static func window(
        medication: Medication,
        intakes: [LocalIntakeSnapshot],
        days: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ComplianceWindowResult {
        let day: TimeInterval = 86400
        let periodStart = now.addingTimeInterval(-Double(days) * day)
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: calendar.timeZone,
            now: now
        )
        var totalExpected = 0
        for entry in medication.schedule.entries {
            totalExpected += MedicationRecurrenceEngine.occurrences(
                in: periodStart ... now,
                entry: entry,
                context: context
            ).count
        }
        let windowIntakes = intakes.filter { $0.takenAt >= periodStart && $0.takenAt <= now }
        let taken = windowIntakes.filter { (IntakeStatus(rawValue: $0.status) ?? .taken) == .taken }.count
        let skipped = windowIntakes.filter { IntakeStatus(rawValue: $0.status) == .skipped }.count
        let rate = totalExpected == 0
            ? 100
            : min(100, Int((Double(taken) / Double(totalExpected) * 100).rounded()))
        let missed = max(0, totalExpected - taken - skipped)
        return ComplianceWindowResult(
            totalExpected: totalExpected,
            taken: taken,
            skipped: skipped,
            missed: missed,
            rate: rate,
            streak: 0
        )
    }

    /// Encode a `[MedicationScheduleDTO]` for local persistence. `nil`/empty →
    /// `nil` (no schedule = PRN-like).
    static func encodeSchedules(_ schedules: [MedicationScheduleDTO]?) -> Data? {
        guard let schedules, !schedules.isEmpty else { return nil }
        return try? JSONEncoder().encode(schedules)
    }

    /// Parse a wire `YYYY-MM-DD` course date into a UTC-midnight `Date`
    /// (reusing the wire DTO's parser for parity with the paired path).
    static func parseCourseDay(_ raw: String?) -> Date? {
        MedicationWireDTO.parseCourseDate(raw)
    }
}
