import Foundation
import Testing

#if canImport(HealthLog)
    @testable import HealthLog
#endif

@Suite("HLInsightProse — insight prose rendering")
struct HLInsightProseTests {
    /// Paragraph breaks in the server copy must survive so the text doesn't read
    /// as one wall — `.inlineOnlyPreservingWhitespace` keeps the newlines.
    @Test("preserves paragraph breaks (\\n\\n survives)")
    func preservesParagraphBreaks() {
        let attr = HLInsightProse.attributed("Erster Absatz.\n\nZweiter Absatz.")
        let plain = String(attr.characters)
        #expect(plain.contains("\n\n"))
        #expect(plain.contains("Erster Absatz."))
        #expect(plain.contains("Zweiter Absatz."))
    }

    /// Inline emphasis is resolved (the `**` markers are consumed, not shown).
    @Test("resolves inline markdown emphasis")
    func resolvesEmphasis() {
        let attr = HLInsightProse.attributed("Dein Blutdruck ist **optimal**.")
        let plain = String(attr.characters)
        #expect(plain.contains("optimal"))
        #expect(!plain.contains("**"))
    }

    /// Plain prose with no markdown round-trips verbatim.
    @Test("plain prose round-trips unchanged")
    func plainRoundTrips() {
        let source = "Ganz normale Prosa ohne Formatierung."
        let plain = String(HLInsightProse.attributed(source).characters)
        #expect(plain == source)
    }
}
