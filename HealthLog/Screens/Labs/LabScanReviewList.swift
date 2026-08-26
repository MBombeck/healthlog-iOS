import SwiftUI

/// Step 3 of the lab-report scan: **review every parsed row before anything is
/// written**.
///
/// This screen is the point of the feature, not a courtesy. OCR misreads
/// decimal separators ("7,4" → "74"), confuses units (`mg/dl` vs `mmol/l`), and
/// occasionally attaches a reference bound to the wrong analyte. Committing
/// parsed readings straight into a health record would be precisely the
/// data-integrity defect this work exists to remove. So:
///
///   * every field is editable — analyte, result, unit, both reference bounds;
///   * every row can be switched off individually and is then never written;
///   * the verbatim OCR line sits under each row so the user can compare
///     against the paper without leaving the screen;
///   * weak parses (`labs.scan.flag.lowConfidence`) and repeats
///     (`labs.scan.flag.duplicate`) are flagged — as *hints*, never as
///     automatic rejections, because both are legitimate often enough.
///
/// A linked row (its analyte matched a catalog biomarker) shows unit + range
/// read-only: the server resolves those from the catalog and the client must
/// never send a competing copy.
struct LabScanReviewList: View {
    @Bindable var scan: LabScanStore

    var body: some View {
        Form {
            headerSection
            ForEach($scan.rows) { $row in
                rowSection(row: $row)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            DatePicker(
                "labs.scan.review.batchDate",
                selection: $scan.takenAt,
                in: ...scan.takenAtBound,
                displayedComponents: [.date]
            )
            .accessibilityIdentifier("labs.scan.review.batchDate")
            // Discard the whole batch and photograph the report again. Nothing
            // has been written at this point, so this is a pure local reset.
            Button("labs.scan.retake") { scan.retake() }
                .accessibilityIdentifier("labs.scan.retake")
                .disabled(scan.step == .saving)
        } header: {
            Text("labs.scan.review.header")
        } footer: {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("labs.scan.review.footer")
                Text("labs.scan.review.selected.\(scan.includedCount).\(scan.rows.count)")
                if let summary = scan.saveSummary {
                    Text(verbatim: summary)
                        .foregroundStyle(HLText.primary)
                }
            }
        }
    }

    // MARK: - One reviewable row

    private func rowSection(row: Binding<LabScanRow>) -> some View {
        Section {
            Toggle(isOn: row.isIncluded) {
                Text("labs.scan.review.include")
            }
            .accessibilityIdentifier("labs.scan.review.include")

            if row.wrappedValue.isIncluded {
                analyteField(row: row)
                LabResultTypePicker(resultType: row.resultType)
                resultField(row: row)
                if !row.wrappedValue.isLinked {
                    unitField(row: row)
                    referenceFields(row: row)
                }
            }
        } header: {
            flags(row: row.wrappedValue)
        } footer: {
            footer(row: row.wrappedValue)
        }
    }

    @ViewBuilder
    private func analyteField(row: Binding<LabScanRow>) -> some View {
        if row.wrappedValue.isLinked {
            LabeledContent("labs.scan.review.analyte") {
                Text(verbatim: row.wrappedValue.analyte)
                    .foregroundStyle(HLText.secondary)
            }
        } else {
            TextField("labs.scan.review.analyte", text: row.analyte)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private func resultField(row: Binding<LabScanRow>) -> some View {
        switch row.wrappedValue.resultType {
        case .numeric:
            TextField("labs.add.value", text: row.value)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("labs.scan.review.value")
        case .qualitative:
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                TextField("labs.form.qualitativePlaceholder", text: row.qualitativeText)
                    .accessibilityIdentifier("labs.scan.review.qualitative")
                LabQualitativeSuggestionChips(text: row.qualitativeText)
            }
        }
    }

    private func unitField(row: Binding<LabScanRow>) -> some View {
        TextField("labs.add.unit", text: row.unit)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    @ViewBuilder
    private func referenceFields(row: Binding<LabScanRow>) -> some View {
        TextField("labs.add.referenceLow", text: row.referenceLow)
            .keyboardType(.decimalPad)
        TextField("labs.add.referenceHigh", text: row.referenceHigh)
            .keyboardType(.decimalPad)
    }

    /// Header line: the flags this row carries, if any.
    @ViewBuilder
    private func flags(row: LabScanRow) -> some View {
        let labels = flagLabels(row: row)
        if labels.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: HLSpace.sm) {
                ForEach(labels, id: \.self) { label in
                    HLBadge(label, tone: .info)
                }
            }
        }
    }

    private func flagLabels(row: LabScanRow) -> [String] {
        var labels: [String] = []
        if row.isLowConfidence { labels.append(String(localized: "labs.scan.flag.lowConfidence")) }
        if row.isDuplicate { labels.append(String(localized: "labs.scan.flag.duplicate")) }
        return labels
    }

    /// Footer: the verbatim OCR line, plus the catalog-link note for a linked
    /// row (its unit + range come from the catalog, hence the missing fields).
    private func footer(row: LabScanRow) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            if row.isLinked {
                Text("labs.scan.review.linked")
            }
            if !row.rawLine.isEmpty {
                Text(verbatim: row.rawLine)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        }
    }
}
