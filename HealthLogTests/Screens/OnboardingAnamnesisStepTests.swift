import Foundation
@testable import HealthLog
import Testing

/// G2/G3/G5/G6 (AUDIT-onboarding) — onboarding anamnesis routing + the
/// AI-consent legal-disclosure copy keys.
///
/// We test the pure routing decision (no view tree) plus that every new
/// localized key resolves to real, non-key copy in the bundle (a missing or
/// mistyped key returns the key string itself, which these assertions catch).
@MainActor
@Suite("Onboarding — anamnesis step + consent legal text")
struct OnboardingAnamnesisStepTests {
    // MARK: - Routing

    @Test("server branch routes into the optional anamnesis step")
    func serverRoutesToAnamnesis() {
        let next = OnboardingFlow.stepAfterAISource(isStandalone: false)
        #expect(next == .anamnesis)
        #expect(next != .done)
    }

    @Test("standalone skips anamnesis (server-only) and finishes")
    func standaloneSkipsAnamnesis() {
        let next = OnboardingFlow.stepAfterAISource(isStandalone: true)
        #expect(next == .done)
        #expect(next != .anamnesis)
    }

    // MARK: - Localized copy resolves

    private func resolves(_ key: String) -> Bool {
        let value = String(localized: String.LocalizationValue(key))
        // A missing key returns the key itself; a present key returns copy that
        // differs from the key and is non-empty.
        return !value.isEmpty && value != key
    }

    @Test("onboarding anamnesis copy keys resolve")
    func anamnesisKeysResolve() {
        for key in [
            "onboarding.progress.anamnesis",
            "onboarding.anamnesis.title",
            "onboarding.anamnesis.subtitle",
            "onboarding.anamnesis.goals.title",
            "onboarding.anamnesis.goals.prompt",
            "onboarding.anamnesis.conditions.title",
            "onboarding.anamnesis.allergies.title",
            "onboarding.anamnesis.footer"
        ] {
            #expect(resolves(key), "missing onboarding key: \(key)")
        }
    }

    @Test("G4 — onboarding baseline-profile copy keys resolve")
    func baselineProfileKeysResolve() {
        for key in [
            "onboarding.progress.baselineProfile",
            "onboarding.baselineProfile.title",
            "onboarding.baselineProfile.subtitle",
            "onboarding.baselineProfile.name.prompt",
            "onboarding.baselineProfile.footer"
        ] {
            #expect(resolves(key), "missing baseline-profile key: \(key)")
        }
    }

    // MARK: - Allergies parsing (audit 02 · H-2b)

    @Test("allergies free-text splits on newlines and commas, trimming blanks")
    func parseSubstancesSplitsAndTrims() {
        let parsed = AnamnesisStep.parseSubstances("Penicillin, Pollen\n  Lactose  \n\n , ")
        #expect(parsed == ["Penicillin", "Pollen", "Lactose"])
    }

    @Test("empty / whitespace-only allergies text yields no substances")
    func parseSubstancesEmpty() {
        #expect(AnamnesisStep.parseSubstances("   \n , ").isEmpty)
        #expect(AnamnesisStep.parseSubstances("").isEmpty)
    }

    @Test("an over-long substance is capped at the server's 160-char limit")
    func parseSubstancesCaps() {
        let long = String(repeating: "a", count: 200)
        let parsed = AnamnesisStep.parseSubstances(long)
        #expect(parsed.count == 1)
        #expect(parsed[0].count == 160)
    }

    // MARK: - 08-10: an optional field is not an unchecked field

    @Test("a blank height is legitimate and may advance")
    func blankHeightIsSkippable() {
        for blank in ["", "   ", "\t"] {
            #expect(BaselineProfileStep.validateHeight(blank) == .blank, "\(blank.debugDescription) is blank")
        }
    }

    @Test("the accepted band is inclusive at both ends")
    func heightBandIsInclusive() {
        #expect(BaselineProfileStep.validateHeight("50") == .valid(50))
        #expect(BaselineProfileStep.validateHeight("300") == .valid(300))
        #expect(BaselineProfileStep.validateHeight(" 170 ") == .valid(170))
    }

    @Test("a non-blank value outside the band cannot advance")
    func outOfBandHeightIsInvalid() {
        // Each of these used to be *dropped*: the patch simply omitted the
        // height, and when it was the only thing typed the step advanced
        // through `guard dirty else { onNext() }` with the input gone and
        // nothing said. `.invalid` is the state that makes that impossible.
        for entry in ["49", "301", "500", "0", "-170", "abc", "17.0", "1e2", "170cm"] {
            #expect(
                BaselineProfileStep.validateHeight(entry) == .invalid,
                "\(entry) is neither blank nor a height and must not advance"
            )
        }
    }

    // MARK: - 08-10: a partial save is its own answer

    @Test("nothing refused is a complete save")
    func noRefusalIsComplete() {
        let all = AnamnesisStep.AllergySaveResult(attempted: 3, failed: [])
        #expect(AnamnesisStep.disclosure(allergies: all, conditionsFailed: false) == .complete)
        #expect(AnamnesisStep.disclosure(allergies: .nothingAttempted, conditionsFailed: false) == .complete)
    }

    @Test("some refused is partial, and it counts what failed")
    func someRefusedIsPartial() {
        let some = AnamnesisStep.AllergySaveResult(attempted: 5, failed: ["Pollen", "Lactose"])
        #expect(AnamnesisStep.disclosure(allergies: some, conditionsFailed: false) == .partial(failed: 2))
    }

    @Test("a refused free-text write outranks the allergy tally")
    func conditionsFailureIsTheWholeAnswer() {
        let some = AnamnesisStep.AllergySaveResult(attempted: 2, failed: ["Pollen"])
        #expect(AnamnesisStep.disclosure(allergies: some, conditionsFailed: true) == .failed)
        #expect(AnamnesisStep.disclosure(allergies: .nothingAttempted, conditionsFailed: true) == .failed)
    }

    @Test("the partial-save summary is localized, counted and redacted")
    func partialSaveMessageIsRedacted() {
        let message = AnamnesisStep.partialSaveMessage(failed: 2, attempted: 5)
        #expect(message != "onboarding.anamnesis.partialSave", "the key must resolve")
        #expect(message.contains("2"))
        #expect(message.contains("5"))
        // The substances are health data. They stay in the field the user typed
        // them into — which is what makes the retry a retry — and never enter a
        // message, a log or an identifier.
        #expect(!message.contains("Pollen"))
        #expect(!message.contains("%"))
    }

    @Test("AI-consent legal-disclosure keys resolve (sub-processor / transfer / Art. 9)")
    func consentLegalKeysResolve() {
        for key in [
            "consent.legal.leavesDevice",
            "consent.legal.subProcessor.server",
            "consent.legal.subProcessor.userChosen",
            "consent.legal.transferRetention",
            "consent.legal.article9"
        ] {
            #expect(resolves(key), "missing consent key: \(key)")
        }
    }

    @Test("Art. 9 consent copy names the GDPR legal basis")
    func article9CopyNamesLegalBasis() {
        let copy = String(localized: "consent.legal.article9")
        #expect(copy.contains("9(2)(a)") || copy.contains("9 (2) (a)"))
    }

    @Test("server sub-processor copy names Anthropic and OpenAI")
    func subProcessorNamesProviders() {
        let copy = String(localized: "consent.legal.subProcessor.server")
        #expect(copy.contains("Anthropic"))
        #expect(copy.contains("OpenAI"))
    }
}
