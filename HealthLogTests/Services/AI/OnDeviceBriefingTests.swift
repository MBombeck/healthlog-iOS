import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for the on-device assistant briefing pipeline (R4 stack adoption,
/// I-1 scope). Covers the safety filter matrix, the feature-flag short
/// circuit, the locale switch, and the device-availability fallback path.
@Suite("OnDeviceBriefing — safety + availability + flags (I-1)")
@MainActor
struct OnDeviceBriefingTests {
    // MARK: - MDR Safety Filter (15-row matrix per R4 §5.1)

    @Test("MDRSafetyFilter — predictive German pattern is refused")
    func mdrFilterRefusesPredictiveDE() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Dein Blutdruck wird morgen steigen.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — predictive English pattern is refused")
    func mdrFilterRefusesPredictiveEN() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Your pulse will rise tomorrow.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — prescriptive (Empfehlung) is refused")
    func mdrFilterRefusesPrescriptive() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Ich empfehle dir, die Dosis zu erhöhen.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — diagnostic claim is refused")
    func mdrFilterRefusesDiagnostic() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Deine Werte deuten auf Hypertonie hin.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — direct diagnose claim is refused")
    func mdrFilterRefusesDirectDiagnose() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Du leidest an Diabetes.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — causal claim is refused")
    func mdrFilterRefusesCausal() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Dein Stress verursacht deinem Blutdruck.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — drug level interpretation is refused")
    func mdrFilterRefusesDrugLevel() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Dein Wirkstoffspiegel ist gerade am Peak.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — sick claim is refused")
    func mdrFilterRefusesSickClaim() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Du bist krank.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — therapy change is refused")
    func mdrFilterRefusesTherapyChange() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Du solltest deine Therapie ändern.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — future risk claim is refused")
    func mdrFilterRefusesFutureRisk() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Hohes Risiko für Schlaganfall.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — values indicate suggestion is refused")
    func mdrFilterRefusesValuesIndicate() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Deine Werte deuten auf etwas hin.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — leads-to causal link is refused")
    func mdrFilterRefusesLeadsTo() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Dein Schlafmangel führt zu höherem Puls.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — must-take-now is refused")
    func mdrFilterRefusesMustTakeNow() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Du musst jetzt deine Tablette nehmen.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — pharmacokinetic interpretation is refused")
    func mdrFilterRefusesPharmacokinetic() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Die Halbwertszeit deutet auf einen Peak hin.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — direct condition assertion is refused")
    func mdrFilterRefusesDirectCondition() async {
        let filter = MDRSafetyFilter()
        let refused = await filter.containsForbiddenPattern(in: "Du hast Bluthochdruck.")
        #expect(refused == true)
    }

    @Test("MDRSafetyFilter — safe observational text passes")
    func mdrFilterPassesSafeText() async {
        let filter = MDRSafetyFilter()
        let safe = await filter.containsForbiddenPattern(in: "Du hast diese Woche 7 Tage in Folge geloggt. Magst du auch Schlaf erfassen?")
        #expect(safe == false)
    }

    @Test("MDRSafetyFilter — matrix covers UNSAFE rows 7, 8, 9, 11, 14")
    func mdrFilterMatrixCoversRequiredRows() {
        let rows = MDRSafetyFilter.matrixRows()
        // R4 §5.1 — UNSAFE rows that MUST have at least one regex.
        for required in [7, 8, 9, 11, 14] {
            #expect(rows.contains(required), "Matrix missing row \(required)")
        }
    }

    @Test("MDRSafetyFilter — pattern count ≥ 15 (matrix completeness)")
    func mdrFilterHasFifteenPatterns() {
        #expect(MDRSafetyFilter.patternCount >= 15)
    }

    // MARK: - Feature flag short-circuit

    @Test("OnDeviceBriefingService — feature flag off short-circuits to fallback")
    func featureFlagOffShortCircuits() async throws {
        let defaults = try #require(UserDefaults(suiteName: "test.flag.off.\(UUID().uuidString)"))
        let flags = UserDefaultsFeatureFlagsService(defaults: defaults)
        flags.setEnabled(.assistantBriefing, value: false)
        let service = OnDeviceBriefingService(featureFlags: flags)
        let outcome = await service.generate(
            measurements: [],
            healthScore: nil,
            locale: Locale(identifier: "de_DE")
        )
        #expect(outcome.briefing == nil)
        #expect(outcome.fallbackReason == .featureFlagDisabled)
    }

    @Test("OnDeviceBriefingService — defaults to enabled when key absent")
    func featureFlagDefaultsToEnabled() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.flag.default.\(UUID().uuidString)"))
        let flags = UserDefaultsFeatureFlagsService(defaults: defaults)
        #expect(flags.isEnabled(.assistantBriefing) == true)
    }

    // MARK: - Locale switching in prompt template

    @Test("OnDeviceBriefingPrompt — DE locale produces German digest")
    func promptUsesGermanForDELocale() {
        let prompt = OnDeviceBriefingPrompt.build(
            measurements: [],
            healthScore: nil,
            locale: Locale(identifier: "de_DE")
        )
        #expect(prompt.contains("Daten der letzten 7 Tage"))
        #expect(prompt.contains("Niemals diagnostizieren") || prompt.contains("beobachtend"))
    }

    @Test("OnDeviceBriefingPrompt — EN locale produces English digest")
    func promptUsesEnglishForENLocale() {
        let prompt = OnDeviceBriefingPrompt.build(
            measurements: [],
            healthScore: nil,
            locale: Locale(identifier: "en_US")
        )
        #expect(prompt.contains("Last 7 days of data"))
        #expect(prompt.contains("Never diagnose"))
    }

    // MARK: - Device-availability fallback (compile-gated path)

    #if !canImport(FoundationModels)
        @Test("OnDeviceBriefingService — framework-unavailable returns fallback")
        func frameworkUnavailableFallsBack() async throws {
            let defaults = try #require(UserDefaults(suiteName: "test.fw.\(UUID().uuidString)"))
            let flags = UserDefaultsFeatureFlagsService(defaults: defaults)
            let service = OnDeviceBriefingService(featureFlags: flags)
            let outcome = await service.generate(
                measurements: [],
                healthScore: nil,
                locale: Locale(identifier: "de_DE")
            )
            #expect(outcome.briefing == nil)
            #expect(outcome.fallbackReason == .frameworkUnavailable)
        }
    #endif

    // MARK: - Server-shape isomorphism

    @Test("OnDeviceBriefing — maps to server DailyBriefing shape isomorphically")
    func mapsToServerShape() {
        let on = OnDeviceBriefing(
            summary: "Du hast 5 Messungen erfasst.",
            keyFindings: ["Puls stabil", "Schlaf 7h"],
            actionableNudges: [],
            confidence: 0.6,
            safetyApplied: true
        )
        let mapped = OnDeviceBriefingHero.mapToServerShape(on)
        #expect(mapped.paragraph == "Du hast 5 Messungen erfasst.")
        #expect(mapped.keyFindings.count == 2)
        #expect(mapped.keyFindings.first?.headline == "Puls stabil")
    }

    // MARK: - Provenance honesty (RA2 §6)

    @Test("DailyBriefingHero — provenance badge defaults OFF (no false privacy claim)")
    func provenanceBadgeDefaultsOff() {
        // The "On your device" badge must default OFF so the server /
        // Statistik-Mode-floor arms never claim on-device provenance.
        // OnDeviceBriefingHero opts it in ONLY on its .onDevice branch.
        let hero = DailyBriefingHero(
            briefing: DailyBriefing(paragraph: "x", keyFindings: []),
            style: .full
        )
        #expect(hero.showsOnDeviceProvenance == false)
    }

    @Test("DailyBriefingHero — provenance badge surfaces when explicitly on-device")
    func provenanceBadgeOptIn() {
        let hero = DailyBriefingHero(
            briefing: DailyBriefing(paragraph: "x", keyFindings: []),
            style: .full,
            showsOnDeviceProvenance: true
        )
        #expect(hero.showsOnDeviceProvenance == true)
    }
}
