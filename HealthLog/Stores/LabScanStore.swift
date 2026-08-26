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
    var referenceLow: String
    var referenceHigh: String
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
            return hasName && LocaleDecimalParser.parse(value) != nil
        case .qualitative:
            return hasName && !qualitativeText.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    init(candidate: LabScanCandidate, biomarkerId: String?, isLowConfidence: Bool) {
        analyte = candidate.analyte
        resultType = candidate.isQualitative ? .qualitative : .numeric
        value = candidate.value.map { Self.editableNumber($0) } ?? ""
        qualitativeText = candidate.valueText ?? ""
        unit = candidate.unit ?? ""
        referenceLow = candidate.referenceLow.map { Self.editableNumber($0) } ?? ""
        referenceHigh = candidate.referenceHigh.map { Self.editableNumber($0) } ?? ""
        self.biomarkerId = biomarkerId
        self.isLowConfidence = isLowConfidence
        rawLine = candidate.rawLine
    }

    /// Render a parsed number back into the user's locale so the review field
    /// shows "7,4" on a German phone and "7.4" on an English one — the field is
    /// read back through `LocaleDecimalParser`, so the two must agree.
    private static func editableNumber(_ value: Double) -> String {
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

        var messageKey: String {
            switch self {
            case .camera: "labs.scan.error.camera"
            case .load: "labs.scan.error.load"
            case .noText: "labs.scan.error.noText"
            case .noRows: "labs.scan.error.noRows"
            case .platform: "labs.scan.error.platform"
            case .generic: "labs.scan.error.generic"
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
            guard !lines.isEmpty else {
                report(.noText)
                return
            }
            ingest(lines: lines)
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
        failure = nil
        step = .review
    }

    /// Abandon the parsed batch and go back to the source chooser.
    func retake() {
        rows = []
        failure = nil
        saveSummary = nil
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

    /// Map one reviewed row onto the create body. A linked row sends only the
    /// biomarker id + result (the server resolves analyte / unit / range); a
    /// free-text row sends its own fields.
    ///
    /// `source: "OCR"` is the provenance marker the server has accepted since
    /// v1.25 and that the client never produced until now.
    static func body(for row: LabScanRow, takenAt: String) -> LabResultCreate {
        let numeric: Double?
        let qualitative: String?
        switch row.resultType {
        case .numeric:
            numeric = LocaleDecimalParser.parse(row.value)
            qualitative = nil
        case .qualitative:
            numeric = nil
            qualitative = row.qualitativeText.trimmingCharacters(in: .whitespaces)
        }
        if let biomarkerId = row.biomarkerId {
            return LabResultCreate(
                biomarkerId: biomarkerId,
                value: numeric,
                valueText: qualitative,
                takenAt: takenAt,
                source: "OCR"
            )
        }
        let unit = row.unit.trimmingCharacters(in: .whitespaces)
        return LabResultCreate(
            analyte: row.analyte.trimmingCharacters(in: .whitespaces),
            value: numeric,
            valueText: qualitative,
            unit: unit.isEmpty ? nil : unit,
            referenceLow: LocaleDecimalParser.parse(row.referenceLow),
            referenceHigh: LocaleDecimalParser.parse(row.referenceHigh),
            takenAt: takenAt,
            source: "OCR"
        )
    }

    // MARK: - Analyte matching

    /// Resolve an OCR'd analyte name against the user's biomarker catalog.
    ///
    /// Tier 1 — an exact (case/diacritic-insensitive) name match on a catalog
    /// marker: link it, and the server owns unit + range.
    /// Tier 2 — no catalog marker, but the name maps onto a known catalogue
    /// slug: keep it free-text but rewrite the analyte to the slug's canonical
    /// display name so repeated scans of the same panel converge on one name.
    static func match(analyte: String, in catalog: [BiomarkerDTO]) -> (biomarkerId: String?, canonicalName: String?) {
        let needle = normalize(analyte)
        guard !needle.isEmpty else { return (nil, nil) }
        if let exact = catalog.first(where: { normalize($0.name) == needle }) {
            return (exact.id, nil)
        }
        guard let slug = BiomarkerExplainer.slug(forName: analyte) else { return (nil, nil) }
        if let viaSlug = catalog.first(where: { BiomarkerExplainer.slug(forName: $0.name) == slug }) {
            return (viaSlug.id, nil)
        }
        return (nil, BiomarkerExplainer.canonicalDisplayName(forSlug: slug))
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
            rows[index].isDuplicate = existing.contains(key) || !seen.insert(key).inserted
        }
    }

    private static func normalize(_ raw: String) -> String {
        raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
