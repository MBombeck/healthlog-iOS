// `PrivacyInfo.xcprivacy` ist build-relevant: ein fehlender oder
// kaputter Eintrag lässt App Store Connect den Upload zurückweisen
// (Enforcement seit Mai 2024). Wir lesen die Datei aus dem App-Bundle,
// validieren sie als Plist und checken die für Apple-Compliance
// kritischen Einträge ab.
//
// Diese Suite deckt nur den App-Target ab (kein SPM-Build) — das
// `.xcprivacy`-File ist eine Resource des HealthLog-Targets.
//
// Refs: A7-apple-compliance-research.md BLOCKER 5 / §6 Privacy Manifest

#if !SWIFT_PACKAGE

    import Foundation
    import Testing

    @Suite("PrivacyInfo.xcprivacy")
    struct PrivacyManifestTests {
        private func loadManifest() throws -> [String: Any] {
            // App-Bundle des HealthLog-Targets — bei Test-Hosting via TEST_HOST
            // ist `Bundle.main` die App.
            guard let url = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") else {
                throw ManifestError.notFound
            }
            let data = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization
                .propertyList(from: data, options: [], format: nil) as? [String: Any] else
            {
                throw ManifestError.notDictionary
            }
            return plist
        }

        private enum ManifestError: Error { case notFound, notDictionary }

        @Test("Tracking is disabled and tracking-domains list is empty")
        func trackingDisabled() throws {
            let plist = try loadManifest()
            #expect((plist["NSPrivacyTracking"] as? Bool) == false)
            let domains = plist["NSPrivacyTrackingDomains"] as? [String] ?? []
            #expect(domains.isEmpty)
        }

        @Test("Collected data types include all categories required by A7 §6")
        func collectedDataTypesPresent() throws {
            let plist = try loadManifest()
            let types = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
            let typeIDs = Set(types.compactMap { $0["NSPrivacyCollectedDataType"] as? String })

            let required: Set = [
                "NSPrivacyCollectedDataTypeHealth",
                "NSPrivacyCollectedDataTypeFitness",
                "NSPrivacyCollectedDataTypeUserID",
                "NSPrivacyCollectedDataTypeEmailAddress",
                "NSPrivacyCollectedDataTypeOtherUserContent",
                "NSPrivacyCollectedDataTypeSensitiveInfo",
                "NSPrivacyCollectedDataTypeDeviceID"
            ]
            let missing = required.subtracting(typeIDs)
            #expect(missing.isEmpty, "Missing data types in PrivacyInfo: \(missing)")

            // CrashData darf NICHT deklariert sein, solange wir kein MetricKit
            // einsetzen — Over-Declaration kann eigene Reviewer-Frueh-Trigger
            // auslösen ("Was gibst du genau weiter?").
            #expect(!typeIDs.contains("NSPrivacyCollectedDataTypeCrashData"))
        }

        @Test("Every collected data type is Linked + non-Tracking")
        func everyTypeLinkedNonTracking() throws {
            let plist = try loadManifest()
            let types = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
            for entry in types {
                let id = entry["NSPrivacyCollectedDataType"] as? String ?? "<unknown>"
                #expect((entry["NSPrivacyCollectedDataTypeLinked"] as? Bool) == true, "\(id): not Linked")
                #expect((entry["NSPrivacyCollectedDataTypeTracking"] as? Bool) == false, "\(id): Tracking enabled")
                let purposes = entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
                #expect(!purposes.isEmpty, "\(id): no purposes declared")
            }
        }

        /// Build 273 — every purpose must be one Apple's manifest vocabulary
        /// defines. `PurposeAccountManagement` is an App Store Connect label
        /// answer, not a manifest purpose; a manifest carrying it declares no
        /// valid purpose for that type. The credentialed types use
        /// `AppFunctionality` here and "Account Management" on the ASC form.
        @Test("Every purpose is a valid manifest purpose; credentialed types use AppFunctionality")
        func purposesAreValidManifestVocabulary() throws {
            let plist = try loadManifest()
            let types = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
            let valid: Set = [
                "NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising",
                "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising",
                "NSPrivacyCollectedDataTypePurposeAnalytics",
                "NSPrivacyCollectedDataTypePurposeProductPersonalization",
                "NSPrivacyCollectedDataTypePurposeAppFunctionality",
                "NSPrivacyCollectedDataTypePurposeOther"
            ]
            for entry in types {
                let id = entry["NSPrivacyCollectedDataType"] as? String ?? "?"
                let purposes = Set((entry["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? [])
                #expect(purposes.subtracting(valid).isEmpty, "\(id): unknown purpose \(purposes.subtracting(valid))")
            }
            for credentialType in ["NSPrivacyCollectedDataTypeEmailAddress", "NSPrivacyCollectedDataTypeUserID"] {
                let entry = types.first { $0["NSPrivacyCollectedDataType"] as? String == credentialType }
                let purposes = (entry?["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? []
                #expect(
                    purposes.contains("NSPrivacyCollectedDataTypePurposeAppFunctionality"),
                    "\(credentialType) must carry AppFunctionality"
                )
            }
        }

        @Test("Required-reason APIs match actual code usage (UserDefaults + FileTimestamp)")
        func requiredReasonAPIs() throws {
            let plist = try loadManifest()
            let entries = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? []
            let categories = Set(entries.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })

            // UserDefaults wird tatsächlich genutzt (SettingsStore + HK-Anchors).
            #expect(categories.contains("NSPrivacyAccessedAPICategoryUserDefaults"))

            // SystemBootTime bleibt entfernt — wir nutzen kein `mach_absolute_time`.
            #expect(!categories.contains("NSPrivacyAccessedAPICategorySystemBootTime"))

            // FileTimestamp ist seit v0.6.2.3 (C617.1) deklariert: die Outbox-
            // Replay-/Diagnose-Surfaces zeigen Datei- + SwiftData-Timestamps
            // direkt an den User. v0.7.0 ergaenzt DDA9.1 fuer die zweite reale
            // Verwendung (Outbox-Inspector / Sync-Diagnostik). Apple verlangt
            // keinen exklusiven Reason pro Kategorie — beide existieren als
            // echte Code-Pfade, also fuehren wir beide.
            #expect(categories.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))

            // UserDefaults muss CA92.1 als Reason fuehren (oder einen aequivalent
            // gültigen Code) — die Liste der erlaubten Codes pflegt Apple
            // separat, hier exemplarisch der von uns verwendete.
            let userDefaultsEntry = entries
                .first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" }
            let reasons = userDefaultsEntry?["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            #expect(reasons.contains("CA92.1"))

            // FileTimestamp muss BEIDE Reasons fuehren: C617.1 (display file
            // timestamps to the user) + DDA9.1 (display SwiftData timestamps in
            // der Outbox-Diagnose). v0.7.0 W-APPSTORE.
            let fileTimestampEntry = entries
                .first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryFileTimestamp" }
            let fileReasons = Set(fileTimestampEntry?["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
            #expect(fileReasons.contains("C617.1"))
            #expect(fileReasons.contains("DDA9.1"))
        }
    }

#endif
