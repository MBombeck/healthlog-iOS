import Foundation
@testable import HealthLog
import Testing

/// v0.13 W3 — pins the mode- + capability-aware option-list computation that
/// drives ``AISourceChoicePicker``. The decision logic lives in the pure
/// ``AISourceOptions/offered(operatingMode:onDeviceAvailability:)`` function
/// (not in the View) so the matrix is unit-verifiable.
///
/// Contract under test (D2 mode axis · D4 hide-permanent / disable-recoverable):
/// - `.none` is always offered, available, every mode.
/// - `.online` (External AI) only in `.paired`; dropped in `.standalone`.
/// - `.onDevice` hidden on permanent incapability (`.deviceNotEligible` /
///   `.unsupported`); shown disabled-with-reason on recoverable
///   (`.appleIntelligenceNotEnabled` → recovery deep-link, `.modelNotReady` →
///   passive); available on `.available`.
/// - `.byoKey` ("Own key") is offered + available in BOTH modes (v0.13 W4
///   un-gated it; mode-invariant client-side path).
@Suite("AISourceOptions — mode × on-device capability matrix (W3)")
@MainActor
struct AISourceOptionsTests {
    private func modes(
        _ mode: BackendAvailability.Mode,
        _ availability: LocalLLMService.Availability
    ) -> [AIMode] {
        AISourceOptions.offered(operatingMode: mode, onDeviceAvailability: availability)
            .map(\.mode)
    }

    // MARK: - `.none` always present

    @Test("None is always offered and available in both modes")
    func noneAlwaysAvailable() {
        for mode in [BackendAvailability.Mode.paired, .standalone] {
            for availability in allAvailabilities {
                let options = AISourceOptions.offered(
                    operatingMode: mode,
                    onDeviceAvailability: availability
                )
                let none = options.first { $0.mode == .none }
                #expect(none != nil)
                #expect(none?.state == .available)
            }
        }
    }

    // MARK: - `.byoKey` offered in both modes (W4 un-gate)

    @Test("byoKey is offered and available in both operating modes (W4)")
    func byoKeyOfferedBothModes() {
        for mode in [BackendAvailability.Mode.paired, .standalone] {
            for availability in allAvailabilities {
                let option = AISourceOptions
                    .offered(operatingMode: mode, onDeviceAvailability: availability)
                    .first { $0.mode == .byoKey }
                #expect(option != nil)
                #expect(option?.state == .available)
            }
        }
    }

    // MARK: - External AI (online) — mode-gated

    @Test("External AI offered in paired mode")
    func externalOfferedPaired() {
        #expect(modes(.paired, .available).contains(.online))
    }

    @Test("External AI dropped in standalone mode")
    func externalDroppedStandalone() {
        #expect(!modes(.standalone, .available).contains(.online))
        #expect(!modes(.standalone, .appleIntelligenceNotEnabled).contains(.online))
    }

    // MARK: - On-device — capability-gated (D4)

    @Test("On-device available card when model is available")
    func onDeviceAvailable() {
        let option = AISourceOptions
            .offered(operatingMode: .paired, onDeviceAvailability: .available)
            .first { $0.mode == .onDevice }
        #expect(option?.state == .available)
    }

    @Test("On-device hidden on permanently incapable hardware")
    func onDeviceHiddenPermanent() {
        for availability in [LocalLLMService.Availability.deviceNotEligible, .unsupported] {
            #expect(!modes(.paired, availability).contains(.onDevice))
            #expect(!modes(.standalone, availability).contains(.onDevice))
        }
    }

    @Test("On-device disabled-with-recovery when Apple Intelligence is off")
    func onDeviceDisabledAIOff() {
        let option = AISourceOptions
            .offered(operatingMode: .paired, onDeviceAvailability: .appleIntelligenceNotEnabled)
            .first { $0.mode == .onDevice }
        guard case let .disabledWithReason(reason, recovery) = option?.state else {
            Issue.record("Expected disabledWithReason for appleIntelligenceNotEnabled")
            return
        }
        #expect(!reason.isEmpty)
        #expect(recovery == .openAppleIntelligenceSettings)
    }

    @Test("On-device disabled-passive when model is downloading")
    func onDeviceDisabledModelNotReady() {
        let option = AISourceOptions
            .offered(operatingMode: .paired, onDeviceAvailability: .modelNotReady)
            .first { $0.mode == .onDevice }
        guard case let .disabledWithReason(reason, recovery) = option?.state else {
            Issue.record("Expected disabledWithReason for modelNotReady")
            return
        }
        #expect(!reason.isEmpty)
        #expect(recovery == nil) // passive — nothing to tap
    }

    // MARK: - Full column shape

    @Test("Standalone + capable offers exactly {none, onDevice, byoKey}")
    func standaloneCapableShape() {
        #expect(modes(.standalone, .available) == [.none, .onDevice, .byoKey])
    }

    @Test("Paired + capable offers exactly {none, onDevice, online, byoKey}")
    func pairedCapableShape() {
        #expect(modes(.paired, .available) == [.none, .onDevice, .online, .byoKey])
    }

    @Test("Standalone + ineligible device offers exactly {none, byoKey}")
    func standaloneIneligibleShape() {
        #expect(modes(.standalone, .deviceNotEligible) == [.none, .byoKey])
    }

    @Test("Paired + ineligible device offers exactly {none, online, byoKey}")
    func pairedIneligibleShape() {
        #expect(modes(.paired, .deviceNotEligible) == [.none, .online, .byoKey])
    }

    // MARK: - Onboarding default-selection (operator review)

    /// `AISourceStep.shouldDefaultToOnline` pre-selects External AI for an
    /// undecided user only when the server has a provider AND `.online` is an
    /// available (selectable) card — never a disabled/absent one.
    @Test("Default-to-online: true when provider configured + online available (paired)")
    func defaultOnlineWhenProviderAndAvailable() {
        let options = AISourceOptions.offered(operatingMode: .paired, onDeviceAvailability: .available)
        #expect(AISourceStep.shouldDefaultToOnline(providerConfigured: true, options: options))
    }

    @Test("Default-to-online: false when no provider configured, even if online offered")
    func noDefaultOnlineWhenNoProvider() {
        let options = AISourceOptions.offered(operatingMode: .paired, onDeviceAvailability: .available)
        #expect(!AISourceStep.shouldDefaultToOnline(providerConfigured: false, options: options))
    }

    @Test("Default-to-online: false in standalone (online card not offered)")
    func noDefaultOnlineStandalone() {
        let options = AISourceOptions.offered(operatingMode: .standalone, onDeviceAvailability: .available)
        // Even if a provider were somehow flagged, the .online card is absent.
        #expect(!AISourceStep.shouldDefaultToOnline(providerConfigured: true, options: options))
    }

    @Test("Default-to-online: false when online card is present but disabled")
    func noDefaultOnlineWhenDisabled() {
        // Construct a list where .online is disabled-with-reason (defensive — the
        // pure function must never pre-select a dead card regardless of how the
        // host built the options).
        let options: [AISourceOption] = [
            AISourceOption(mode: .none, state: .available),
            AISourceOption(
                mode: .online,
                state: .disabledWithReason(reason: "Server offline", recovery: nil)
            )
        ]
        #expect(!AISourceStep.shouldDefaultToOnline(providerConfigured: true, options: options))
    }

    // MARK: - Helpers

    private var allAvailabilities: [LocalLLMService.Availability] {
        [.available, .appleIntelligenceNotEnabled, .modelNotReady, .deviceNotEligible, .unsupported]
    }
}
