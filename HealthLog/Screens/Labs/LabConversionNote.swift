import SwiftUI

/// #126 3.5 (server v1.42.3) — a lab reading entered in another unit.
///
/// The server converts a printed value into the marker's unit when it knows the
/// pair (`converted: true`) and keeps what was printed in `sourceValue` /
/// `sourceUnit`; `printedReferenceText` is the range as printed in the source
/// unit. The app shows both as delivered and converts nothing itself.
struct LabConversion: Equatable {
    let converted: Bool?
    let sourceValue: Double?
    let sourceUnit: String?
    let printedReferenceText: String?

    init(converted: Bool?, sourceValue: Double?, sourceUnit: String?, printedReferenceText: String?) {
        self.converted = converted
        self.sourceValue = sourceValue
        self.sourceUnit = sourceUnit
        self.printedReferenceText = printedReferenceText
    }

    init(_ row: LabResultDTO) {
        self.init(
            converted: row.converted, sourceValue: row.sourceValue,
            sourceUnit: row.sourceUnit, printedReferenceText: row.printedReferenceText
        )
    }

    init(_ detail: LabResultDetailDTO) {
        self.init(
            converted: detail.converted, sourceValue: detail.sourceValue,
            sourceUnit: detail.sourceUnit, printedReferenceText: detail.printedReferenceText
        )
    }

    /// "converted from 5.4 mmol/L", only for a reading the server converted.
    var convertedLine: String? {
        guard converted == true, let sourceValue else { return nil }
        let value = sourceValue.formatted(.number.precision(.fractionLength(0 ... 4)))
        let printed = LabUnit.appending(sourceUnit, to: value)
        return String(localized: "labs.conversion.from \(printed)")
    }

    /// "Printed range: 3.9 to 5.5 mmol/L", as the server stored it.
    var printedRangeLine: String? {
        guard let text = printedReferenceText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return String(localized: "labs.conversion.printedRange \(text)")
    }

    var lines: [String] {
        [convertedLine, printedRangeLine].compactMap(\.self)
    }
}

/// The two lines of ``LabConversion`` in caption style; nothing for a reading
/// entered in the marker's own unit.
struct LabConversionNote: View {
    let conversion: LabConversion

    var body: some View {
        ForEach(conversion.lines, id: \.self) { line in
            Text(verbatim: line)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// #126 3.5 — the unit a linked reading is sent with: the printed unit when
/// the person entered one that differs from the marker's, else none (the
/// server then takes the marker's unit). Spelling is the server's business
/// (`mmol/l` is forgiven there); only an identical unit is dropped here.
enum LabPrintedUnit {
    static func sent(_ printed: String, markerUnit: String?) -> String? {
        let trimmed = printed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let markerUnit, trimmed == markerUnit.trimmingCharacters(in: .whitespaces) { return nil }
        return trimmed
    }
}
