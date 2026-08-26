import Foundation
import Observation

// FHIR (ModelsR4) helpers live in `ExportStore+FHIR.swift` — importing ModelsR4
// here would shadow the `Observation` framework the `@Observable` macro needs.

/// **Audit v0162 H2 (layering) — ExportStore.**
///
/// Owns the repository/service construction, the FHIR/export **artifact
/// assembly**, and the PHI-write-to-disk that the four PHI-export/import
/// screens previously did inline in their SwiftUI `body`s:
///
///   - the unified sharing surface     → ``assembleFHIR(periodDays:snapshot:generatedAt:isBackendReachable:)``
///   - `SettingsExportScreen`          → ``downloadFullBackup(_:)`` / ``downloadDomainCSV(_:)``
///   - the unified sharing surface     → ``downloadHealthRecordPackage(_:)``
///   - `SettingsAppleHealthImportScreen` → ``startAppleHealthImport(fileURL:)`` + ``importPhase``
///
/// The views are now thin: they build the (Sendable) input snapshot from the
/// `@Environment` metric stores, call one store method, and render the returned
/// artifact / the published ``importPhase``. That restores the canonical
/// layering (Views → Stores → Repositories/Services) — no `ExportService` /
/// `LabsRepository` / `IllnessRepository` / `ServerFHIREverythingService`
/// construction, and no `DoctorReportSpecBuilder` / `DoctorReportToFHIRBundle`
/// assembly, in view code.
///
/// **PHI-write contract (unchanged):** every persisted export is health data,
/// so ``persist(data:filename:)`` / ``writeData(_:generatedAt:)`` land the bytes
/// under `.completeFileProtection` — matching every sibling export path
/// (`DoctorReportStore`, `DoctorReportFHIRWriter`, `DoctorReportRenderer`). A
/// source-level test pins that literal.
@MainActor
@Observable
public final class ExportStore {
    private let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let moduleGate: ModuleGate
    /// **Phase 09 / plan 09-03** — the write boundary. `ExportStore` stays
    /// `@MainActor` for its UI state; the bytes land through here, off the main
    /// actor, and only the resulting URL crosses back to be published.
    private let persistence: ExportPersistence

    public convenience init(api: APIClientProtocol, outbox: OutboxQueue, moduleGate: ModuleGate) {
        self.init(api: api, outbox: outbox, moduleGate: moduleGate, persistence: ExportPersistence())
    }

    /// The injectable form. `ExportPersistence` is an internal boundary, so it
    /// cannot appear in a public default argument — hence the pair.
    init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        moduleGate: ModuleGate,
        persistence: ExportPersistence
    ) {
        self.api = api
        self.outbox = outbox
        self.moduleGate = moduleGate
        self.persistence = persistence
    }

    // MARK: - Full backup / per-domain CSV / health-record package

    /// Download the full JSON/CSV backup (`POST /api/export`) and persist it to
    /// the temp dir under complete file protection. Returns the shareable URL.
    /// Throws `HLError` (rate-limit, network, …) so the card can surface it.
    public func downloadFullBackup(_ format: ExportService.BackupFormat) async throws -> URL {
        let export = try await ExportService(api: api).downloadFullBackup(format)
        let filename = "healthlog-export-\(Self.dayStamp(Date.now)).\(format.rawValue)"
        return try await persistExport(data: export.data, filename: filename)
    }

    /// Download one domain's server-rendered CSV and persist it. The
    /// server-suggested filename already matches the `DoctorReportTmpSweeper`
    /// owned-prefix list, so the PHI residue is swept on the doctor-report
    /// lifecycle.
    public func downloadDomainCSV(_ domain: ExportService.Domain) async throws -> URL {
        let export = try await ExportService(api: api).downloadCSV(domain)
        return try await persistExport(data: export.data, filename: export.suggestedFilename)
    }

    /// Download the unified health-record export **package** (ZIP: PDF + FHIR +
    /// readme) and persist it. The server filename matches the sweeper prefix.
    public func downloadHealthRecordPackage(_ request: HealthRecordExportRequest) async throws -> URL {
        let export = try await ExportService(api: api).downloadHealthRecordPackage(request)
        return try await persistExport(data: export.data, filename: export.suggestedFilename)
    }

    /// Download the passphrase-encrypted full backup (`HLX1` archive) and
    /// persist it under complete file protection. The passphrase never reaches
    /// disk or a log — it is passed straight to the service and forgotten.
    /// Throws `HLError` (422 not-configured, 403 MFA step-up, 429, network) so
    /// the card surfaces it honestly.
    public func downloadEncryptedBackup(passphrase: String) async throws -> URL {
        let export = try await ExportService(api: api).downloadEncryptedBackup(passphrase: passphrase)
        return try await persistExport(data: export.data, filename: export.suggestedFilename)
    }

    // MARK: - FHIR assembly

    /// The assembled FHIR bundle bytes plus which emitter produced them. The
    /// view writes the bytes via ``writeData(_:generatedAt:)`` and renders the
    /// source on the result card.
    public struct FHIRAssembly: Sendable, Equatable {
        public let json: Data
        public let source: FHIRExportSource

        public init(json: Data, source: FHIRExportSource) {
            self.json = json
            self.source = source
        }
    }

    /// What ``assembleFHIR(periodDays:snapshot:generatedAt:isBackendReachable:)``
    /// produced. Three outcomes, because "no file" has two very different
    /// causes and collapsing them was the CU-13 defect: an empty server Bundle
    /// is a *contract-correct* answer that needs an instruction, not an error.
    public enum FHIRAssemblyOutcome: Sendable, Equatable {
        /// Bundle bytes ready to write + share.
        case assembled(FHIRAssembly)
        /// The server's scoped `Patient/$everything` came back with zero
        /// entries. `hasSavedSelection` names which of the two honest causes it
        /// was — see ``ExportStore/hasSavedReportSelection()``.
        case empty(hasSavedSelection: Bool)
        /// No bundle can be produced: the doctor-report module is off, or the
        /// local emitter itself failed.
        case unavailable
    }

    /// Assemble the FHIR R4 bundle JSON, preferring the server-canonical
    /// `Patient/$everything` when paired + online and falling back to the
    /// on-device emitter otherwise (or on a server-fetch failure). Fails soft: a
    /// labs / illness fetch error just omits that block.
    ///
    /// **CU-13 — an empty server Bundle is not an export.** Since v1.34.2 the
    /// server scopes the Bundle to the owner's saved report selection, so an
    /// account that never saved one gets `200` with zero entries. Writing those
    /// bytes out would hand the user a file that looks like an export and
    /// carries nothing, so the empty Bundle is reported as its own outcome and
    /// the screen says what to do about it. It is deliberately **not** answered
    /// by falling through to the local emitter either: silently substituting the
    /// poorer bundle is exactly the unnoticed degradation this unit removes.
    ///
    /// - Parameter snapshot: built by the caller from the live metric stores
    ///   (kept out of the store so it stays trivially test-injectable).
    public func assembleFHIR(
        periodDays: Int,
        snapshot: DoctorReportSpecBuilder.Snapshot,
        generatedAt: Date,
        isBackendReachable: Bool
    ) async -> FHIRAssemblyOutcome {
        // Prefer the server-canonical `$everything` Bundle when reachable; a
        // fetch that throws (network hiccup, 429, decode) falls through to the
        // local emitter so the export never dead-ends.
        if FHIRExportSource.preferred(isBackendReachable: isBackendReachable) == .server {
            do {
                // The service combines all `$everything` pages and encodes to
                // JSON inside the actor, so only Sendable bytes (+ the entry
                // count) cross back.
                let bundle = try await ServerFHIREverythingService(api: api).fetchEverything()
                if bundle.isEmpty {
                    return await .empty(hasSavedSelection: hasSavedReportSelection())
                }
                return .assembled(FHIRAssembly(json: bundle.json, source: .server))
            } catch let err as HLError where err.isModuleDisabled {
                // **Server brief #56 (backend v1.30.19).** `/api/fhir/*` now
                // returns `403 module.disabled` when the doctor-report module is
                // off; it used to serve the full bundle — insurance number
                // included — regardless of the switch.
                //
                // A 403 here is a DECISION, not a transport hiccup. Falling
                // through to the local emitter would rebuild locally exactly the
                // bundle the server just refused, which would defeat the gate the
                // server introduced. So we surface the refusal instead: no
                // export, no silent downgrade.
                HLLog.api.info("FHIR $everything refused — doctor-report module is off; not falling back to local")
                return .unavailable
            } catch {
                // Transport hiccup / 429 / decode: falling back is safe and keeps
                // the export from dead-ending.
                HLLog.api.info("FHIR $everything fetch failed — falling back to local emitter")
            }
        }

        // Fetch the gated clinical surfaces (labs / illness) so the local
        // bundle carries them too. Each is gated by its module and fails soft.
        let labs = await fetchLabsBlock()
        let illnesses = await fetchIllnessBlock()
        guard let json = Self.makeLocalBundleJSON(
            periodDays: periodDays,
            snapshot: snapshot,
            generatedAt: generatedAt,
            labs: labs,
            illnesses: illnesses
        ) else {
            return .unavailable
        }
        return .assembled(FHIRAssembly(json: json, source: .local))
    }

    /// Does this account have a saved report selection at all?
    ///
    /// CU-13 couples the empty-Bundle hint to the actual state instead of
    /// guessing it from the empty result: the server scopes
    /// `Patient/$everything` to the profile behind
    /// `GET /api/auth/me/report-selection`, and `profile == nil` is the honest
    /// "never saved one" answer — the one cause the user can act on.
    ///
    /// Reuses CU-11's ``ReportSelectionRepository`` (the same route the
    /// doctor-report panel reads), so there is exactly one idea of the saved
    /// scope in the app.
    ///
    /// A failed read answers `true`, i.e. "don't claim they never saved one".
    /// Telling a user to go save a selection they already have would send them
    /// on an errand that fixes nothing; the generic empty-Bundle wording stays
    /// true either way.
    private func hasSavedReportSelection() async -> Bool {
        do {
            return try await ReportSelectionRepository(api: api).fetch() != nil
        } catch {
            HLLog.api.info("FHIR export: report-selection read failed — not claiming an unsaved selection")
            return true
        }
    }

    /// Fetch the lab results for the FHIR bundle when the `labs` module is on.
    /// Returns `nil` when the module is off or empty; a fetch error fails soft
    /// (PII-free log, `nil`) so the export proceeds.
    private func fetchLabsBlock() async -> DoctorReportSpec.LabsBlock? {
        guard moduleGate.isEnabled(.labs) else { return nil }
        let repo = LabsRepository(api: api, outbox: outbox)
        do {
            let response = try await repo.labs(limit: 500)
            return response.results.isEmpty ? nil : DoctorReportSpec.LabsBlock(results: response.results)
        } catch {
            HLLog.api.info("FHIR export: labs fetch failed — omitting labs section")
            return nil
        }
    }

    /// Fetch illness episodes (+ their day-logs) for the FHIR bundle when the
    /// `illness` module is on. Fails soft like ``fetchLabsBlock``.
    private func fetchIllnessBlock() async -> DoctorReportSpec.IllnessBlock? {
        guard moduleGate.isEnabled(.illness) else { return nil }
        let repo = IllnessRepository(api: api, outbox: outbox)
        do {
            let episodes = try await repo.episodes(limit: 100, includeResolved: true)
            guard !episodes.isEmpty else { return nil }
            var dayLogsByEpisode: [String: [IllnessDayLogDTO]] = [:]
            for episode in episodes {
                if let list = try? await repo.dayLogs(episodeId: episode.id, limit: 200), !list.dayLogs.isEmpty {
                    dayLogsByEpisode[episode.id] = list.dayLogs
                }
            }
            return DoctorReportSpec.IllnessBlock(episodes: episodes, dayLogsByEpisode: dayLogsByEpisode)
        } catch {
            HLLog.api.info("FHIR export: illness fetch failed — omitting conditions section")
            return nil
        }
    }

    // Build + encode the iOS-local FHIR Bundle from the in-memory store
    // snapshot — the offline / standalone fallback. Folds in the gated labs /
    // illness blocks (already module-checked + fetched by the caller). Returns
    // `nil` if the local emitter or encode throws. Implemented in
    // `ExportStore+FHIR.swift` (`makeLocalBundleJSON`) — see that file's note on
    // why the ModelsR4-typed helpers are split out.

    // MARK: - PHI write

    /// **Phase 09 / plan 09-03 — the awaited export write.**
    ///
    /// The bytes leave the main actor, land atomically under complete file
    /// protection, and only then does the share URL come back to be published.
    /// The cancellation check sits *after* the write and *before* the return: a
    /// user who left the export surface while a 250 MiB backup was being written
    /// gets the file cleaned up by the temp sweeper rather than a share sheet
    /// they no longer asked for.
    func persistExport(data: Data, filename: String) async throws -> URL {
        let url = try await persistence.persist(data: data, filename: filename)
        try Task.checkCancellation()
        return url
    }

    /// The same boundary for the assembled FHIR bundle. See ``persistExport(data:filename:)``.
    func persistFHIR(_ data: Data, generatedAt: Date) async throws -> URL {
        let url = try await persistence.writeFHIR(data, generatedAt: generatedAt)
        try Task.checkCancellation()
        return url
    }

    /// Write already-encoded FHIR JSON bytes to the temp dir under
    /// `.completeFileProtection`. Shared by the server-`$everything` path (which
    /// encodes inside the actor and hands back `Data`) and the local emitter, so
    /// both honour the exact same PHI-write contract.
    ///
    /// `nonisolated` since 09-03: this is the one implementation of the
    /// protected export write, and ``ExportPersistence`` has to be able to run
    /// it on its own executor rather than hopping back to the main actor to do
    /// the blocking part.
    nonisolated static func writeData(
        _ data: Data,
        generatedAt: Date,
        writer: ExportPersistenceWriter = .live
    ) throws -> URL {
        let stamp = fhirStamp(generatedAt)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("healthlog-fhir-\(stamp)")
            .appendingPathExtension("fhir.json")
        // PHI write — the FHIR bundle carries health observations, so it must
        // land under `.completeFileProtection` to match every sibling export
        // path. Without it the bytes stay readable after first unlock (forensic
        // extraction window) — a defence-in-depth regression vs. the rest of the
        // app.
        try HLPerfSignpost.measure(.exportPersist, magnitude: .of(byteCount: data.count)) {
            try writer.write(data, to: url, options: [.atomic, .completeFileProtection])
        }
        return url
    }

    /// Persist already-downloaded export bytes under complete file protection
    /// with a caller-supplied filename. Central write seam for the backup / CSV
    /// / package surfaces. `nonisolated` for the reason given on ``writeData(_:generatedAt:writer:)``.
    nonisolated static func persist(
        data: Data,
        filename: String,
        writer: ExportPersistenceWriter = .live
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try HLPerfSignpost.measure(.exportPersist, magnitude: .of(byteCount: data.count)) {
            try writer.write(data, to: url, options: [.atomic, .completeFileProtection])
        }
        return url
    }

    /// `yyyyMMdd-HHmmss` stamp for the FHIR temp filename, in the device's own
    /// time zone — byte-identical to the `en_US_POSIX` `DateFormatter` this
    /// replaced (`ExportStoreTests.fhirStampMatchesTheFormatterItReplaced` runs
    /// both against the same instants and compares the strings).
    ///
    /// **Why not the cached formatter (v0162 perf).** A `DateFormatter` is a
    /// reference type, so a shared static one cannot be `nonisolated` without an
    /// unchecked-`Sendable` escape hatch, and 09-03 has to run this off the main
    /// actor. Rebuilding a formatter per write would undo the v0162 hoist, so
    /// the stamp is computed from `DateComponents` instead: value types
    /// throughout, no shared mutable state, no allocation to hoist.
    nonisolated static func fhirStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    /// `yyyy-MM-dd` day stamp for the full-backup filename (matches the former
    /// in-card `Date.now.formatted(.iso8601.year().month().day())`).
    nonisolated static func dayStamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    // MARK: - Apple Health import

    /// UI flow state machine for the one-shot Apple Health Export ZIP import.
    /// `.uploading` / `.polling` carry the live snapshot for progress display;
    /// `.done` / `.failed` are terminal. The view renders from ``importPhase``.
    public enum ImportPhase: Equatable {
        case idle
        case uploading
        case polling(AppleHealthImportStatusDTO)
        case done(AppleHealthImportStatusDTO)
        case failed(String)
    }

    /// The live import phase — drives the Apple-Health-import screen.
    public private(set) var importPhase: ImportPhase = .idle

    private var pollTask: Task<Void, Never>?

    /// Reset the import surface back to idle (the "Import another" affordance).
    public func resetImport() {
        importPhase = .idle
    }

    /// Cancel any in-flight upload/poll (view `onDisappear`).
    public func cancelImport() {
        pollTask?.cancel()
    }

    /// Drive the upload → poll → terminal import flow from a picked `export.zip`.
    /// Owns the poll task and the terminal mapping; publishes progress through
    /// ``importPhase``.
    ///
    /// **Phase 09 / plan 09-02 — the security scope moved out of here.** This
    /// wrapper used to hold `startAccessingSecurityScopedResource()` for the
    /// whole `upload` **plus** `poll` span, which for a 1.5 GiB archive is a
    /// multi-minute hold on somebody else's file provider — long after the last
    /// byte of theirs was needed. ``AppleHealthImportService`` now owns the
    /// scope for exactly the copy that consumes it and releases it before the
    /// upload begins, on success, error and cancellation alike.
    public func startAppleHealthImport(fileURL: URL) {
        pollTask?.cancel()
        importPhase = .uploading

        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let service = AppleHealthImportService(api: api)
            do {
                let kickoff = try await service.upload(fileURL: fileURL)
                let terminal = try await service.poll(jobId: kickoff.jobId) { [weak self] snapshot in
                    Task { @MainActor in self?.applyPollSnapshot(snapshot) }
                }
                switch terminal.status {
                case .done:
                    importPhase = .done(terminal)
                case .failed:
                    importPhase = .failed(
                        terminal.failureReason
                            ?? String(localized: "settings.applehealth_import.error_generic")
                    )
                default:
                    importPhase = .failed(String(localized: "settings.applehealth_import.error_generic"))
                }
            } catch is CancellationError {
                // User navigated away — leave state as-is.
            } catch AppleHealthImportError.timedOut {
                importPhase = .failed(String(localized: "settings.applehealth_import.error_timeout"))
            } catch let err as HLError {
                importPhase = .failed(err.userFacingDescription)
            } catch {
                importPhase = .failed(String(localized: "settings.applehealth_import.error_generic"))
            }
        }
    }

    /// Reflect a live poll snapshot, but never clobber a terminal state if a
    /// late snapshot lands after done/failed.
    private func applyPollSnapshot(_ snapshot: AppleHealthImportStatusDTO) {
        switch importPhase {
        case .uploading, .polling:
            importPhase = .polling(snapshot)
        case .idle, .done, .failed:
            break
        }
    }
}

/// **Phase 09 Wave 0 — the export byte-write seam.**
///
/// Both PHI writes above are `@MainActor`-reachable synchronous `Data.write`
/// calls today, and Plan 09-03 moves them off the main actor. Moving a write is
/// only provable if a test can count the writes and see which thread they landed
/// on, and `Data.write` offers nowhere to stand. This indirection is that place.
///
/// It deliberately keeps the `options:` argument at the call site rather than
/// baking the protection class in here: the protection class is a security
/// decision that belongs next to the bytes it protects, a source-level guard in
/// `SettingsFHIRExportScreenTests` pins the literal in this file, and a seam
/// that silently chose the class for its callers would be exactly the kind of
/// indirection that lets a protection regression hide.
struct ExportPersistenceWriter: Sendable {
    private let handler: @Sendable (Data, URL, Data.WritingOptions) throws -> Void

    init(_ handler: @escaping @Sendable (Data, URL, Data.WritingOptions) throws -> Void) {
        self.handler = handler
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try handler(data, url, options)
    }

    /// Production default — the same `Data.write` the store called inline.
    static let live = ExportPersistenceWriter { data, url, options in
        try data.write(to: url, options: options)
    }
}
