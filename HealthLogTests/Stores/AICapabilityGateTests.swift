import Foundation
@testable import HealthLog
import Testing

/// #114 / #115 · 0.2 — successor of `FeatureFlagsLiveServiceTests`: the gate
/// every AI surface reads, its live shadow for the on-device actors, the
/// refusal mirror, and the update path from builds that cached the old flags.
@Suite("AICapabilityGate — capability reads, live shadow, update path", .serialized)
@MainActor
struct AICapabilityGateTests {
    // MARK: - Legacy (server < v1.39) vs. present block

    @Test("No `ai` block → every capability reads the 1.0.3 behaviour")
    func legacyReadsOpen() {
        let gate = AICapabilityGate()
        for key in AICapabilityKey.allCases {
            #expect(gate.isAvailable(key))
            #expect(gate.allowsOnDevice(key))
            #expect(gate.offersEntryPoint(key))
        }
        #expect(!gate.reportsCapabilities)
    }

    @Test(
        "With a block present, `available` / `onDeviceAllowed` / the entry point follow the server per reason",
        arguments: [
            (AICaps.available, true, true, true),
            (AICaps.operatorDisabled, false, false, false),
            (AICaps.notPermitted, false, false, false),
            (AICaps.moduleDisabled, false, false, false),
            (AICaps.userDisabled, false, false, false),
            (AICaps.checkFailed, false, false, false),
            (AICaps.noProvider, false, true, true),
            (AICaps.consentRequired, false, true, true)
        ]
    )
    func followsServer(state: AICapabilityState, available: Bool, onDevice: Bool, entry: Bool) {
        let gate = AICapabilityGate(account: AICaps.block([.coach: state]))
        #expect(gate.isAvailable(.coach) == available)
        #expect(gate.allowsOnDevice(.coach) == onDevice)
        #expect(gate.offersEntryPoint(.coach) == entry)
        // Other capabilities are untouched.
        #expect(gate.isAvailable(.briefing))
    }

    @Test("A reason next to available:true contradicts the contract and fails closed")
    func contradictionFailsClosed() {
        let odd = AICapabilityState(available: true, reason: .operatorDisabled, onDeviceAllowed: true)
        #expect(!odd.isAvailable)
    }

    // MARK: - Live shadow for the on-device actors

    @Test("The reader mirrors apply / refusal / logout synchronously")
    func readerMirrors() {
        let gate = AICapabilityGate()
        let reader = gate.reader
        #expect(reader.allowsOnDevice(.briefing))

        gate.apply(AICaps.block([.briefing: AICaps.operatorDisabled]))
        #expect(!reader.allowsOnDevice(.briefing))
        #expect(reader.isAvailable(.coach))

        gate.clearOnLogout()
        #expect(reader.allowsOnDevice(.briefing))
    }

    @Test("Logout (ModuleGate.clearOnLogout) drops the previous account's `ai` block")
    func logoutClearsBlock() {
        let gate = AICapabilityGate(account: AICaps.block([.coach: AICaps.operatorDisabled]))
        let moduleGate = ModuleGate()
        moduleGate.aiCapabilityGate = gate
        moduleGate.clearOnLogout()
        #expect(!gate.reportsCapabilities)
        #expect(gate.offersEntryPoint(.coach))
    }

    // MARK: - Refusal mirror

    @Test("A refusal closes the named capability until the next /me load")
    func refusalOverridesUntilReload() {
        let gate = AICapabilityGate(account: AICaps.block())
        gate.applyRefusal(AIRefusal(errorCode: "assistant.disabled.coach", capability: .coach, reason: .operatorDisabled))
        #expect(!gate.offersEntryPoint(.coach))
        #expect(!gate.reader.allowsOnDevice(.coach))
        #expect(gate.isAvailable(.briefing))

        gate.apply(AICaps.block())
        #expect(gate.offersEntryPoint(.coach))
    }

    @Test("A refusal on a pre-v1.39 server (no block) still closes the switch's capabilities")
    func refusalWorksInLegacyMode() {
        let gate = AICapabilityGate()
        gate.applyRefusal(AIRefusal(errorCode: "assistant.disabled.briefing"))
        #expect(!gate.isAvailable(.briefing))
        #expect(!gate.isAvailable(.periodNarrative))
        #expect(gate.isAvailable(.coach))
        #expect(!gate.reader.allowsOnDevice(.briefing))
        #expect(gate.reader.allowsOnDevice(.coach))
    }

    @Test("`ai.provider.none` closes the server path but keeps the device")
    func providerNoneKeepsDevice() {
        let gate = AICapabilityGate(account: AICaps.block())
        gate.applyRefusal(AIRefusal(errorCode: "ai.provider.none", capability: .documentAi, httpStatus: 422))
        #expect(!gate.isAvailable(.documentAi))
        #expect(gate.allowsOnDevice(.documentAi))
    }

    // MARK: - Update path: a 1.0.3 installation's cached flags

    /// The keys a pre-#115 build could have persisted: the UserDefaults stub
    /// (`UserDefaultsFeatureFlagsService`, key `feature_flag.<raw>`) was the
    /// default flag source of every on-device assistant service.
    private static let legacyKeys = [
        "feature_flag.assistant.briefing",
        "feature_flag.assistant.coach",
        "feature_flag.assistant.trend",
        "feature_flag.assistant.insights"
    ]

    @Test("Cached `assistant.*` = false from an older build gates nothing after the update")
    func legacyCachedFlagsDoNotGate() async {
        let defaults = UserDefaults.standard
        for key in Self.legacyKeys {
            defaults.set(false, forKey: key)
        }
        defer {
            for key in Self.legacyKeys {
                defaults.removeObject(forKey: key)
            }
        }

        // Every on-device service built with its default capability source —
        // exactly how `PhotoOfMedSheet`, previews and older call sites build
        // them — ignores the stale keys.
        let briefing = await OnDeviceBriefingService().generate(
            measurements: [], healthScore: nil, locale: Locale(identifier: "de_DE")
        )
        #expect(briefing.fallbackReason != .capabilityNotAllowed)
        let coach = await MiniCoachService().respond(
            to: "Was ist mein letztes Gewicht?", context: MiniCoachContext(), locale: Locale(identifier: "de_DE")
        )
        #expect(coach.disposition != .capabilityNotAllowed)
        let extraction = await MedicationExtractionService().extract(from: "Metformin 500 mg")
        #expect(extraction.fallbackReason != .capabilityNotAllowed)
        let reminder = await SmartReminderPhraseService().generate(
            context: ReminderPhraseContext(medicationName: "Trulicity", slot: .noon)
        )
        #expect(reminder.fallbackReason != .capabilityNotAllowed)

        // The gate an updated installation starts with reads open, too.
        let gate = AICapabilityGate()
        #expect(gate.offersEntryPoint(.coach))
        #expect(gate.reader.allowsOnDevice(.briefing))
    }

    @Test("The local flag store carries no assistant key any more")
    func flagStoreHasNoAssistantKeys() {
        #expect(FeatureFlag.allCases.allSatisfy { !$0.rawValue.hasPrefix("assistant.") })
        let store = FeatureFlagsStore()
        #expect(store.isEnabled(.enableDailyStats))
        #expect(store.isEnabled(.cycleTracking))
    }
}
