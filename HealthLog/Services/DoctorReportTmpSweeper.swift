import Foundation

/// **v0.7.0 W-SEC-M-1 — Doctor-report tmpdir residue sweeper.**
///
/// Doctor-report PDFs (server-rendered + locally-rendered) and the
/// co-emitted FHIR JSON Documents are written to
/// `FileManager.default.temporaryDirectory` with `.completeFileProtection`.
/// The `DoctorReportStore` / `LocalDoctorReportStore` lifecycles only
/// remove the *previous* artifact on the *next* render — if the user
/// generates one report, never generates a second, never explicitly
/// logs out, and the app remains installed for weeks, the PDF sits in
/// tmp indefinitely.
///
/// iOS *does* purge `temporaryDirectory` on its own schedule
/// ("opportunistically", per Apple docs — typically when storage is
/// low or on update), but that's not a contract we can lean on for a
/// PHI-bearing artifact. The local doctor-report contains the
/// patient name (cover), every measurement in the period, every
/// medication + adherence row, and every mood entry — i.e. the full
/// shape of a clinical handoff. PHI residue with `.completeFileProtection`
/// is still PHI residue.
///
/// `sweep(...)` deletes every matching file older than `ttl` seconds.
/// Wired into:
///
///  * `AppContainer.handleLocalLogout` — wipe-all (ttl = 0).
///  * `AppContainer.localCleanupHook` (account-deletion) — wipe-all.
///  * `RootView.handle(scenePhase:)` `.active` branch — 24h sweep.
///
/// Pattern coverage:
///  * `healthlog-report-*.pdf`         — server-rendered (legacy)
///  * `healthlog-doctor-report-*.pdf`  — `DoctorReportRenderer.persist`
///  * `healthlog-fhir-*.fhir.json`     — `DoctorReportFHIRWriter`
///
/// Conservative on naming drift: any future filename that does not
/// match one of those prefixes is left alone. Add prefixes here when
/// new artifact pipelines land.
public enum DoctorReportTmpSweeper {
    /// Default time-to-live for `.active` scenePhase sweeps. 24 hours
    /// is long enough that a doctor-visit walkthrough (operator renders
    /// the PDF at home, takes the iPhone to the appointment, shares
    /// from the same tmpdir-URL via AirDrop) does not have the file
    /// yanked out from under the share-sheet, and short enough that
    /// residue does not accumulate across multiple non-overlapping
    /// renders.
    public static let defaultTTL: TimeInterval = 24 * 60 * 60

    /// Filename prefixes the sweeper owns. Drift here is a security
    /// hole — sync this list with `DoctorReportStore.persist`,
    /// `DoctorReportRenderer.persist`, and `DoctorReportFHIRWriter.write`
    /// whenever any of the three changes its naming scheme.
    public static let ownedPrefixes: [String] = [
        "healthlog-report-",
        "healthlog-doctor-report-",
        "healthlog-fhir-",
        // v0.11 W9 — per-domain CSV exports (`ExportService` → persisted in
        // `SettingsExportScreen`). Same PHI-residue concern: the CSVs carry the
        // full measurement / mood / medication-intake history.
        "healthlog-measurements-",
        "healthlog-mood-",
        "healthlog-medications-",
        // v0.14.2 FW5-A — unified health-record export package
        // (`ExportService.downloadHealthRecordPackage` → persisted in
        // the unified sharing surface). The ZIP carries report.pdf + FHIR
        // bundle.json — the full clinical-handoff PHI shape, same residue
        // concern as the doctor-report artifacts.
        "healthlog-health-record-"
    ]

    /// Deletes every owned artifact in `temporaryDirectory` whose
    /// modification time is older than `now - ttl`. Returns the URLs
    /// that were removed (for tests + logging). Failures are silently
    /// dropped — sweep is best-effort and the cost of "delete failed"
    /// is bounded by the next sweep tick.
    ///
    /// - Parameters:
    ///   - now: clock injection point for tests. Production passes `.now`.
    ///   - ttl: residue older than this is removed. Pass `0` to wipe
    ///          every owned file unconditionally (logout / account-
    ///          deletion path).
    ///   - directory: tmp directory. Tests can pass an isolated path.
    ///   - fileManager: injection seam.
    @discardableResult
    public static func sweep(
        now: Date = .now,
        ttl: TimeInterval = defaultTTL,
        directory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-ttl)
        var removed: [URL] = []
        for url in entries {
            let name = url.lastPathComponent
            guard ownedPrefixes.contains(where: name.hasPrefix) else { continue }
            // ttl == 0 means "no age gate" — wipe everything we own.
            if ttl > 0 {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let mtime = values?.contentModificationDate else {
                    // No mtime? Be conservative — skip. We'd rather
                    // leave a file than yank a freshly-written one
                    // whose attribute hasn't materialised yet.
                    continue
                }
                guard mtime < cutoff else { continue }
            }
            do {
                try fileManager.removeItem(at: url)
                removed.append(url)
            } catch {
                // Best-effort — fall through.
                continue
            }
        }
        return removed
    }
}
