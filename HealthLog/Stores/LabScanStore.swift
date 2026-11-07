import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

/// One reviewable row in the lab-scan review screen.
///
/// Every field is a **string** rather than a parsed value, because this is an
/// editing surface: the user retypes what the OCR got wrong, and a half-typed
/// "7," must survive a keystroke without collapsing to `nil`. Parsing back to
/// numbers happens once, at commit.
///
/// ``idempotencyKey`` is minted ONCE, when the row is created from the scan —
/// not at save time. That is the whole point of the previously-dead
/// `LabsRepository.createLab(idempotencyKey:)` seam: if a batch of 14 rows
/// partially fails and the user taps Save again, the 6 rows that already
/// reached the server are re-POSTed under their ORIGINAL keys and the server
/// dedupes them, instead of landing a second copy.
struct LabScanRow: Identifiable {
    let id = UUID()
    /// Rows start included; the user switches off anything they don't want.
    var isIncluded = true
    var analyte: String
    var resultType: LabResultType
    /// The numeric reading as an editable string.
    var value: String
    /// The qualitative reading ("negativ") as an editable string.
    var qualitativeText: String
    var unit: String
    /// #160 — the person switched on "No unit" (the unity `"1"`). Never
    /// set by the scan itself: only a person asserts that a value has no unit.
    var noUnit = false
    var referenceLow: String
    var referenceHigh: String
    /// LAB-OCR — the reference window exactly as the report printed it, from a
    /// server read; sent back on commit so a worded range is not lost.
    var referenceText: String?
    /// LAB-OCR — the unit the matched marker is tracked in (server read).
    var markerUnit: String?
    /// LAB-OCR — a server commit needs a unit on every numeric reading.
    var requiresUnit = false
    /// Set when the analyte resolved to a marker in the user's catalog — then
    /// the server resolves unit + range and the local fields are read-only.
    var biomarkerId: String?
    /// The OCR/parse was structurally weak — surfaced as `labs.scan.flag.lowConfidence`.
    var isLowConfidence: Bool
    /// Another row in this batch (or an already-stored result on the same day)
    /// carries the same analyte — surfaced as `labs.scan.flag.duplicate`.
    var isDuplicate = false
    /// The verbatim OCR line, shown under the row so the user can compare
    /// against the paper.
    let rawLine: String
    /// Stable across retries — see the type doc.
    let idempotencyKey = IdempotencyKey()

    var isLinked: Bool {
        biomarkerId != nil
    }

    /// A row is committable when it has an analyte (or a catalog link) and a
    /// result of the selected kind.
    var isCommittable: Bool {
        let hasName = isLinked || !analyte.trimmingCharacters(in: .whitespaces).isEmpty
        switch resultType {
        case .numeric:
            let hasUnit = !requiresUnit || LabUnit.wire(typed: unit, noUnit: noUnit) != nil || markerUnit != nil
            return hasName && hasUnit && LocaleDecimalParser.parse(value) != nil
        case .qualitative:
            return hasName && !qualitativeText.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    init(candidate: LabScanCandidate, biomarkerId: String?, isLowConfidence: Bool) {
        analyte = candidate.analyte
        resultType = candidate.isQualitative ? .qualitative : .numeric
        value = candidate.value.map { Self.editableNumber($0) } ?? ""
        qualitativeText = candidate.valueText ?? ""
        // #160 — a bare "1" read off the page is not a person saying "no
        // unit". The field starts empty and the row is flagged for a look,
        // so nothing goes out as the unity unless the switch is turned on.
        let readUnity = LabUnit.isUnity(candidate.unit)
        unit = readUnity ? "" : candidate.unit ?? ""
        referenceLow = candidate.referenceLow.map { Self.editableNumber($0) } ?? ""
        referenceHigh = candidate.referenceHigh.map { Self.editableNumber($0) } ?? ""
        self.biomarkerId = biomarkerId
        self.isLowConfidence = isLowConfidence || readUnity
        rawLine = candidate.rawLine
    }

    /// Render a parsed number back into the user's locale so the review field
    /// shows "7,4" on a German phone and "7.4" on an English one — the field is
    /// read back through `LocaleDecimalParser`, so the two must agree.
    static func editableNumber(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0 ... 4)))
    }
}

/// `@MainActor @Observable` store driving the lab-report scan flow:
/// **scan → recognise → parse → review → batch commit**.
///
/// **Everything before the commit is on-device.** VisionKit captures the page,
/// Vision recognises the text, ``LabReportParser`` extracts candidate rows. No
/// server round-trip, no external AI, and therefore no consent gate — the AI
/// consent receipt (`AppContainer+AIConsentGate`) governs calls that leave the
/// device, and this flow makes none. Only the rows the user explicitly keeps
/// are written, through the normal `LabsStore` → `LabsRepository` → Outbox path.
///
/// **The review step is the feature.** OCR misreads decimal separators and
/// confuses units routinely; committing parsed readings without a human pass
/// would inject wrong numbers into a health record. So ``rows`` is editable and
/// individually rejectable, and ``commit()`` writes nothing that the user did
/// not leave switched on.
@MainActor
@Observable
final class LabScanStore {
    /// Where the flow currently is. The sheet renders one step per case.
    enum Step: Equatable {
        /// Pick a source (camera / photo library).
        case chooser
        /// OCR + parse running.
        case processing
        /// Rows parsed — the user reviews, edits, rejects.
        case review
        /// Batch commit in flight.
        case saving
    }

    /// A user-facing failure. Each maps to one of the pre-translated
    /// `labs.scan.error.*` strings.
    enum Failure: Equatable {
        case camera
        case load
        case noText
        case noRows
        case platform
        case generic
        /// LAB-OCR — a server read ended without rows; its own sentence.
        case server(LabsOCRFailure)

        var messageKey: String {
            switch self {
            case .camera: "labs.scan.error.camera"
            case .load: "labs.scan.error.load"
            case .noText: "labs.scan.error.noText"
            case .noRows: "labs.scan.error.noRows"
            case .platform: "labs.scan.error.platform"
            case .generic: "labs.scan.error.generic"
            case let .server(failure): failure.messageKey
            }
        }

        /// The already-localized message for this failure.
        var message: String {
            String(localized: String.LocalizationValue(messageKey))
        }
    }

    private(set) var step: Step = .chooser
    private(set) var failure: Failure?
    /// The reviewable rows. `var` (not `private(set)`) because the review screen
    /// binds directly into each row's fields — that IS the editing surface.
    var rows: [LabScanRow] = []
    /// One sample date for the whole report (`labs.scan.review.batchDate`). A
    /// paper panel is one blood draw; asking per row would be absurd.
    var takenAt = Date.now
    /// The upper bound for the date picker — a draw cannot be in the future.
    let takenAtBound = Date.now
    /// Set after a partial batch commit: the already-localized summary.
    private(set) var saveSummary: String?

    /// LAB-OCR — where the rows came from. A server read commits through
    /// `POST /api/labs/ocr/commit`; an on-device read row by row as before.
    enum Origin: Equatable {
        case device
        case server
    }

    private(set) var origin: Origin = .device
    /// LAB-OCR — the limits a server read ran into, one calm line each.
    private(set) var readLimits: [LabsOCRLimitLine] = []
    /// LAB-OCR — set by the sheet when the server can read reports.
    var ocrRepository: LabsOCRRepository?
    /// One commit key per body, so saving the same rows again reuses it.
    private var commitKeys: [LabsOCRCommitRequest: IdempotencyKey] = [:]

    private let labsStore: LabsStore
    private let ocr: MedicationOCRService

    /// - Parameters:
    ///   - labsStore: the surface's existing store — the commit goes through it
    ///     so optimistic insert, Outbox enqueue, and the threshold nudge all
    ///     behave exactly as they do for a hand-entered value.
    ///   - ocr: the shared on-device text recogniser. It is named for the
    ///     medication-package flow it shipped for, but it is a plain
    ///     `VNRecognizeTextRequest` wrapper configured de-DE + en-US — exactly
    ///     what a German lab report needs. Reusing it beats a copy that would
    ///     drift.
    init(labsStore: LabsStore, ocr: MedicationOCRService = MedicationOCRService()) {
        self.labsStore = labsStore
        self.ocr = ocr
    }

    var includedCount: Int {
        rows.filter { $0.isIncluded && $0.isCommittable }.count
    }

    var canCommit: Bool {
        step == .review && includedCount > 0
    }

    // MARK: - Scan intake

    #if canImport(UIKit)
        /// Recognise + parse the scanned pages. Called from the VisionKit
        /// callback and from the photo-library picker.
        func ingest(images: [UIImage]) async {
            guard !images.isEmpty else {
                report(.load)
                return
            }
            step = .processing
            failure = nil
            let lines = await recognisedLines(in: images)
            guard !lines.isEmpty else {
                report(.noText)
                return
            }
            ingest(lines: lines)
        }

        /// The text Vision reads off the pages, on the device. Also the input
        /// of a server read in `text` mode, where only this text leaves.
        func recognisedLines(in images: [UIImage]) async -> [String] {
            var lines: [String] = []
            for image in images {
                do {
                    let result = try await ocr.recognise(image)
                    lines.append(contentsOf: result.observations.map(\.text))
                } catch MedicationOCRError.noTextRecognised {
                    continue
                } catch {
                    HLLog.ui.error("LabScanStore: OCR failed for one page")
                    continue
                }
            }
            return lines
        }
    #endif

    /// Parse an already-recognised transcript into review rows. Split out from
    /// the image path so the parse → review wiring is exercisable without
    /// VisionKit.
    func ingest(lines: [String]) {
        let candidates = LabReportParser.parse(lines: lines)
        guard !candidates.isEmpty else {
            report(.noRows)
            return
        }
        rows = candidates.map { candidate in
            let match = Self.match(analyte: candidate.analyte, in: labsStore.biomarkers)
            var row = LabScanRow(
                candidate: candidate,
                biomarkerId: match.biomarkerId,
                isLowConfidence: candidate.needsReview
            )
            if let canonical = match.canonicalName {
                // Tier-2: the OCR'd spelling matched a catalogue slug but the
                // user has no such marker yet. Post the CANONICAL name so the
                // server mints "LDL-Cholesterin", not "LDL Chol." — which is
                // exactly what `BiomarkerExplainer.canonicalDisplayName` was
                // written for and never called with.
                row.analyte = canonical
            }
            return row
        }
        flagDuplicates()
        origin = .device
        readLimits = []
        failure = nil
        step = .review
    }

    /// LAB-OCR — a server read is under way.
    func beginServerRead() {
        failure = nil
        saveSummary = nil
        step = .processing
    }

    /// LAB-OCR — the rows a server read proposed, into the same review list.
    /// The server's own marker match wins; the local one fills the gap.
    func ingest(server result: LabsOCRExtractResult) {
        guard !result.rows.isEmpty else {
            report(.noRows)
            return
        }
        if let date = Self.reportDate(result.reportDate, notAfter: takenAtBound) { takenAt = date }
        rows = result.rows.map { proposed in
            let local = Self.match(analyte: proposed.analyte, in: labsStore.biomarkers)
            var row = LabScanRow(server: proposed, biomarkerId: proposed.biomarkerId ?? local.biomarkerId)
            if row.biomarkerId == nil, let canonical = local.canonicalName { row.analyte = canonical }
            return row
        }
        flagDuplicates()
        origin = .server
        readLimits = LabsOCRLimitLine.lines(for: result)
        failure = nil
        step = .review
    }

    /// Abandon the parsed batch and go back to the source chooser.
    func retake() {
        rows = []
        failure = nil
        saveSummary = nil
        readLimits = []
        origin = .device
        step = .chooser
    }

    /// Report a scanner-level failure (VisionKit cancel / camera error /
    /// unsupported device). Public so the view's `onError` can call it.
    func report(_ failure: Failure) {
        self.failure = failure
        step = .chooser
    }

    // MARK: - Batch commit

    /// Write every included, committable row through `LabsStore.createLab`,
    /// each under its own STABLE idempotency key.
    ///
    /// Rows that land are dropped from ``rows``; rows that fail stay, so a
    /// second tap of Save retries only those — under the same keys, so a row
    /// that actually reached the server on the first pass is deduped rather
    /// than duplicated. Returns `true` when everything landed.
    @discardableResult
    func commit() async -> Bool {
        guard step == .review else { return false }
        let batch = rows.filter { $0.isIncluded && $0.isCommittable }
        guard !batch.isEmpty else { return false }
        step = .saving
        saveSummary = nil
        if origin == .server, let ocrRepository {
            return await commitThroughServer(batch, repository: ocrRepository)
        }

        let iso = ISO8601DateFormatter()
        let takenAtISO = iso.string(from: takenAt)
        var savedIDs: Set<UUID> = []
        for row in batch {
            let ok = await labsStore.createLab(
                Self.body(for: row, takenAt: takenAtISO),
                idempotencyKey: row.idempotencyKey,
                // One list reload for the whole batch, not one per row.
                reloadAfterCreate: false
            )
            if ok { savedIDs.insert(row.id) }
        }
        await labsStore.load()

        rows.removeAll { savedIDs.contains($0.id) }
        let saved = savedIDs.count
        if saved == batch.count {
            saveSummary = String(localized: "labs.scan.saved.\(saved)")
            step = .review
            return true
        }
        saveSummary = String(localized: "labs.scan.savedPartial.\(saved).\(batch.count)")
        step = .review
        return false
    }

    /// LAB-OCR — writes the confirmed rows through `POST /api/labs/ocr/commit`
    /// (at most 400 per request). Written rows leave the list; a row the
    /// server skipped (already there, or a unit its marker cannot take) stays,
    /// switched off and flagged, so saving again does not repeat it.
    private func commitThroughServer(_ batch: [LabScanRow], repository: LabsOCRRepository) async -> Bool {
        let takenAtISO = ISO8601DateFormatter().string(from: takenAt)
        var written = 0
        var skipped: [LabsOCRCommitResult.Skipped] = []
        var sentIDs: Set<UUID> = []
        for chunk in Self.commitChunks(batch, takenAt: takenAtISO) {
            let key = commitKeys[chunk.body] ?? IdempotencyKey()
            commitKeys[chunk.body] = key
            guard let result = try? await repository.commit(chunk.body, idempotencyKey: key) else { break }
            written += result.insertedCount
            skipped += result.skipped
            sentIDs.formUnion(chunk.ids)
        }
        if written > 0 { await labsStore.load() }
        let skippedNames = Set(skipped.map { Self.normalize($0.analyte) })
        rows.removeAll { sentIDs.contains($0.id) && !skippedNames.contains(Self.normalize($0.analyte)) }
        for index in rows.indices where sentIDs.contains(rows[index].id) {
            rows[index].isIncluded = false
            rows[index].isLowConfidence = true
        }
        saveSummary = Self.serverCommitSummary(
            written: written,
            skipped: skipped.count,
            allSent: sentIDs.count == batch.count,
            batchCount: batch.count
        )
        step = .review
        return sentIDs.count == batch.count && skipped.isEmpty
    }

    /// Flag rows whose analyte repeats inside the batch, or already exists in
    /// the stored results for the chosen sample day. A flag only — the user
    /// decides; a legitimately repeated analyte (two draws, one report) exists.
    private func flagDuplicates() {
        let day = String(ISO8601DateFormatter().string(from: takenAt).prefix(10))
        let existing = Set(
            labsStore.labs
                .filter { $0.takenAt.hasPrefix(day) }
                .map { Self.normalize($0.analyte) }
        )
        var seen: Set<String> = []
        for index in rows.indices {
            let key = Self.normalize(rows[index].analyte)
            // `||`: a server read may already have flagged the row (`duplicateOf`).
            rows[index].isDuplicate = rows[index].isDuplicate || existing.contains(key) || !seen.insert(key).inserted
        }
    }

    static func normalize(_ raw: String) -> String {
        raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
