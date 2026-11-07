import Foundation

// The create bodies, the catalog match and (LAB-OCR) the server-read mapping of
// the lab-report scan, split out of `LabScanStore.swift` (type body length).

extension LabScanStore {
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
        return LabResultCreate(
            analyte: row.analyte.trimmingCharacters(in: .whitespaces),
            value: numeric,
            valueText: qualitative,
            unit: LabUnit.wire(typed: row.unit, noUnit: row.noUnit),
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

    // MARK: - LAB-OCR server read

    /// The report date a server read found, when it is a real day that is not
    /// in the future. `YYYY-MM-DD` or a full ISO instant.
    static func reportDate(_ raw: String?, notAfter bound: Date) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = full.date(from: raw) ?? fractional.date(from: raw) ?? day.date(from: String(raw.prefix(10))),
              date <= bound else { return nil }
        return date
    }

    /// The commit requests for a batch, at most 400 rows each.
    static func commitChunks(_ batch: [LabScanRow], takenAt: String) -> [(ids: [UUID], body: LabsOCRCommitRequest)] {
        let size = LabsOCRCommitRequest.maxRows
        return stride(from: 0, to: batch.count, by: size).map { start in
            let slice = batch[start ..< min(start + size, batch.count)]
            return (slice.map(\.id), LabsOCRCommitRequest(rows: slice.map { commitRow(for: $0, takenAt: takenAt) }))
        }
    }

    /// One confirmed row for `POST /api/labs/ocr/commit`. A numeric reading
    /// carries its unit: the one typed, the unity `"1"` only when the person
    /// switched "No unit" on, else (linked rows) the marker's own. A linked
    /// row names its marker and leaves the range to the catalog.
    static func commitRow(for row: LabScanRow, takenAt: String) -> LabsOCRCommitRequest.Row {
        let analyte = row.analyte.trimmingCharacters(in: .whitespaces)
        switch row.resultType {
        case .numeric:
            return LabsOCRCommitRequest.Row(
                analyte: analyte,
                value: LocaleDecimalParser.parse(row.value),
                valueText: nil,
                unit: LabUnit.wire(typed: row.unit, noUnit: row.noUnit) ?? (row.isLinked ? row.markerUnit : nil),
                referenceLow: row.isLinked ? nil : LocaleDecimalParser.parse(row.referenceLow),
                referenceHigh: row.isLinked ? nil : LocaleDecimalParser.parse(row.referenceHigh),
                referenceText: row.isLinked ? nil : row.referenceText,
                takenAt: takenAt,
                biomarkerId: row.biomarkerId
            )
        case .qualitative:
            return LabsOCRCommitRequest.Row(
                analyte: analyte,
                value: nil,
                valueText: row.qualitativeText.trimmingCharacters(in: .whitespaces),
                unit: nil,
                referenceLow: nil,
                referenceHigh: nil,
                referenceText: row.isLinked ? nil : row.referenceText,
                takenAt: takenAt,
                biomarkerId: row.biomarkerId
            )
        }
    }

    /// The already-localized line after a server commit.
    static func serverCommitSummary(written: Int, skipped: Int, allSent: Bool, batchCount: Int) -> String {
        if !allSent {
            return written == 0 && skipped == 0
                ? String(localized: "labs.ocr.saveFailed")
                : String(localized: "labs.scan.savedPartial.\(written).\(batchCount)")
        }
        if skipped > 0 {
            return String(localized: "labs.ocr.savedSkipped.\(written).\(skipped)")
        }
        return String(localized: "labs.scan.saved.\(written)")
    }
}

extension LabScanRow {
    /// LAB-OCR — one row a server read proposed. The same rules as a row read
    /// on the device: a bare "1" is not the person saying "no unit" (field
    /// empty, row flagged), weak fields and repeats are flagged, never dropped.
    init(server proposed: LabsOCRRow, biomarkerId: String?) {
        let isQualitative = proposed.value == nil && proposed.valueText != nil
        let readUnity = LabUnit.isUnity(proposed.unit)
        let unitDiffers = biomarkerId != nil && proposed.markerUnit != nil && proposed.unit != nil &&
            proposed.unit?.lowercased() != proposed.markerUnit?.lowercased()
        analyte = proposed.analyte
        resultType = isQualitative ? .qualitative : .numeric
        value = proposed.value.map { Self.editableNumber($0) } ?? ""
        qualitativeText = proposed.valueText ?? ""
        unit = readUnity ? "" : proposed.unit ?? ""
        referenceLow = proposed.referenceLow.map { Self.editableNumber($0) } ?? ""
        referenceHigh = proposed.referenceHigh.map { Self.editableNumber($0) } ?? ""
        referenceText = proposed.referenceText
        markerUnit = proposed.markerUnit
        requiresUnit = true
        self.biomarkerId = biomarkerId
        isLowConfidence = readUnity || unitDiffers || (proposed.confidence?.isWeak ?? false)
        isDuplicate = proposed.duplicateOf != nil
        rawLine = proposed.referenceText.map { String(localized: "labs.ocr.review.printedRange.\($0)") } ?? ""
    }
}
