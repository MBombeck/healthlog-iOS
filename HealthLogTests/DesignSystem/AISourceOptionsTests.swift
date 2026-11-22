import Foundation
@testable import HealthLog
import Testing

/// Pins the capability-aware option-list computation that drives
/// ``AISourceChoicePicker``. The decision logic lives in the pure
/// ``AISourceOptions/offered(onDeviceAvailability:)`` function (not in the
/// View) so the matrix is unit-verifiable.
///
/// Contract under test (D4 hide-permanent / disable-recoverable):
/// - `.none` is always offered and available.
/// - `.online` (External AI) is always offered.
/// - `.onDevice` hidden on permanent incapability (`.deviceNotEligible` /
///   `.unsupported`); shown disabled-with-reason on recoverable
///   (`.appleIntelligenceNotEnabled` → recovery deep-link, `.modelNotReady` →
///   passive); available on `.available`.
/// - `.byoKey` ("Own key") is offered + available (v0.13 W4 un-gated it).
@Suite("AISourceOptions — on-device capability matrix (W3)")
@MainActor
struct AISourceOptionsTests {
    private func modes(_ availability: LocalLLMService.Availability) -> [AIMode] {
        AISourceOptions.offered(onDeviceAvailability: availability)
            .map(\.mode)
    }

    // MARK: - `.none` always present

    @Test("None is always offered and available")
    func noneAlwaysAvailable() {
        for availability in allAvailabilities {
            let options = AISourceOptions.offered(onDeviceAvailability: availability)
            let none = options.first { $0.mode == .none }
            #expect(none != nil)
            #expect(none?.state == .available)
        }
    }

    // MARK: - `.byoKey` offered (W4 un-gate)

    @Test("byoKey is offered and available (W4)")
    func byoKeyOffered() {
        for availability in allAvailabilities {
            let option = AISourceOptions
                .offered(onDeviceAvailability: availability)
                .first { $0.mode == .byoKey }
            #expect(option != nil)
            #expect(option?.state == .available)
        }
    }

    // MARK: - External AI (online)

    @Test("External AI offered")
    func externalOffered() {
        #expect(modes(.available).contains(.online))
    }

    // MARK: - On-device — capability-gated

    @Test("On-device available card when model is available")
    func onDeviceAvailable() {
        let option = AISourceOptions
            .offered(onDeviceAvailability: .available)
            .first { $0.mode == .onDevice }
        #expect(option?.state == .available)
    }

    @Test("On-device hidden on permanently incapable hardware")
    func onDeviceHiddenPermanent() {
        for availability in [LocalLLMService.Availability.deviceNotEligible, .unsupported] {
            #expect(!modes(availability).contains(.onDevice))
        }
    }

    @Test("On-device disabled-with-recovery when Apple Intelligence is off")
    func onDeviceDisabledAIOff() {
        let option = AISourceOptions
            .offered(onDeviceAvailability: .appleIntelligenceNotEnabled)
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
            .offered(onDeviceAvailability: .modelNotReady)
            .first { $0.mode == .onDevice }
        guard case let .disabledWithReason(reason, recovery) = option?.state else {
            Issue.record("Expected disabledWithReason for modelNotReady")
            return
        }
        #expect(!reason.isEmpty)
        #expect(recovery == nil) // passive — nothing to tap
    }

    // MARK: - Full column shape

    @Test("Capable device offers exactly {none, onDevice, online, byoKey}")
    func capableShape() {
        #expect(modes(.available) == [.none, .onDevice, .online, .byoKey])
    }

    @Test("Ineligible device offers exactly {none, online, byoKey}")
    func ineligibleShape() {
        #expect(modes(.deviceNotEligible) == [.none, .online, .byoKey])
    }

    // MARK: - Onboarding default-selection (operator review)

    /// `AISourceStep.shouldDefaultToOnline` pre-selects External AI for an
    /// undecided user only when the server has a provider AND `.online` is an
    /// available (selectable) card — never a disabled/absent one.
    @Test("Default-to-online: true when provider configured + online available")
    func defaultOnlineWhenProviderAndAvailable() {
        let options = AISourceOptions.offered(onDeviceAvailability: .available)
        #expect(AISourceStep.shouldDefaultToOnline(providerConfigured: true, options: options))
    }

    @Test("Default-to-online: false when no provider configured, even if online offered")
    func noDefaultOnlineWhenNoProvider() {
        let options = AISourceOptions.offered(onDeviceAvailability: .available)
        #expect(!AISourceStep.shouldDefaultToOnline(providerConfigured: false, options: options))
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
