#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("HealthKitAvailabilityPolicy: only phones read Apple Health")
    struct HealthKitAvailabilityPolicyTests {
        @Test("phone and Duo (both `.phone`) read HealthKit and offer everything")
        func phoneReads() {
            let policy = HealthKitAvailabilityPolicy(idiom: .phone)
            #expect(policy.readsHealthKit)
            #expect(policy.offersAuthorization)
            #expect(policy.registersHealthKitBackgroundTask)
            #expect(policy.onboardingIncludesHealthKitStep)
        }

        @Test("iPad reads nothing: no permission, no switch, no background task, no onboarding step")
        func padReadsNothing() {
            let policy = HealthKitAvailabilityPolicy(idiom: .pad)
            #expect(!policy.readsHealthKit)
            #expect(!policy.offersAuthorization)
            #expect(!policy.registersHealthKitBackgroundTask)
            #expect(!policy.onboardingIncludesHealthKitStep)
        }

        @Test("the profile the app root builds drives the policy, not a global")
        func profileDrivesPolicy() {
            let pad = DeviceProfile(idiom: .pad, model: "iPad")
            let duo = DeviceProfile(idiom: .phone, model: "iPhone")
            #expect(!HealthKitAvailabilityPolicy(idiom: pad.idiom).readsHealthKit)
            #expect(HealthKitAvailabilityPolicy(idiom: duo.idiom).readsHealthKit)
            #expect(DeviceProfile.phone.idiom == .phone)
        }

        @Test("the background coordinator carries the policy's answer for the processing task")
        func coordinatorRegistration() {
            let phone = BackgroundSyncCoordinator(healthKit: nil, registersHealthKitTask: true)
            let pad = BackgroundSyncCoordinator(healthKit: nil, registersHealthKitTask: false)
            #expect(phone.registersHealthKitTask)
            #expect(!pad.registersHealthKitTask)
        }
    }

#endif
