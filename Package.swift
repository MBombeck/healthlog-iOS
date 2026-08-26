// swift-tools-version: 6.0
//
// SPM-Manifest fuer die plattform-unabhaengigen Anteile von HealthLog
// (Models, Services-Core, Repositories, Cache, Sync, Pharmacokinetics, Util).
// Production-Build geht ueber das `xcodegen`-erzeugte `.xcodeproj`; dieser
// Manifest existiert, damit `swift build` / `swift test` die Modulgrenze
// "HealthLogCore kompiliert iOS-frei (kein UIKit/HealthKit/Spezi/FHIR)"
// als CI-Gate erzwingen koennen.
//
// Wichtig: der `HealthLogCore`-Target nutzt eine **explizite `sources:`-
// Allowlist** statt einer `exclude:`-Denylist. Grund: der gemeinsame
// `HealthLog/`-Pfad enthaelt auch app-/iOS-only Code (Screens, Stores,
// DesignSystem-Components, FHIR/ModelsR4, HealthKit-/Spezi-Services,
// FoundationModels `@Generable`, AppIntents, Vision, PDF). Eine Denylist
// liesse jeden neu hinzugefuegten app-only File still in den Core-Target
// lecken und damit die Modulreinheit unbemerkt brechen. Die Allowlist
// dokumentiert positiv, was "Core" ist, und faengt Leaks beim naechsten
// `swift build` ab.
import PackageDescription

let package = Package(
    name: "HealthLogCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HealthLogCore", targets: ["HealthLogCore"])
    ],
    targets: [
        .target(
            name: "HealthLogCore",
            path: "HealthLog",
            // `CoachInsight` nutzt `@Generable` (FoundationModels, nur
            // macOS 26 / iOS 26) — gehoert in den App-Target, nicht in Core.
            exclude: [
                "Models/CoachInsight.swift",
                // Mirror der HealthLogWidgets-Repositories-Excludes
                // (project.yml): diese Repos referenzieren app-only Model-Typen,
                // die in Screen-Dateien definiert sind (`PasskeyEntry`,
                // `WithingsStatus`) — also NICHT plattform-frei. Der `sources:`
                // globt `Repositories/`; ohne diese Excludes leaken die
                // app-only Typen in Core und `swift build` bricht (H1). Note:
                // `AuditLogRepository.swift` kompiliert plattform-frei und
                // bleibt daher in Core (bewusst nicht mit-excludiert).
                "Repositories/PasskeyRepository.swift",
                "Repositories/WithingsRepository.swift",
                // 09-15 — `HealthLog/Resources/` is the APP target's resource
                // bundle (`Assets.xcassets`, `Localizable.xcstrings`, the
                // xcodegen-generated `Info.plist`/entitlements and the
                // `de.lproj`/`en.lproj` `InfoPlist.strings` pair). None of it
                // belongs to `HealthLogCore`, which is a compile-only module
                // gate that never loads a bundle. SwiftPM scans the whole
                // target `path:` for RESOURCES independently of the `sources:`
                // allowlist, so the two `.lproj` directories made the target
                // "localized" and SwiftPM hard-errored with `manifest property
                // 'defaultLocalization' not set` — which is what took CI's
                // `swift build` step red from `a617af3f` onwards while the
                // Xcode build stayed green. Excluding the directory is the fix
                // rather than declaring `defaultLocalization:`, because the
                // core module must process NO resources at all: declaring a
                // default localization would make SwiftPM build a resource
                // bundle for a module that never reads one, and would silently
                // absorb every future app resource into the core target — the
                // exact leak the `sources:` allowlist exists to prevent.
                "Resources"
            ],
            sources: [
                // Reine Value-Types / Models (Codable, Sendable). Eine
                // Handvoll (`MetricKindDescriptor`, `PersonalRecord`,
                // `MetricSeriesProjection`) referenziert DesignSystem-Tints
                // (HLText/HLSurface/HLChartTints) — die liegen in der
                // plattform-freien `DesignSystem/Tokens.swift` (nur SwiftUI),
                // die unten explizit mit aufgenommen wird.
                "Models",
                // APIClient, Keychain, Logger, Reachability, IdempotencyKey,
                // CertificatePinner, AuthService, FeatureFlags, … — alles
                // plattform-frei. HealthKit-/Notification-/Passkey-/Spezi-
                // Services sind bewusst NICHT gelistet (iOS-only).
                "Services/AIConsentStore.swift",
                // v0.13 BYO — `AIConsentStore`/`AuthService` referenzieren
                // `BYOProviderID` (Consent-Namespace) + `BYOKeyStore.wipeAll()`
                // (Account-Delete-Pfad) + dessen Typed-Error. Alle drei sind
                // Foundation-only (KeychainStoring), gehoeren also in Core.
                // Adapter + BYOLLMService (URLSession) bleiben app-only.
                "Services/AI/BYO/BYOProviderID.swift",
                "Services/AI/BYO/BYOKeyStore.swift",
                "Services/AI/BYO/BYOLLMError.swift",
                "Services/APIClient.swift",
                // Phase 09 / plan 09-02 — APIClient's conformance to the
                // file-backed upload requirement; without it Core would
                // fall back to the protocol's throwing default.
                "Services/APIClient+FileUpload.swift",
                "Services/APIClient+HealthProbe.swift",
                "Services/APIClient+Pinning.swift",
                "Services/APIClient+ServerVersion.swift",
                // Phase 09 / plan 09-02 — `APIClientProtocol` names the
                // file-backed upload request, so Core must compile it too.
                "Services/APIFileUploadRequest.swift",
                "Services/APIRequest.swift",
                "Services/AuthService.swift",
                // 09-15 — `AuthService` names these wire DTOs in twelve of its
                // own signatures (`NativeLoginResponse`,
                // `MfaWebauthnOptionsResponse`, `PasskeyLoginOptionsResponse`,
                // `WebAuthnAssertionDTO`) and returns `OidcStatus` from
                // `oidcStatus()`. Both files are `import Foundation` only. They
                // were missing from the allowlist and NOBODY noticed, because
                // the manifest error above aborted `swift build` before a
                // single file was compiled — the module-purity gate had never
                // actually run.
                "Services/AuthService+WireDTOs.swift",
                "Services/OidcStatus.swift",
                // 09-15 — `EcgRepository` and `WorkoutsRepository` (both in the
                // wholesale-globbed `Repositories/`) build their routes from
                // `HealthIngestRoute`, which imports nothing at all.
                "Services/HealthIngestRoute.swift",
                "Services/AvatarCache.swift",
                "Services/BatchSyncThrottle.swift",
                "Services/BiometricGate.swift",
                "Services/CertificatePinner.swift",
                // W-COACH-SSE — APIClient references CoachStreamTimeoutPolicy
                // (coach SSE streaming-session timeout values); Foundation-only
                // value type, must compile into Core alongside APIClient.swift.
                "Services/CoachStreamTimeoutPolicy.swift",
                "Services/DoctorReportService.swift",
                "Services/DoctorReportTmpSweeper.swift",
                "Services/FeatureFlagsService.swift",
                "Services/IdempotencyKey.swift",
                "Services/KeychainStore.swift",
                "Services/Logger.swift",
                // Audit-M2 — non-trapping in-memory floor der SwiftData-Recovery-
                // Ladders (`OutboxQueue+WriteAhead`, `SWRCacheFactory`, beide in
                // Core). Foundation + SwiftData only, plattform-frei.
                "Services/ModelContainerRecovery.swift",
                "Services/PasskeyProtocol.swift",
                "Services/Reachability.swift",
                "Services/RefreshCoordinator.swift",
                "Services/RefreshOutcome.swift",
                "Services/ServerReachabilityProbe.swift",
                // 13-02 — `AuthService.webLoginAvailable()` stopped being a
                // version statement and now asks the login route where it
                // leads. The probe (and the shared route builder the browser
                // leg forwards to) lives here; the throwaway S256 challenge it
                // sends comes from `OidcPKCE`, a CryptoKit+Foundation value
                // type that was app-only only because nothing in Core had
                // needed it yet.
                "Services/WebLoginRouteProbe.swift",
                "Services/OidcPKCE.swift",
                "Services/StatistikModeBriefingService.swift",
                // SWR + Outbox repositories — plattform-frei.
                "Repositories",
                // SwiftData/Keychain caches — plattform-frei.
                "Cache",
                "Sync",
                "Pharmacokinetics",
                "Util",
                // Nur die Token-Dateien aus DesignSystem (reine SwiftUI-Farb-/
                // Spacing-/Motion-Tokens). Die DesignSystem-*Components*
                // (HLCard, HLButton, … = UIKit-guarded UI) bleiben App-only.
                // W-B188 splittete `Tokens.swift` in thematische Geschwister
                // (file-length). Die Core-Models (`MetricKindDescriptor`,
                // `PersonalRecord`, …) referenzieren `HLSurface`/`HLText`/
                // `HLAccent` aus diesen Splits — ohne sie bricht `swift build`
                // (H1). Mirror des Widget-Allowlists (project.yml).
                "DesignSystem/Tokens.swift",
                "DesignSystem/Tokens+Layout.swift",
                "DesignSystem/Tokens+Motion.swift",
                "DesignSystem/Tokens+Charts.swift",
                "DesignSystem/Tokens+Surfaces.swift",
                // 09-15 — `Tokens+Tint.swift` was deleted by `6eae69dc`
                // ("monochrome — remove preferredTint accent + HLTint enum")
                // and `HLAccent` now lives in `Tokens+Surfaces.swift`, already
                // listed above. The stale entry produced only
                // `warning: Invalid Source '…/Tokens+Tint.swift': File not
                // found.` — a warning `swift build` does not fail on, which is
                // why an allowlist entry pointing at nothing survived. The
                // 09-15 SPM gate fails closed on that warning from now on.
                "DesignSystem/Tokens+Shadow.swift"
            ]
        ),
        .testTarget(
            name: "HealthLogCoreTests",
            dependencies: ["HealthLogCore"],
            // SPM picks up Core/ + Mocks/ + Stores/ — same set xcodebuild compiles
            // for the iOS test target. Excludes are paths that don't apply outside Xcode.
            path: "HealthLogTests"
        )
    ]
)
