import Foundation

/// **Phase 09 / plan 09-03 — the protected export write boundary.**
///
/// Every PHI export the app produces — the full backup, a per-domain CSV, the
/// health-record ZIP, the encrypted `HLX1` archive, the FHIR bundle — ends in
/// one atomic `Data.write` under `.completeFileProtection`. Those writes used to
/// happen on the main actor, inside `ExportStore`, because the store is
/// `@MainActor` for its UI state and the write was a plain synchronous call. A
/// multi-megabyte protected atomic write is a blocking file operation, and a
/// blocking file operation on the main thread is a dropped frame at best.
///
/// This owns the bytes-to-disk step and nothing else. It is deliberately *not*
/// where the protection class is chosen: the `options` travel from the call site
/// (see the note on ``ExportPersistenceWriter``), so a seam that quietly picked
/// a weaker class for its callers cannot exist here.
///
/// **An `actor`, so the write has somewhere to be that is not the main one.**
/// Serialization is a side benefit rather than the point: two exports cannot
/// interleave their bytes anyway, since each writes its own uniquely named file.
/// What the actor buys is an executor of its own — the caller `await`s, the main
/// actor is free while the bytes land, and the share URL is published afterwards.
actor ExportPersistence {
    private let writer: ExportPersistenceWriter

    /// - Parameter writer: the byte-write seam (09-01). The live default is the
    ///   same `Data.write` the store called inline; tests pass a counting writer
    ///   that records the byte count, the options and the originating thread.
    init(writer: ExportPersistenceWriter = .live) {
        self.writer = writer
    }

    /// Persist downloaded export bytes under a caller-supplied filename.
    ///
    /// The write itself, its `export.persist` interval and — crucially — its
    /// `.completeFileProtection` literal stay in ``ExportStore/persist(data:filename:writer:)``.
    /// There is exactly one implementation of the protected export write in the
    /// app, and it is the one a source guard pins; this boundary decides *where*
    /// it runs, never *what it promises*.
    func persist(data: Data, filename: String) throws -> URL {
        try ExportStore.persist(data: data, filename: filename, writer: writer)
    }

    /// Persist already-encoded FHIR bundle bytes. Same contract as ``persist(data:filename:)``.
    func writeFHIR(_ data: Data, generatedAt: Date) throws -> URL {
        try ExportStore.writeData(data, generatedAt: generatedAt, writer: writer)
    }
}
