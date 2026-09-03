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
    func assistantProviderSurfaceIsCompleteAndNeutral() throws {
        let model = try text("HealthLog/Models/Insight.swift")
        let screen = try text("HealthLog/Screens/Settings/AIProviderScreen.swift")
        let consent = try text("HealthLog/Screens/Settings/AIConsentSheet.swift")
        let token = try text("HealthLog/Models/ApiTokenDTO.swift")
        let mcp = try text("HealthLog/Screens/Settings/Sub/McpTokenSheets.swift")

        #expect(AIProvider.allCases.count == 5)
        #expect(model.contains("case .anthropic: \"Anthropic\""))
        #expect(screen.contains("Anthropic processes your insights"))
        #expect(consent.contains("case .anthropic: \"Anthropic\""))
        #expect(consent.contains("case .anthropic: \"Anthropic, PBC\""))
        #expect(token.contains("a third-party client"))
        #expect(mcp.contains("e.g. My health dashboard"))
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

        let auth = try text("HealthLog/Screens/Onboarding/ServerAuthStep.swift")
        #expect(auth.contains("@State private var email: String"))
        #expect(auth.contains("@State private var password: String"))
        #expect(auth.contains("onboarding.auth.field.email"))
        #expect(auth.contains("onboarding.auth.field.password"))
        #expect(auth.contains("await authStore.login(email: email, password: password)"))
        #expect(auth.contains("onboarding.passwordLoginCTA"))

        let journey = try text("HealthLogUITests/AuthJourneyUITest.swift")
        #expect(journey.contains("-uitest-auth-journey"))
        #expect(journey.contains("HermeticFixtures"))
        #expect(journey.contains("testPasswordLoginWithHealthKitDeniedReachesShell"))
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
        #expect(info["NSHealthClinicalHealthRecordsShareUsageDescription"] == nil)

        let entitlements = try plist("HealthLog/Resources/HealthLog.entitlements")
        #expect(entitlements["com.apple.developer.healthkit"] as? Bool == true)
        #expect(entitlements["com.apple.developer.healthkit.background-delivery"] as? Bool == true)
    }

    @Test("German and English purpose strings disclose the actual HealthKit and document flows")
    func localizedPurposeStringsMatchBehavior() throws {
        let expectedKeys = [
            "NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription",
            "NSFaceIDUsageDescription", "NSUserNotificationsUsageDescription",
            "NSAlarmKitUsageDescription", "NSSpeechRecognitionUsageDescription",
            "NSMicrophoneUsageDescription", "NSCameraUsageDescription",
            "NSPhotoLibraryUsageDescription", "NSBluetoothAlwaysUsageDescription"
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
        #expect(german.contains("Profilbild"))
        for disclosure in ["ECGs", "medications", "document vault", "server"] {
            #expect(english.localizedCaseInsensitiveContains(disclosure), "English disclosure omits \(disclosure)")
        }
        #expect(english.contains("profile picture"))
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
            "NSPrivacyCollectedDataTypePhotosorVideos"
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
        #expect(reasons["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1"])
        #expect(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"] == ["C617.1", "DDA9.1"])
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
        // 08-15 — the release switch that consumed the flag is deleted, not
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

        #expect(try text("HealthLog/Services/Devices/DeviceReadingForwarder.swift").contains("MeasurementsRecordedSheet` confirm step"))
        #expect(try text("HealthLog/Services/HealthKitService.swift").contains("HKMetadataKeyWasUserEntered: true"))
        #expect(try text("HealthLog/Services/HealthKit/CycleHealthKitWriter.swift").contains("HKMetadataKeyWasUserEntered: true"))
        let write = try text("HealthLog/Services/HealthKit/HealthKitService+Write.swift")
        #expect(write.contains("guard measurement.source == .manual else { return }"))
        #expect(write.contains("authorizationStatus(for: $0.sampleType) == .sharingAuthorized"))
    }
}

extension AppReviewConfigurationTests {
    // 09-08 — an App-Review contract assertion set. Each `#expect` is one
    // reviewable clause of the same guideline; splitting them into helper
    // functions would hide which clauses exist behind a call, which is the
    // opposite of what a compliance test is for.
    // function_body_length exception (owner: 09-08): exhaustive App-Review contract clause list.
    // swiftlint:disable function_body_length
    @Test("account deletion is reachable in Release and preserves exact server and return contracts")
    func accountDeletionContractIsComplete() throws {
        let accountScreen = try text("HealthLog/Screens/Settings/Sub/SettingsAccountScreen.swift")
        #expect(accountScreen.contains("deleteAccountCard"))
        #expect(accountScreen.contains("DeleteAccountScreen()"))
        #expect(!accountScreen.contains("#if DEBUG"))

        let service = try text("HealthLog/Services/AuthService.swift")
        #expect(service.contains("path: \"/api/settings/account\""))
        #expect(service.contains("method: .delete"))
        #expect(service.contains("confirm: \"DELETE_ACCOUNT\""))
        #expect(service.contains("maxRetries: 0"))
        #expect(service.contains("AIConsentStore.serverManagedScope"))
        #expect(service.contains("AIConsentStore.serverManagedDeclinedKey"))
        #expect(service.contains("nonisolated static func wipeDeletedAccountKeychain"))
        #expect(service.contains("Self.wipeDeletedAccountKeychain(using: keychain)"))
        #expect(service.contains("private var credentialPersistenceGeneration: UInt64 = 0"))
        #expect(service.contains("func invalidateAndWipeDeletedAccountCredentials()"))
        #expect(service.contains("func invalidateAndWipeSessionCredentials() throws -> String?"))
        #expect(!service.contains("invalidateCredentialPersistenceForDeletedAccount"))
        for accountBoundKey in [
            "KeychainKey.authToken", "KeychainKey.refreshToken", "KeychainKey.userID",
            "KeychainKey.userDisplayName", "KeychainKey.deviceID"
        ] {
            #expect(service.contains(accountBoundKey), "shared deletion wipe omits \(accountBoundKey)")
        }
        #expect(service.contains("for provider in AIProvider.allCases"))
        #expect(service.contains("for provider in BYOProviderID.allCases"))

        let nativeDeleteStart = try #require(service.range(of: "public func deleteAccount() async throws"))
        let nativeDeleteEnd = try #require(service.range(
            of: "private nonisolated static func wipeDeletedAccountKeychain",
            range: nativeDeleteStart.upperBound ..< service.endIndex
        ))
        let nativeDelete = String(service[nativeDeleteStart.lowerBound ..< nativeDeleteEnd.lowerBound])
        let nativeDeleteAccepted = try #require(nativeDelete.range(of: "try await api.sendVoid(deleteReq)"))
        let nativeWipe = try #require(nativeDelete.range(of: "invalidateAndWipeDeletedAccountCredentials()"))
        #expect(nativeDeleteAccepted.lowerBound < nativeWipe.lowerBound)
        #expect(!nativeDelete.contains("Self.wipeDeletedAccountKeychain"))

        let deletedTeardownStart = try #require(service.range(
            of: "func invalidateAndWipeDeletedAccountCredentials()"
        ))
        let deletedTeardownEnd = try #require(service.range(
            of: "func invalidateAndWipeSessionCredentials() throws -> String?",
            range: deletedTeardownStart.upperBound ..< service.endIndex
        ))
        let deletedTeardown = String(service[deletedTeardownStart.lowerBound ..< deletedTeardownEnd.lowerBound])
        let deletedGeneration = try #require(deletedTeardown.range(of: "credentialPersistenceGeneration &+= 1"))
        let deletedWipe = try #require(deletedTeardown.range(of: "Self.wipeDeletedAccountKeychain(using: keychain)"))
        #expect(deletedGeneration.lowerBound < deletedWipe.lowerBound)
        #expect(!deletedTeardown.contains("await"), "generation and deletion wipe must share one actor turn")

        let sessionTeardownStart = try #require(service.range(
            of: "func invalidateAndWipeSessionCredentials() throws -> String?"
        ))
        let sessionTeardownEnd = try #require(service.range(
            of: "// MARK: - Web-handoff login",
            range: sessionTeardownStart.upperBound ..< service.endIndex
        ))
        let sessionTeardown = String(service[sessionTeardownStart.lowerBound ..< sessionTeardownEnd.lowerBound])
        let sessionGeneration = try #require(sessionTeardown.range(of: "credentialPersistenceGeneration &+= 1"))
        let sessionRemoval = try #require(sessionTeardown.range(of: "try keychain.remove(forKey: key)"))
        #expect(sessionGeneration.lowerBound < sessionRemoval.lowerBound)
        #expect(!sessionTeardown.contains("await"), "generation and session wipe must share one actor turn")

        let logoutStart = try #require(service.range(of: "public func logout() async throws"))
        let logoutEnd = try #require(service.range(
            of: "public func setOnLogoutCleanup",
            range: logoutStart.upperBound ..< service.endIndex
        ))
        let logout = String(service[logoutStart.lowerBound ..< logoutEnd.lowerBound])
        #expect(logout.contains("try invalidateAndWipeSessionCredentials()"))

        let refreshStart = try #require(service.range(of: "public func refresh() async -> RefreshOutcome"))
        let refreshEnd = try #require(service.range(
            of: "// MARK: - Persistence",
            range: refreshStart.upperBound ..< service.endIndex
        ))
        let refresh = String(service[refreshStart.lowerBound ..< refreshEnd.lowerBound])
        let refreshCapture = try #require(refresh.range(
            of: "let capturedPersistenceGeneration = credentialPersistenceGeneration"
        ))
        let refreshValidation = try #require(refresh.range(
            of: "guard capturedPersistenceGeneration == credentialPersistenceGeneration"
        ))
        let refreshPersist = try #require(refresh.range(of: "try persist(session)"))
        #expect(refreshCapture.lowerBound < refreshValidation.lowerBound)
        #expect(refreshValidation.lowerBound < refreshPersist.lowerBound)
        #expect(!refresh.contains("beginAuthenticationTransition"))
        #expect(!refresh.contains("accountBoundaryTransition"))

        let deletionScreen = try text("HealthLog/Screens/Settings/DeleteAccountScreen.swift")
        #expect(deletionScreen.contains("authStore.markPendingWebDeletion()"))
        let webDeletion = try text("HealthLog/Stores/AuthStore+WebDeletion.swift")
        #expect(webDeletion.contains("func reconcilePendingWebDeletion() async"))
        #expect(webDeletion.contains("case .gone"))
        #expect(webDeletion.contains("localCleanupHook"))
        #expect(webDeletion.contains("pendingOwner != capturedOwner"))
        #expect(!webDeletion.contains("AuthService.wipeDeletedAccountKeychain"))
        #expect(webDeletion.contains("let capturedGeneration = authSessionGeneration"))
        #expect(webDeletion.contains("await beginDeletedAccountTransition()"))
        #expect(webDeletion.contains("defer { finishDeletedAccountTransition() }"))

        let suspendedProbe = try #require(webDeletion.range(of: "let outcome = await auth.probeAccountStatus()"))
        let ownerGuard = try #require(webDeletion.range(of: "currentMarkerOwner == pendingOwner"))
        let generationGuard = try #require(webDeletion.range(of: "authSessionGeneration == capturedGeneration"))
        let sharedWipe = try #require(webDeletion.range(
            of: "await auth.invalidateAndWipeDeletedAccountCredentials()"
        ))
        let anchorCleanup = try #require(webDeletion.range(
            of: "await runDeletedAccountOwnerCleanup(previousOwner: deletedAccountOwner)"
        ))
        let localCleanup = try #require(webDeletion.range(of: "await localCleanupHook?()"))
        let boundaryCompletion = try #require(webDeletion.range(of: "completeDeletedAccountBoundary()"))
        #expect(suspendedProbe.lowerBound < ownerGuard.lowerBound)
        #expect(suspendedProbe.lowerBound < generationGuard.lowerBound)
        #expect(ownerGuard.lowerBound < sharedWipe.lowerBound)
        #expect(generationGuard.lowerBound < sharedWipe.lowerBound)
        #expect(sharedWipe.lowerBound < anchorCleanup.lowerBound)
        #expect(anchorCleanup.lowerBound < localCleanup.lowerBound)
        #expect(localCleanup.lowerBound < boundaryCompletion.lowerBound)

        let authStore = try text("HealthLog/Stores/AuthStore.swift")
        #expect(authStore.contains("private(set) var authSessionGeneration: UInt64 = 0"))
        #expect(authStore.contains("public func handleUnauthorized() async -> Bool"))
        #expect(authStore.contains("guard !deletionOwnsAccountBoundary else { return false }"))
        #expect(authStore.contains("await auth.invalidateAndWipeSessionCredentials()"))
        #expect(authStore.contains("await beginAuthenticationTransition()"))
        #expect(authStore.contains("func completeDeletedAccountBoundary()"))

        let accountBoundary = try text("HealthLog/Stores/AuthStore+AccountBoundary.swift")
        #expect(accountBoundary.contains("final class AuthAccountBoundaryTransition"))
        #expect(accountBoundary.contains("func beginDeletedAccountTransition() async"))
        #expect(accountBoundary.contains("func beginAuthenticationTransition() async"))
        #expect(accountBoundary.contains("var deletionOwnsAccountBoundary: Bool"))

        let logoutBridge = try text("HealthLog/Stores/AppContainer+LogoutHooks.swift")
        #expect(logoutBridge.contains("let shouldRunGenericCleanup"))
        #expect(logoutBridge.contains("await storeForBridge?.handleUnauthorized() ?? true"))
        #expect(logoutBridge.contains("guard shouldRunGenericCleanup else { return }"))
        #expect(logoutBridge.contains("performFullLocalLogout(reason: .tokenExpired)"))

        let apiClient = try text("HealthLog/Services/APIClient.swift")
        let recoveryStart = try #require(apiClient.range(of: "private func handleUnauthorizedAndShouldRetry"))
        let recoveryEnd = try #require(apiClient.range(
            of: "private func rateLimitOrBackoffDelay",
            range: recoveryStart.upperBound ..< apiClient.endIndex
        ))
        let recovery = String(apiClient[recoveryStart.lowerBound ..< recoveryEnd.lowerBound])
        let refreshAttempt = try #require(recovery.range(of: "switch await refreshHandler()"))
        let terminalUnauthorized = try #require(recovery.range(of: "await onUnauthorized()"))
        #expect(refreshAttempt.lowerBound < terminalUnauthorized.lowerBound)
    }

    // swiftlint:enable function_body_length
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
            "HealthLog/Standalone/LocalStore.swift",
            "HealthLog/Screens/Insights/DailyBriefingHero+OnDevice.swift",
            "HealthLog/Screens/Insights/TrendObservationCard+OnDevice.swift"
        ]
        for path in directoryStores {
            #expect(
                try text(path).contains("SensitiveDataBackupExclusion.prepareDirectory"),
                "health-bearing directory store lost backup exclusion: \(path)"
            )
        }
        let speziScheduler = try text("HealthLog/Services/HealthKit/HealthLogSpeziDelegate.swift")
        #expect(speziScheduler.contains("static let directoryName = \"SpeziScheduler\""))
        #expect(speziScheduler.contains("documentsDirectory.appendingPathComponent(directoryName"))
        #expect(speziScheduler.contains("SensitiveDataBackupExclusion.prepareDirectory"))
        #expect(speziScheduler.contains("Scheduler(persistence: .onDisk(directory: directory))"))
        #expect(speziScheduler.contains("SpeziSchedulerStorage.makeDefaultSchedulerOrFailClosed()"))
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
    @Test("external AI remains default-off and consent-gated")
    func externalAIRequiresConsent() throws {
        let consentStore = try text("HealthLog/Services/AIConsentStore.swift")
        #expect(consentStore.contains("keychain.getString(forKey: Self.serverManagedScope) == \"granted\""))
        #expect(consentStore.contains("func revoke"))
        let consentSheet = try text("HealthLog/Screens/Settings/AIConsentSheet.swift")
        #expect(consentSheet.localizedCaseInsensitiveContains("document"))
        let documents = try text("HealthLog/Repositories/DocumentsRepository.swift")
        #expect(documents.contains("static let denied = DocumentAIConsentLeaseProvider { nil }"))
        #expect(documents.contains("sendWithExternalAIConsent"))
        #expect(documents.contains("guard await externalAIConsent.currentLease() == capturedLease"))
        #expect(documents.contains("maxRetries: 0"))
        let assist = try text("HealthLog/Repositories/DocumentsRepository+Assist.swift")
        #expect(assist.contains("sendWithExternalAIConsent"))
        let chat = try text("HealthLog/Repositories/DocumentsRepository+Chat.swift")
        #expect(chat.contains("requestWithExternalAIConsent(request)"))
        #expect(chat.contains("api.streamLines(leased.request)"))
        #expect(chat.contains("private func validateChatLeaseAfterAwait"))
        #expect(chat.components(separatedBy: "validateChatLeaseAfterAwait(leased.lease)").count - 1 == 3)
        #expect(chat.contains("withUnsafeCurrentTask { $0?.cancel() }"))
        #expect(chat.contains("allowsAuthenticationRecovery: false"))
    }

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
