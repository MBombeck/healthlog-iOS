import Foundation
import Testing

/// Determinism guards for the v0.84 native-FormatStyle migration
/// (WNATIVE-B). The absolute-date display surfaces — `HLEmojiChart`'s
/// VoiceOver x-axis label and `RecordCard`'s VoiceOver date — now route
/// through Foundation's `Date.FormatStyle` instead of hand-rolled
/// `DateFormatter` instances.
///
/// These tests pin a fixed `Locale` + `TimeZone` so the asserted output
/// is deterministic regardless of the test host's region. They lock the
/// exact FormatStyle configurations the production code adopted — if a
/// future refactor drifts the style (e.g. re-adds the year to the chart
/// x-label) the contract breaks here rather than silently in a VoiceOver
/// readout.
///
/// Relative-date output (`DailyBriefingCard` "Aktualisiert …",
/// `RecordCard` footer) routes through `Date.RelativeFormatStyle`, whose
/// rendering is computed against the live `Date.now` and therefore can't
/// be pinned to a deterministic string — those surfaces are exercised by
/// the build + their owning view-composition suites instead.
@Suite("Native Date.FormatStyle migration output")
struct NativeDateFormatStyleTests {
    /// 2026-05-16 (UTC) — a stable anchor for absolute-date asserts.
    private let anchor = Date(timeIntervalSince1970: 1_778_926_200)

    // MARK: - HLEmojiChart AX x-axis label (.day().month(.abbreviated))

    @Test("Chart AX x-label: day + abbreviated month, no year (de_DE)")
    func chartAXLabelGerman() {
        let style = Date.FormatStyle()
            .day()
            .month(.abbreviated)
            .locale(Locale(identifier: "de_DE"))
            .timeZone(.gmt)
        // German abbreviated month for May is "Mai"; day-first ordering.
        // Key contract: NO year component leaks in.
        #expect(anchor.formatted(style) == "16. Mai")
    }

    @Test("Chart AX x-label: day + abbreviated month, no year (en_US)")
    func chartAXLabelEnglish() {
        let style = Date.FormatStyle()
            .day()
            .month(.abbreviated)
            .locale(Locale(identifier: "en_US"))
            .timeZone(.gmt)
        // English abbreviated month is "May"; month-first ordering.
        #expect(anchor.formatted(style) == "May 16")
    }

    // MARK: - RecordCard AX absolute date (date: .abbreviated, time: .omitted)

    @Test("Record AX date: abbreviated date, time omitted (de_DE)")
    func recordAXDateGerman() {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            .locale(Locale(identifier: "de_DE"))
            .timeZone(.gmt)
        // `.abbreviated` renders the spelled abbreviated month ("Mai"),
        // not a numeric "16.05.2026" — locale-correct German long-ish form.
        #expect(anchor.formatted(style) == "16. Mai 2026")
    }

    @Test("Record AX date: abbreviated date, time omitted (en_US)")
    func recordAXDateEnglish() {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            .locale(Locale(identifier: "en_US"))
            .timeZone(.gmt)
        #expect(anchor.formatted(style) == "May 16, 2026")
    }
}
