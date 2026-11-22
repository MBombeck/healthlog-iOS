import CryptoKit
import Foundation
@testable import HealthLog
import Testing

@Suite("App Review configuration")
struct AppReviewConfigurationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(relativePath))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    @Test("release configuration cannot inject an operator identity")
    func releaseConfigurationIsOperatorNeutral() throws {
        let project = try text("project.yml")
        #expect(!project.contains("Config/local.yml"))
        #expect(!project.contains("HL_LOCAL_CONFIG"))

        let info = try plist("HealthLog/Resources/Info.plist")
        #expect(info["HLBaseURL"] == nil)
        #expect(info["HLPinnedHosts"] == nil)
        #expect(info["HLPinnedSPKIHashes"] == nil)
        #expect(info["HLPasskeyRelyingPartyHosts"] == nil)

        let entitlements = try plist("HealthLog/Resources/HealthLog.entitlements")
        #expect(entitlements["com.apple.developer.associated-domains"] == nil)
    }

    @Test("release UI contains only supported, neutrally named assistant providers")
    func assistantProviderSurfaceIsCompleteAndNeutral() {
        #expect(AIProvider.allCases.count == 5)
        #expect(AIProvider.configurableCases == [.anthropic, .openai, .local])
        #expect(AIProvider.anthropic.label == "Anthropic")
        #expect(AIProvider.openai.label == "OpenAI")
    }

    @Test("review sign-in has no embedded credential or one-tap demo path")
    func reviewerSignInIsOperatorSuppliedAndFailClosed() throws {
        let productionRoots = ["HealthLog", "HealthLogWatch", "NotificationServiceExtension"]
        let forbiddenSymbols = [
            "demoIdentifier", "demoPassword", "demoServerURL", "loginDemo",
            "demoAlwaysAvailableInDebug", "demoLoginAvailable",
            "onboarding.demoCTA", "onboarding.modeDemo"
        ]
        let retiredCredentialFingerprint = "983987033f0e117011e531dc33ad9bb15290bba41a414d830fb5cbdbcda2ff17"
        let tokenPattern = try NSRegularExpression(pattern: #"[A-Za-z0-9][A-Za-z0-9._%+@:-]{5,}"#)
        var scannedFiles = 0

        for relativeRoot in productionRoots {
            let root = Self.root.appendingPathComponent(relativeRoot)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { continue }

            for case let file as URL in enumerator where file.pathExtension == "swift" {
                scannedFiles += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                let relativePath = file.path.replacingOccurrences(of: Self.root.path + "/", with: "")

                for symbol in forbiddenSymbols {
                    #expect(!source.contains(symbol), "embedded reviewer demo symbol in \(relativePath): \(symbol)")
                }

                let range = NSRange(source.startIndex ..< source.endIndex, in: source)
                for match in tokenPattern.matches(in: source, range: range) {
                    guard let tokenRange = Range(match.range, in: source) else { continue }
                    let digest = SHA256.hash(data: Data(source[tokenRange].utf8))
                        .map { String(format: "%02x", $0) }
                        .joined()
                    #expect(
                        digest != retiredCredentialFingerprint,
                        "retired reviewer credential fingerprint found in \(relativePath)"
                    )
                }
            }
        }
        #expect(scannedFiles > 100, "production-source guard did not see the app tree")
    }

    @Test("generated app configuration declares only the intended background work")
    func intendedBackgroundConfiguration() throws {
        let info = try plist("HealthLog/Resources/Info.plist")
        let modes = try Set(#require(info["UIBackgroundModes"] as? [String]))
        #expect(modes == ["remote-notification", "processing", "fetch"])

        let identifiers = try Set(#require(info["BGTaskSchedulerPermittedIdentifiers"] as? [String]))
        #expect(identifiers == [
            BackgroundSyncCoordinator.bgTaskIdentifier,
            BackgroundSyncCoordinator.bgRefreshTaskIdentifier,
            "edu.stanford.spezi.scheduler.notifications-scheduling"
        ])
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
        // 1.7 (#180) — the Labs Health Records sync reads lab results, so
        // the purpose string and the entitlement are declared together.
        #expect((info["NSHealthClinicalHealthRecordsShareUsageDescription"] as? String)?.isEmpty == false)

        let entitlements = try plist("HealthLog/Resources/HealthLog.entitlements")
        #expect(entitlements["com.apple.developer.healthkit"] as? Bool == true)
        #expect(entitlements["com.apple.developer.healthkit.background-delivery"] as? Bool == true)
        #expect(entitlements["com.apple.developer.healthkit.access"] as? [String] == ["health-records"])
    }

    @Test("German and English purpose strings disclose the actual HealthKit and document flows")
    func localizedPurposeStringsMatchBehavior() throws {
        let expectedKeys = [
            "NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription",
            "NSFaceIDUsageDescription", "NSUserNotificationsUsageDescription",
            "NSAlarmKitUsageDescription", "NSSpeechRecognitionUsageDescription",
            "NSMicrophoneUsageDescription", "NSCameraUsageDescription",
            "NSBluetoothAlwaysUsageDescription", "NSHealthClinicalHealthRecordsShareUsageDescription"
        ]
        let german = try text("HealthLog/Resources/de.lproj/InfoPlist.strings")
        let english = try text("HealthLog/Resources/en.lproj/InfoPlist.strings")

        for key in expectedKeys {
            #expect(german.contains("\"\(key)\""), "missing German purpose for \(key)")
            #expect(english.contains("\"\(key)\""), "missing English purpose for \(key)")
        }
        for disclosure in ["EKGs", "Medikamente", "Dokumententresor", "Server"] {
            #expect(german.contains(disclosure), "German disclosure omits \(disclosure)")
        }
        for disclosure in ["ECGs", "medications", "document vault", "server"] {
            #expect(english.localizedCaseInsensitiveContains(disclosure), "English disclosure omits \(disclosure)")
        }
        #expect(!english.contains("Gesundheitsdaten"), "English locale must not fall back to German copy")
    }

    @Test("privacy manifest is non-tracking and covers every collected category")
    func privacyManifestContract() throws {
        let manifest = try plist("HealthLog/Resources/PrivacyInfo.xcprivacy")
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)

        let entries = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let categories = Set(entries.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        #expect(categories == [
            "NSPrivacyCollectedDataTypeName",
            "NSPrivacyCollectedDataTypeHealth",
            "NSPrivacyCollectedDataTypeFitness",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypeSensitiveInfo",
            "NSPrivacyCollectedDataTypeDeviceID",
            "NSPrivacyCollectedDataTypePhotosorVideos", "NSPrivacyCollectedDataTypePreciseLocation"
        ])
        for entry in entries {
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(!(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []).isEmpty)
        }

        let accessed = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = Dictionary(uniqueKeysWithValues: accessed.compactMap { item -> (String, Set<String>)? in
            guard let type = item["NSPrivacyAccessedAPIType"] as? String,
                  let values = item["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return nil }
            return (type, Set(values))
        })
        #expect(reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1", "1C8F.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1", "DDA9.1"])
        #expect(reasons["NSPrivacyAccessedAPICategorySystemBootTime"] == ["35F9.1"])
    }

    @Test("notification privacy extension is a generated, embedded host dependency")
    func notificationServiceExtensionIsEmbedded() throws {
        let project = try text("project.yml")
        let generated = try text("HealthLog.xcodeproj/project.pbxproj")
        #expect(project.contains("- target: HealthLogNotificationService"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: dev.healthlog.app.notification-service"))
        #expect(project.contains("CFBundleShortVersionString: $(MARKETING_VERSION)"))
        #expect(project.contains("CFBundleVersion: $(CURRENT_PROJECT_VERSION)"))
        #expect(project.contains("- path: NotificationServiceExtension/Resources/PrivacyInfo.xcprivacy"))
        #expect(generated.contains("HealthLogNotificationService.appex in Embed Foundation Extensions"))
        #expect(generated.contains("dev.healthlog.app.notification-service"))
        #expect(generated.contains("PrivacyInfo.xcprivacy"))

        let hostInfo = try plist("HealthLog/Resources/Info.plist")
        let extensionInfo = try plist("NotificationServiceExtension/Resources/Info.plist")
        #expect(extensionInfo["CFBundleShortVersionString"] as? String == hostInfo["CFBundleShortVersionString"] as? String)
        #expect(extensionInfo["CFBundleVersion"] as? String == hostInfo["CFBundleVersion"] as? String)

        let extensionEntitlements = try plist("NotificationServiceExtension/NotificationServiceExtension.entitlements")
        #expect(extensionEntitlements["com.apple.security.application-groups"] as? [String] == ["group.dev.healthlog.app"])
        let extensionManifest = try plist("NotificationServiceExtension/Resources/PrivacyInfo.xcprivacy")
        #expect(extensionManifest["NSPrivacyTracking"] as? Bool == false)
        // It reads the App-Group suite the app writes, and nothing else of the
        // required-reason set.
        let extensionAPIs = (extensionManifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? []
        #expect(extensionAPIs.compactMap { $0["NSPrivacyAccessedAPIType"] as? String } == ["NSPrivacyAccessedAPICategoryUserDefaults"])
        #expect(extensionAPIs.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["CA92.1", "1C8F.1"])
    }

    @Test("Release policy retires persisted raw-HR schedules without rewriting an in-progress UTC day")
    func productionRawHeartRatePolicyFailsClosed() throws {
        let suite = "test.appreview.rawhr.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: String) throws -> Date {
            try #require(formatter.date(from: value))
        }
        let user = "policy-fixture"
        let cutoverNow = try date("2026-06-21T14:00:00.000Z")
        let rawTap = try date("2026-06-25T14:00:00.000Z")
        let releaseNow = try date("2026-06-28T09:00:00.000Z")
        let bucketMidnight = try date("2026-06-29T00:00:00.000Z")

        HRBucketCutoverStore.cutover(
            userId: user,
            now: cutoverNow,
            defaults: defaults
        )
        HRUploadModeSchedule.setDesiredMode(
            .raw,
            userId: user,
            now: rawTap,
            defaults: defaults,
            rawExperimentAvailable: true
        )

        #expect(HRUploadModeSchedule.mode(
            at: releaseNow,
            userId: user,
            now: releaseNow,
            defaults: defaults,
            rawExperimentAvailable: false
        ) == .raw)
        let changes = HRUploadModeSchedule.changes(userId: user, defaults: defaults)
        #expect(changes.last?.mode == .buckets)
        #expect(changes.last?.effectiveFrom == bucketMidnight)
        #expect(HRUploadModeSchedule.mode(
            at: bucketMidnight,
            userId: user,
            now: releaseNow,
            defaults: defaults,
            rawExperimentAvailable: false
        ) == .buckets)
        #expect(HRUploadModeSchedule.setDesiredMode(
            .raw,
            userId: user,
            now: releaseNow,
            defaults: defaults,
            rawExperimentAvailable: false
        ) == nil)

        let pendingUser = "pending-policy-fixture"
        HRBucketCutoverStore.cutover(userId: pendingUser, now: cutoverNow, defaults: defaults)
        HRUploadModeSchedule.setDesiredMode(
            .raw,
            userId: pendingUser,
            now: rawTap,
            defaults: defaults,
            rawExperimentAvailable: true
        )
        #expect(HRUploadModeSchedule.changes(userId: pendingUser, defaults: defaults).last?.mode == .raw)
        #expect(HRUploadModeSchedule.mode(
            at: rawTap,
            userId: pendingUser,
            now: rawTap,
            defaults: defaults,
            rawExperimentAvailable: false
        ) == .buckets)
        #expect(!HRUploadModeSchedule.changes(userId: pendingUser, defaults: defaults).contains { $0.mode == .raw })

        let flags = try text("HealthLog/App/FeatureFlags.swift")
        #expect(flags.contains("rawHeartRateExperimentAvailable = false"))
        // The release switch that consumed the flag is deleted, not
        // disabled, so this half is now an inventory assertion over the whole
        // Settings tree rather than a read of one file. Reading a file to prove
        // it fails closed stops meaning anything the moment the file is gone.
        let schedule = try text("HealthLog/Services/HRUploadModeSchedule.swift")
        #expect(schedule.contains("rawExperimentAvailable: Bool = FeatureFlags.rawHeartRateExperimentAvailable"))
        let pulseHits = try Self.releaseSettingsRawHeartRateHits()
        #expect(pulseHits.isEmpty, "release Settings can still schedule a raw heart-rate upload: \(pulseHits)")
    }

    @Test("all HealthKit writes remain on reviewed user-entered or approved-device paths")
    func healthKitWriteSitesStayAllowlisted() throws {
        let expected: Set = [
            "HealthLog/Services/Devices/DeviceReadingForwarder.swift",
            "HealthLog/Services/HealthKitService.swift",
            "HealthLog/Services/HealthKit/CycleHealthKitWriter.swift",
            "HealthLog/Services/HealthKit/HealthKitService+Write.swift"
        ]
        let healthLog = Self.root.appendingPathComponent("HealthLog")
        let enumerator = try #require(FileManager.default.enumerator(
            at: healthLog,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var actual = Set<String>()
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("import HealthKit"), source.contains("store.save(") else { continue }
            actual.insert(file.path.replacingOccurrences(of: Self.root.path + "/", with: ""))
        }
        #expect(actual == expected, "HealthKit write surface changed; audit the new/removed save site")

        #expect(try text("HealthLog/Services/HealthKitService.swift").contains("HKMetadataKeyWasUserEntered: true"))
        #expect(try text("HealthLog/Services/HealthKit/CycleHealthKitWriter.swift").contains("HKMetadataKeyWasUserEntered: true"))
        let write = try text("HealthLog/Services/HealthKit/HealthKitService+Write.swift")
        #expect(write.contains("guard measurement.source == .manual else { return }"))
        #expect(write.contains("authorizationStatus(for: $0.sampleType) == .sharingAuthorized"))
    }
}

extension AppReviewConfigurationTests {
    /// Guideline 5.1.1(v): the deletion entry point sits in a SwiftUI body, so
    /// its Release reachability is checked at the source.
    @Test("account deletion is reachable in Release")
    func accountDeletionContractIsComplete() throws {
        let accountScreen = try text("HealthLog/Screens/Settings/Sub/SettingsAccountScreen.swift")
        #expect(accountScreen.contains("deleteAccountRow"))
        #expect(accountScreen.contains("DeleteAccountScreen()"))
        #expect(!accountScreen.contains("#if DEBUG"))
    }
}

extension AppReviewConfigurationTests {
    @Test("health-bearing local stores are excluded from backup and declare no iCloud container")
    func healthPayloadsAreNotICloudBacked() throws {
        let entitlements = try plist("HealthLog/Resources/HealthLog.entitlements")
        #expect(!entitlements.keys.contains { $0.localizedCaseInsensitiveContains("icloud") })
        #expect(!entitlements.keys.contains { $0.localizedCaseInsensitiveContains("ubiquity") })

        let exclusion = try text("HealthLog/Util/SensitiveDataBackupExclusion.swift")
        #expect(exclusion.contains("isExcludedFromBackupKey"))
        #expect(exclusion.contains("verificationFailed"))
        #expect(exclusion.contains("fileManager.removeItem(at: item)"), "standalone PHI writes must fail closed")

        let directoryStores = [
            "HealthLog/Cache/SWRCache.swift",
            "HealthLog/Repositories/OutboxStore.swift",
            "HealthLog/Screens/GLP1/GLP1LocalStore.swift",
            "HealthLog/Services/AI/CoachChatStore.swift",
            "HealthLog/Services/HealthKitDailyStatsCache.swift",
            "HealthLog/Services/AI/OnDeviceBriefingCache.swift",
            "HealthLog/Screens/Insights/TrendObservationCard+OnDevice.swift"
        ]
        for path in directoryStores {
            #expect(
                try text(path).contains("SensitiveDataBackupExclusion.prepareDirectory"),
                "health-bearing directory store lost backup exclusion: \(path)"
            )
        }
        let speziScheduler = try text("HealthLog/Services/HealthKit/HealthLogSpeziDelegate.swift")
            + text("HealthLog/Services/HealthKit/SpeziSchedulerStorage.swift")
        #expect(speziScheduler.contains("static let directoryName = \"SpeziScheduler\""))
        #expect(speziScheduler.contains("documentsDirectory.appendingPathComponent(directoryName"))
        #expect(speziScheduler.contains("SensitiveDataBackupExclusion.prepareDirectory"))
        #expect(speziScheduler.contains("Scheduler(persistence: .onDisk(directory: directory))"))
        #expect(speziScheduler.contains("SpeziSchedulerStorage.modules(for: schedulerLaunchPlan)"))
        #expect(!speziScheduler.contains("Refusing to open SpeziScheduler"), "launch must not trap on a sealed store (292)")
        let standalonePayloads = [
            "HealthLog/WidgetShared/WidgetPendingConfirmStore.swift",
            "HealthLog/WidgetShared/WidgetSnapshot.swift",
            "HealthLogWatch/Shared/WatchSnapshotStore.swift"
        ]
        for path in standalonePayloads {
            #expect(
                try text(path).contains("SensitiveDataBackupExclusion.secureCreatedItem"),
                "health-bearing payload lost backup exclusion: \(path)"
            )
        }
    }
}

extension AppReviewConfigurationTests {
    @Test("account-boundary transition queues authentication behind deletion ownership")
    @MainActor
    func accountBoundaryTransitionSerializesAuthentication() async {
        let transition = AuthAccountBoundaryTransition()
        await transition.acquire(.deletedAccount)
        #expect(transition.deletionOwnsTransition)

        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        let authentication = Task { @MainActor in
            continuation.yield("attempting")
            await transition.acquire(.authentication)
            continuation.yield("admitted")
        }
        var eventIterator = events.makeAsyncIterator()

        #expect(await eventIterator.next() == "attempting")
        #expect(transition.deletionOwnsTransition)

        transition.release(.deletedAccount)
        #expect(await eventIterator.next() == "admitted")
        #expect(!transition.deletionOwnsTransition)

        transition.release(.authentication)
        await authentication.value
        continuation.finish()
    }
}
