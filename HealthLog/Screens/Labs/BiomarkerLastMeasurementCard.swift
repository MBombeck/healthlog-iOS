import SwiftUI

/// The "Letzte Messung" card on the biomarker detail page: the newest
/// reading in the one hero form the lab pages share with the reference
/// metric page.
struct BiomarkerLastMeasurementCard: View {
    let latest: LabResultDTO
    /// The marker's earlier values, oldest first, as faint points on the range.
    var previous: [Double] = []
    /// The range the marker page judges against (the catalog's when linked).
    var referenceLow: Double?
    var referenceHigh: Double?

    var body: some View {
        LabReadingHero(
            reading: LabReadingHero.Reading(
                value: latest.value, valueText: latest.valueText, unit: latest.unit, printed: latest.sourceValue
            ),
            status: latest.rangeStatus,
            caption: Self.takenCaption(latest.takenAt),
            conversion: LabConversion(latest),
            range: LabReadingHero.Range(low: referenceLow, high: referenceHigh, previous: previous)
        )
    }

    /// "When taken": relative phrasing paired with the absolute medium date
    /// ("Erhoben vor 5 Monaten, 12. Jan. 2026"). Falls back to the bare
    /// medium date when the wire timestamp can't be parsed.
    static func takenCaption(_ takenAt: String) -> String {
        guard let date = LabsDateFormat.readingDate(takenAt) else {
            return LabsDateFormat.labDate(takenAt)
        }
        let relative = date.formatted(.relative(presentation: .named))
        let absolute = LabsDateFormat.labDate(takenAt)
        let template = String(localized: "biomarker.detail.taken.dated")
        return String(format: template, relative, absolute)
    }
}

/// One lab reading as the page's one large figure, built like the hero of
/// the reference metric page (Ruhepuls, Blutdruck): the number in the hero
/// role with its unit small and quiet beside it, the range verdict as quiet
/// text at the top right, the date under it, and the value on its reference
/// range. The biomarker page and the single reading's page use this one form;
/// the name of the marker is the page's or the column's head, never the card's.
struct LabReadingHero: View {
    /// What the reading says, as the server delivered it.
    struct Reading: Equatable {
        let value: Double?
        let valueText: String?
        let unit: String
        /// What the report printed when the server converted the value.
        let printed: Double?

        /// The figure and its unit apart. A number keeps every digit it was
        /// recorded with; a qualitative result is its text and has no unit;
        /// the unity "1" never prints.
        var parts: (number: String, unit: String?) {
            if let value {
                return (RecordedNumber.text(value, printed: printed), LabUnit.suffix(unit))
            }
            if let valueText, !valueText.isEmpty {
                return (valueText, nil)
            }
            return (LabValueDisplay.absentPlaceholder, nil)
        }

        /// Figure and unit as one spoken text.
        var spoken: String {
            LabValueDisplay.text(value: value, valueText: valueText, unit: unit, printed: printed)
        }
    }

    /// The reference range the value is placed on, with earlier values.
    struct Range: Equatable {
        var low: Double?
        var high: Double?
        var previous: [Double] = []
    }

    let reading: Reading
    let status: LabRangeStatus
    let caption: String
    let conversion: LabConversion
    var range = Range()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // From the accessibility sizes on, the verdict moves under the
                // value; beside it one of them broke into single letters.
                let stacked = dynamicTypeSize.isAccessibilitySize
                let row = stacked
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xs))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: HLSpace.xs))
                row {
                    figure
                    if !stacked {
                        Spacer(minLength: HLSpace.xs)
                    }
                    if let verdict = status.rowStatus {
                        verdict.badge
                            .fixedSize()
                    }
                }
                Text(verbatim: caption)
                    .hlText(.rowSubtitle)
                // A single value is read against its range at once, before any
                // course exists.
                if let bar = LabRangeBar(
                    value: reading.value,
                    previous: range.previous,
                    low: range.low,
                    high: range.high,
                    accessibilityText: ""
                ) {
                    bar
                        .padding(.top, HLSpace.xs)
                        .accessibilityHidden(true)
                }
                // A reading the server converted names what was printed.
                LabConversionNote(conversion: conversion)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: accessibilityText))
        }
    }

    private var figure: some View {
        let parts = reading.parts
        return HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Text(verbatim: parts.number)
                .hlText(.heroValue)
                .lineLimit(1)
                .minimumScaleFactor(HeroStrip.valueMinimumScaleFactor)
                .layoutPriority(1)
            if let unit = parts.unit {
                Text(verbatim: unit)
                    .hlText(.valueUnit)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// One spoken element: value, range status, date and the range, so
    /// nothing is read twice.
    private var accessibilityText: String {
        let template = String(localized: "biomarker.detail.lastMeasurement.a11y")
        var text = String(format: template, reading.spoken, status.localizedLabel) + ", " + caption
        if let reference = BiomarkerSeries.referenceText(low: range.low, high: range.high, unit: reading.unit) {
            text += ", \(String(localized: "labs.detail.reference")) \(reference)"
        }
        return text
    }
}
