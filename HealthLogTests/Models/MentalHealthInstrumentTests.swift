import Foundation
@testable import HealthLog
import Testing

/// Locks the PHQ-9 / GAD-7 / WHO-5 / SCI numeric and presentation contract
/// against the server source of truth (`src/lib/mental-health/instruments.ts`).
/// Pure contract tests: no network and no persisted item answers.
@Suite("Mental-health instrument contract")
struct MentalHealthInstrumentTests {
    // MARK: - Item counts

    @Test("PHQ-9 has 9 scored items, GAD-7 has 7")
    func itemCounts() {
        #expect(MentalHealthInstrument.phq9.itemCount == 9)
        #expect(MentalHealthInstrument.gad7.itemCount == 7)
        #expect(MentalHealthInstrument.phq9.maxScore == 27)
        #expect(MentalHealthInstrument.gad7.maxScore == 21)
    }

    @Test("Both instruments use an action threshold of 10")
    func actionThreshold() {
        #expect(MentalHealthInstrument.phq9.actionThreshold == 10)
        #expect(MentalHealthInstrument.gad7.actionThreshold == 10)
    }

    // MARK: - Scoring

    @Test("scoreTotal sums the answers")
    func scoreTotal() {
        #expect(MentalHealthInstrument.scoreTotal([1, 2, 3, 0, 1, 2, 3, 0, 1]) == 13)
        #expect(MentalHealthInstrument.scoreTotal([0, 0, 0, 0, 0, 0, 0]) == 0)
        #expect(MentalHealthInstrument.scoreTotal([3, 3, 3, 3, 3, 3, 3]) == 21)
    }

    // MARK: - Severity bands (boundary values per instrument)

    @Test("PHQ-9 band boundaries (minimal 0–4 / mild 5–9 / moderate 10–14 / modSevere 15–19 / severe 20–27)")
    func phq9Bands() {
        let i = MentalHealthInstrument.phq9
        #expect(i.severityBand(forTotal: 0) == "minimal")
        #expect(i.severityBand(forTotal: 4) == "minimal")
        #expect(i.severityBand(forTotal: 5) == "mild")
        #expect(i.severityBand(forTotal: 9) == "mild")
        #expect(i.severityBand(forTotal: 10) == "moderate")
        #expect(i.severityBand(forTotal: 14) == "moderate")
        #expect(i.severityBand(forTotal: 15) == "modSevere")
        #expect(i.severityBand(forTotal: 19) == "modSevere")
        #expect(i.severityBand(forTotal: 20) == "severe")
        #expect(i.severityBand(forTotal: 27) == "severe")
    }

    @Test("GAD-7 band boundaries (minimal 0–4 / mild 5–9 / moderate 10–14 / severe 15–21)")
    func gad7Bands() {
        let i = MentalHealthInstrument.gad7
        #expect(i.severityBand(forTotal: 0) == "minimal")
        #expect(i.severityBand(forTotal: 4) == "minimal")
        #expect(i.severityBand(forTotal: 5) == "mild")
        #expect(i.severityBand(forTotal: 9) == "mild")
        #expect(i.severityBand(forTotal: 10) == "moderate")
        #expect(i.severityBand(forTotal: 14) == "moderate")
        #expect(i.severityBand(forTotal: 15) == "severe")
        #expect(i.severityBand(forTotal: 21) == "severe")
    }

    // MARK: - Item-9 safety flag (INDEPENDENT of total)

    @Test("PHQ-9 item-9 flag fires on any non-zero index 8, independent of total")
    func phq9SafetyFlag() {
        let phq9 = MentalHealthInstrument.phq9
        // All-zero except item 9 = 1 → total 1 (minimal band) but STILL flagged.
        var items = Array(repeating: 0, count: 9)
        items[8] = 1
        #expect(phq9.isSafetyFlagged(items: items))
        #expect(MentalHealthInstrument.scoreTotal(items) == 1)

        // Item 9 = 0 with a high total → NOT flagged (flag is item-9 only).
        let highButSafe = [3, 3, 3, 3, 3, 0, 0, 0, 0] // total 15
        #expect(!phq9.isSafetyFlagged(items: highButSafe))

        // Item 9 = 3 → flagged.
        var maxFlag = Array(repeating: 0, count: 9)
        maxFlag[8] = 3
        #expect(phq9.isSafetyFlagged(items: maxFlag))
    }

    @Test("GAD-7 never flags (no safety item)")
    func gad7NeverFlags() {
        let gad7 = MentalHealthInstrument.gad7
        #expect(gad7.safetyItemIndex == nil)
        #expect(!gad7.isSafetyFlagged(items: [3, 3, 3, 3, 3, 3, 3]))
    }

    // MARK: - WHO-5 well-being index (v1.27.9 — inverted, 0–5 scale, no safety item)

    @Test("WHO-5 structural contract: 5 items, 0–5 six-point scale, ×4 → 0–100, higher is better")
    func who5Structure() {
        let who5 = MentalHealthInstrument.who5
        #expect(who5.rawValue == "WHO5")
        #expect(who5.keySegment == "who5")
        #expect(who5.itemCount == 5)
        #expect(who5.itemMax == 5)
        #expect(who5.maxScore == 100)
        #expect(who5.scoreMultiplier == 4)
        #expect(who5.higherIsBetter)
        #expect(who5.actionThreshold == 50)
        #expect(who5.optionOrder == [5, 4, 3, 2, 1, 0])
        #expect(who5.optionGroups == nil)
        #expect(who5.optionKeyPrefix(forItem: 0) == "mentalHealth.who5Options")
        #expect(who5.stemKeys == Array(repeating: "who5.period", count: 5))
        #expect(who5.stemKey(forItem: 0) == "mentalHealth.stems.who5.period")
        #expect(!who5.showsFunctionalFollowUp)
        #expect(who5.hasValidatedItems(locale: "de-DE"))
    }

    @Test("WHO-5 has no safety item — never flags, even all-max")
    func who5NoSafetyItem() {
        let who5 = MentalHealthInstrument.who5
        #expect(who5.safetyItemIndex == nil)
        #expect(!who5.isSafetyFlagged(items: [5, 5, 5, 5, 5]))
        #expect(!who5.isSafetyFlagged(items: [0, 0, 0, 0, 0]))
    }

    @Test("WHO-5 reported total is raw-sum × 4 (0–100 %)")
    func who5ScoreTotal() {
        let who5 = MentalHealthInstrument.who5
        #expect(who5.scoreTotal(items: [0, 0, 0, 0, 0]) == 0)
        #expect(who5.scoreTotal(items: [5, 5, 5, 5, 5]) == 100) // raw 25 × 4
        #expect(who5.scoreTotal(items: [3, 3, 3, 2, 1]) == 48) // raw 12 × 4
        // The distress screeners keep the ×1 multiplier.
        #expect(MentalHealthInstrument.phq9.scoreTotal(items: [1, 2, 3, 0, 1, 2, 3, 0, 1]) == 13)
    }

    @Test("WHO-5 band boundaries over the ×4 percentage (low 0–50 / good 51–100)")
    func who5Bands() {
        let who5 = MentalHealthInstrument.who5
        #expect(who5.severityBand(forTotal: 0) == "low")
        #expect(who5.severityBand(forTotal: 48) == "low")
        #expect(who5.severityBand(forTotal: 50) == "low")
        #expect(who5.severityBand(forTotal: 52) == "good")
        #expect(who5.severityBand(forTotal: 100) == "good")
    }

    @Test("Follow-up nudge is direction-aware")
    func directionAwareFollowUp() {
        let who5 = MentalHealthInstrument.who5
        #expect(who5.needsFollowUp(forTotal: 48))
        #expect(who5.needsFollowUp(forTotal: 0))
        #expect(!who5.needsFollowUp(forTotal: 52))
        #expect(!who5.needsFollowUp(forTotal: 100))
        #expect(MentalHealthInstrument.phq9.needsFollowUp(forTotal: 10))
        #expect(!MentalHealthInstrument.phq9.needsFollowUp(forTotal: 9))
        #expect(MentalHealthInstrument.gad7.needsFollowUp(forTotal: 21))
    }

    @Test("WHO-5 carries the verbatim WHO attribution; only PHQ-9 has the optional functional step")
    func who5Attribution() {
        #expect(MentalHealthInstrument.who5.attribution == MentalHealthAttribution.who5)
        #expect(MentalHealthInstrument.who5.attribution ==
            "World Health Organization. The World Health Organization-Five Well-Being " +
            "Index (WHO-5). Geneva: World Health Organization; 2024. Licence: " +
            "CC BY-NC-SA 3.0 IGO. WHO does not endorse this application.")
        #expect(MentalHealthInstrument.phq9.attribution == MentalHealthAttribution.text)
        #expect(MentalHealthInstrument.phq9.showsFunctionalFollowUp)
        #expect(!MentalHealthInstrument.gad7.showsFunctionalFollowUp)
        #expect(!MentalHealthInstrument.who5.showsFunctionalFollowUp)
    }

    // MARK: - Sleep Condition Indicator

    @Test("SCI structure mirrors the server registry exactly")
    func sciStructure() {
        let sci = MentalHealthInstrument.sci
        #expect(sci.rawValue == "SCI")
        #expect(sci.keySegment == "sci")
        #expect(sci.itemCount == 8)
        #expect(sci.itemMax == 4)
        #expect(sci.maxScore == 32)
        #expect(sci.scoreMultiplier == 1)
        #expect(sci.higherIsBetter)
        #expect(sci.optionOrder == [4, 3, 2, 1, 0])
        #expect(sci.optionGroups == [
            "duration", "duration", "nights", "quality",
            "impact", "impact", "impact", "problemDuration"
        ])
        #expect(sci.stemKeys == [
            "sci.night", "sci.night", "sci.night", "sci.night",
            "sci.impact", "sci.impact", "sci.impact", "sci.finally"
        ])
        #expect(sci.optionKeyPrefix(forItem: 0) == "mentalHealth.sciOptions.duration")
        #expect(sci.optionKeyPrefix(forItem: 2) == "mentalHealth.sciOptions.nights")
        #expect(sci.optionKeyPrefix(forItem: 7) == "mentalHealth.sciOptions.problemDuration")
        #expect(sci.stemKey(forItem: 0) == "mentalHealth.stems.sci.night")
        #expect(sci.stemKey(forItem: 4) == "mentalHealth.stems.sci.impact")
        #expect(sci.stemKey(forItem: 7) == "mentalHealth.stems.sci.finally")
    }

    @Test("SCI scores 0–32, bands at 16/17, and follows up on the lower side")
    func sciScoringAndBands() {
        let sci = MentalHealthInstrument.sci
        #expect(sci.scoreTotal(items: Array(repeating: 0, count: 8)) == 0)
        #expect(sci.scoreTotal(items: Array(repeating: 4, count: 8)) == 32)
        #expect(sci.severityBand(forTotal: 0) == "belowThreshold")
        #expect(sci.severityBand(forTotal: 16) == "belowThreshold")
        #expect(sci.severityBand(forTotal: 17) == "aboveThreshold")
        #expect(sci.severityBand(forTotal: 32) == "aboveThreshold")
        #expect(sci.actionThreshold == 16)
        #expect(sci.needsFollowUp(forTotal: 16))
        #expect(!sci.needsFollowUp(forTotal: 17))
    }

    @Test("SCI has no safety or functional question and is validated in English only")
    func sciLocaleAndSafety() {
        let sci = MentalHealthInstrument.sci
        #expect(sci.safetyItemIndex == nil)
        #expect(!sci.isSafetyFlagged(items: Array(repeating: 4, count: 8)))
        #expect(!sci.showsFunctionalFollowUp)
        #expect(sci.validatedItemLocales == ["en"])
        #expect(sci.hasValidatedItems(locale: "en-US"))
        #expect(!sci.hasValidatedItems(locale: "de-DE"))
    }

    @Test("SCI carries the verbatim BMJ Open and Sleepio attribution")
    func sciAttribution() {
        #expect(MentalHealthInstrument.sci.attribution == MentalHealthAttribution.sci)
        #expect(MentalHealthAttribution.sci ==
            "Espie CA, Kyle SD, Hames P, et al. The Sleep Condition Indicator: a " +
            "clinical screening tool to evaluate insomnia disorder. BMJ Open " +
            "2014;4:e004183. © Sleepio Limited; free for non-commercial use (CC BY-NC).")
    }

    // MARK: - Attribution (verbatim, English)

    @Test("Pfizer attribution is the verbatim server string")
    func attribution() {
        #expect(MentalHealthAttribution.text ==
            "Developed by Drs. Robert L. Spitzer, Janet B.W. Williams, Kurt Kroenke and " +
            "colleagues, with an educational grant from Pfizer Inc. No permission " +
            "required to reproduce, translate, display or distribute.")
    }

    // MARK: - Crisis fallback resolution (mirrors server coarse mapping)

    @Test("Crisis fallback resolves DE for de*, US for en-us, International otherwise (incl. plain en)")
    func crisisFallbackResolution() {
        // German → TelefonSeelsorge, emergency 112.
        let de = CrisisResourceFallback.forLocale("de")
        #expect(de.emergencyNumber == "112")
        #expect(de.resources.contains { $0.id == "telefonSeelsorge" })
        #expect(CrisisResourceFallback.forLocale("de_DE").resources.contains { $0.id == "telefonSeelsorge" })

        // en-US → 988, emergency 911.
        let us = CrisisResourceFallback.forLocale("en-US")
        #expect(us.emergencyNumber == "911")
        #expect(us.resources.contains { $0.id == "lifeline988" })

        // plain en → International (NOT US), emergency 112.
        let intl = CrisisResourceFallback.forLocale("en")
        #expect(intl.emergencyNumber == "112")
        #expect(intl.resources.contains { $0.id == "euEmotionalSupport" })
        #expect(!intl.resources.contains { $0.id == "lifeline988" })

        // nil → International.
        #expect(CrisisResourceFallback.forLocale(nil).emergencyNumber == "112")
    }

    // MARK: - Crisis-contact link shape detection

    @Test("Crisis contacts: phone → tel:, domain → https:, instruction → plain text")
    func crisisContactLinks() {
        #expect(MentalHealthCrisisCard.link(for: "0800 111 0 111")?.absoluteString == "tel:0800111 0111".replacingOccurrences(
            of: " ",
            with: ""
        ))
        #expect(MentalHealthCrisisCard.link(for: "988")?.absoluteString == "tel:988")
        #expect(MentalHealthCrisisCard.link(for: "116 123")?.absoluteString == "tel:116123")
        #expect(MentalHealthCrisisCard.link(for: "telefonseelsorge.de")?.absoluteString == "https://telefonseelsorge.de")
        #expect(MentalHealthCrisisCard.link(for: "findahelpline.com")?.absoluteString == "https://findahelpline.com")
        // SMS instruction is ambiguous → plain text (no link).
        #expect(MentalHealthCrisisCard.link(for: "Text HOME to 741741") == nil)
    }
}
