import Foundation
import SwiftData

/// Shared non-trapping floor for the SwiftData `makeWithRecovery()` ladders
/// (`OutboxQueue`, `SWRCache`, `LocalRepository`, `GLP1LocalRepository`,
/// `CoachChatStore`).
///
/// Audit M2: those recovery paths previously closed with `try!` on the
/// in-memory `ModelContainer` build. In-memory creation effectively never
/// throws, but a `try!` on the *exact path that exists to avoid a hard launch
/// failure* defeats its own purpose — a schema-init OOM (or any future SwiftData
/// quirk) would hard-trap at launch.
///
/// `recoveredInMemoryContainer` replaces that `try!` with a two-stage degrade:
///
///   1. Build the in-memory container for the store's real schema.
///   2. If that throws, log `.fault` and fall back to an **empty-schema**
///      (`Schema([])`) in-memory container — the minimal possible SwiftData
///      store, which carries no migration/model surface to fail on.
///
/// Stage 2 returning a container with none of the store's models means the
/// store's fetches resolve to empty and its inserts/saves throw — but every
/// caller of these stores already swallows operation-level errors (fetch → `[]`,
/// insert/clear → log + continue). So a stage-2 floor degrades to a *disabled*
/// store, never a crash. The app stays alive; the affected offline subsystem is
/// inert until the next clean launch, which is strictly better than trapping.
///
/// The empty-schema build is itself wrapped: in the (astronomically unlikely)
/// event SwiftData cannot even open an empty in-memory store, we surface a
/// descriptive `preconditionFailure` so a crash log is actionable — but this is
/// not reachable in practice and is never hit on the happy path.
enum ModelContainerRecovery {
    /// Builds an in-memory `ModelContainer` for the supplied schema, degrading
    /// to an empty-schema in-memory container (logged at `.fault`) rather than
    /// trapping if the primary build throws. Never returns an optional —
    /// callers keep their non-optional `container` field unchanged.
    ///
    /// - Parameters:
    ///   - log: the subsystem logger to record a `.fault` on degrade.
    ///   - subsystem: short label for the fault line (e.g. `"Outbox"`).
    ///   - build: the store's own `makeInMemory()` factory.
    static func recoveredInMemoryContainer(
        log: HLLogger,
        subsystem: String,
        build: () throws -> ModelContainer
    ) -> ModelContainer {
        do {
            return try build()
        } catch {
            log.fault(
                "\(subsystem) in-memory fallback failed to build its schema — degrading to an empty inert store: \(LogSanitizer.redact(String(describing: error)))"
            )
            do {
                return try ModelContainer(
                    for: Schema([]),
                    configurations: [
                        ModelConfiguration(isStoredInMemoryOnly: true)
                    ]
                )
            } catch {
                // Unreachable in practice: an empty-schema in-memory store has
                // no model/migration surface to fail on. A descriptive
                // precondition makes the crash log actionable if it ever fires.
                preconditionFailure(
                    "\(subsystem): even an empty in-memory ModelContainer could not be built — SwiftData runtime is unusable: \(error)"
                )
            }
        }
    }

    // MARK: - W-INTEGRITY-WRITEPATH G-9 — corrupt-vs-unavailable classification

    /// Why a persistent store open failed, for the recovery ladder to decide
    /// between *fail-soft* (retry later, **destroy nothing**) and *move-aside*
    /// (rename the corrupt file so the data is recoverable forensically and a
    /// clean store can be created next time).
    enum StoreOpenFailure: Equatable {
        /// Transient / recoverable: the bytes are (almost certainly) fine, the
        /// store just could not be opened **right now** — most commonly a
        /// `BGProcessingTask` wake before first device unlock, where the
        /// `completeUntilFirstUserAuthentication`-protected SQLite file is
        /// unreadable, or a lock/permission hiccup. Deleting on this path is the
        /// G-9 bug: it irreversibly destroys un-synced writes that would have
        /// opened fine on the next foreground launch.
        case transient
        /// Genuine corruption: the file exists and is readable, but SwiftData /
        /// Core Data / SQLite rejects its contents (malformed db, incompatible
        /// schema with no migration path). Here the store cannot be salvaged in
        /// place — move it aside (rename, never `rm`) so a fresh store opens and
        /// the old bytes survive for post-mortem / manual recovery.
        case corrupt
    }

    /// Classify a persistent-store open failure as `transient` vs `corrupt`.
    ///
    /// Heuristic (deliberately conservative — when in doubt, prefer `transient`
    /// so we never destroy data):
    ///
    ///   * **No file on disk** → `transient`. There is nothing to corrupt or
    ///     move aside; the open failed for some other reason (first-run race,
    ///     directory perms) and a retry/next-launch resolves it.
    ///   * **File present but unreadable due to data protection** (we probe by
    ///     attempting to read one byte and observing an EPERM /
    ///     `NSFileReadNoPermissionError`) → `transient`. This is the
    ///     pre-first-unlock BG-wake case: the bytes are sealed, not broken.
    ///   * **File present and readable, yet the store still failed to open** →
    ///     `corrupt`. We could read the bytes but Core Data/SQLite rejected
    ///     them, which is the move-aside case.
    ///
    /// - Parameters:
    ///   - error: the error thrown by the persistent `ModelContainer` build.
    ///   - storeURL: the on-disk SQLite URL (may not exist yet).
    static func classifyOpenFailure(_ error: Error, storeURL: URL?) -> StoreOpenFailure {
        guard let storeURL else { return .transient }
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else {
            // Nothing on disk → not corruption. A retry / next launch handles it.
            return .transient
        }
        // The file exists. Probe readability: a data-protected file (sealed
        // before first unlock) throws on read with EPERM / no-permission. That
        // is the transient BG-wake case — NOT corruption. If we CAN read the
        // bytes, the store contents themselves are the problem → corrupt.
        let handle = try? FileHandle(forReadingFrom: storeURL)
        if let handle {
            defer { try? handle.close() }
            do {
                _ = try handle.read(upToCount: 1)
                // Readable bytes, but the store failed to open → genuine corruption.
                return .corrupt
            } catch {
                // Could not read despite the file existing → protection-sealed,
                // treat as transient.
                return .transient
            }
        }
        // Could not even open a read handle → most likely protection-sealed
        // (pre-first-unlock). Conservative default: transient (never delete).
        return .transient
    }

    /// Move a corrupt store **aside** (rename, never `rm`) so a clean store can
    /// be created on the next open while the original bytes survive for manual /
    /// forensic recovery. Renames the SQLite file and its `-wal` / `-shm`
    /// sidecars to a timestamped `<name>.corrupt-<epoch>.*` set. Best-effort:
    /// any per-file failure is logged and skipped (a partial move-aside is still
    /// strictly better than a destructive delete).
    ///
    /// - Returns: `true` if the primary store file was moved aside.
    @discardableResult
    static func moveAsideCorruptStore(at storeURL: URL, log: HLLogger, subsystem: String) -> Bool {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let base = storeURL.deletingPathExtension().lastPathComponent
        let dir = storeURL.deletingLastPathComponent()
        var movedPrimary = false
        let exts = ["sqlite", "sqlite-wal", "sqlite-shm"]
        for ext in exts {
            let src = dir.appendingPathComponent("\(base).\(ext)")
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dir.appendingPathComponent("\(base).corrupt-\(stamp).\(ext)")
            do {
                try fm.moveItem(at: src, to: dst)
                if ext == "sqlite" { movedPrimary = true }
            } catch {
                log.error(
                    "\(subsystem): move-aside of \(ext) sidecar failed: \(LogSanitizer.redact(String(describing: error)))"
                )
            }
        }
        return movedPrimary
    }
}
