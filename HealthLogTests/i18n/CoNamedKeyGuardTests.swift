import Foundation
import Testing

/// Build-8 (b239) coherence guard — pins that **every catalog key is fully
/// co-named across both locales** (de + en). A "half-localized" key — one that
/// carries a German value but no English block, or vice versa — renders the raw
/// key or the wrong-locale source on the missing side. `sourceLanguage: en`
/// makes the German side the silent-failure direction: an EN-only key shows
/// English text in the German build.
///
/// This complements `EmptyTranslationGuardTests` (which asserts *non-empty*
/// values): this guard focuses on the structural **co-presence** invariant — if
/// a key is localized at all, it must be localized in *both* de and en — and
/// carries the curated list of web-shared surfaces that Build 8 hardened, so a
/// future reflow cannot drop one leg of a shared key.
///
/// Value-parity against the web `messages/de.json` is intentionally NOT pinned
/// here: the Build-8 copy sweep (items 8.1/8.2/8.8, sibling agent) is rewriting
/// several of these German values in-flight, and a test must never reach into
/// the server repo. The co-presence invariant is stable regardless of copy.
@Suite("Co-Named-Key-Guard — jeder Key ist de+en (kein halb-lokalisierter Key)")
struct CoNamedKeyGuardTests {
    /// The single intentionally-empty sentinel key (`String(localized: "", …)`).
    static let intentionallyEmptyKeys: Set<String> = [""]

    /// Web-shared surfaces whose keys Build 8 pins as co-present anchors — the
    /// Documents module (the byte-identical shared-copy proof-of-concept), the
    /// 8.1 insights explainers, and a few 8.8 shared pairs. Presence in *both*
    /// locales is asserted; values are left to the copy sweep.
    static let sharedSurfaceKeys: [String] = [
        // Documents module — shared-copy proof-of-concept.
        "documents.list.title",
        "documents.kind.doctorReport",
        // 8.1 insights explainers (metric.description + subPage.explainer pairs).
        "insights.metric.activeEnergyBurned.description",
        "insights.metric.bodyMassIndex.description",
        "insights.metric.bodyTemperature.description",
        "insights.subPage.explainer.activeEnergyBody",
        "insights.subPage.explainer.bmiBody",
        "insights.subPage.explainer.bodyTemperatureBody",
        "insights.subPage.explainer.medicationsBody",
        "insights.subPage.explainer.moodBody",
        "insights.subPage.explainer.workoutsBody"
    ]

    @Test("Kein Key ist halb-lokalisiert — de vorhanden ⇒ en vorhanden und umgekehrt")
    func everyKeyIsCoNamed() throws {
        let catalog = try ParityCatalog.load()
        var halfLocalized: [String] = []
        for (key, entry) in catalog.strings {
            if Self.intentionallyEmptyKeys.contains(key) { continue }
            let hasDe = ParityCatalog.hasLocalization(entry, language: "de")
            let hasEn = ParityCatalog.hasLocalization(entry, language: "en")
            if hasDe != hasEn {
                halfLocalized.append("\(key) — de=\(hasDe) en=\(hasEn)")
            }
        }
        #expect(
            halfLocalized.isEmpty,
            "Halb-lokalisierte Keys (\(halfLocalized.count)): \(halfLocalized.sorted().prefix(20))"
        )
    }

    @Test("Web-geteilte Anker-Keys existieren in beiden Sprachen")
    func sharedSurfaceKeysArePresentInBothLocales() throws {
        let catalog = try ParityCatalog.load()
        var missing: [String] = []
        for key in Self.sharedSurfaceKeys {
            guard let entry = catalog.strings[key] else {
                missing.append("\(key) (key absent)")
                continue
            }
            if !ParityCatalog.hasLocalization(entry, language: "de") {
                missing.append("\(key) (de missing)")
            }
            if !ParityCatalog.hasLocalization(entry, language: "en") {
                missing.append("\(key) (en missing)")
            }
        }
        #expect(missing.isEmpty, "Geteilte Anker-Keys unvollständig: \(missing)")
    }
}
