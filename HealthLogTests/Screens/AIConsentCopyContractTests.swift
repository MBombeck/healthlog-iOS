import Foundation
import Testing

/// W-B184 COACH-9/10 (RCA-ai-consent-flow Bug 5 + Bug 4) — source-level contract
/// tests for the AI-consent copy + the loading-vs-unconfigured distinction.
///
/// The consent copy is composed inside SwiftUI view bodies with no testable hook
/// for the resolved string, so — like `ConsentSheetButtonTests` — these are
/// source-level contracts on the two screens. They guard the two trust-critical
/// invariants the audit flagged from regressing:
///   - COACH-9: the *server-mediated* consent path must NOT assert a concrete
///     third-party provider name (the client can't know which provider the
///     server forwards to). The provider name is only named on the user-chosen
///     (BYO/local) path.
///   - COACH-10: the "not configured" surfaces must gate on `config != nil` so
///     a still-loading config never renders a scary "not configured".
@Suite("AI consent copy contracts (COACH-9/10)")
struct AIConsentCopyContractTests {
    private static func source(_ relativePath: String) -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
        let file = root.appendingPathComponent(relativePath)
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private static let consentSheetPath = "HealthLog/Screens/Settings/AIConsentSheet.swift"
    private static let providerScreenPath = "HealthLog/Screens/Settings/AIProviderScreen.swift"
    private static let settingsAIPath = "HealthLog/Screens/Settings/Sub/SettingsAIScreen.swift"

    // MARK: - COACH-9 — provider-agnostic server-mediated consent copy

    @Test("COACH-9: AIConsentSheet branches copy on a server-mediated vs user-chosen context")
    func consentSheetHasContextBranch() {
        let src = Self.source(Self.consentSheetPath)
        #expect(!src.isEmpty)
        // The context enum that selects provider-agnostic vs named copy.
        #expect(src.contains("enum Context"))
        #expect(src.contains("case serverMediated"))
        #expect(src.contains("case userChosen"))
        // The copy switches on that context, not on the decoded provider name.
        #expect(src.contains("switch context"))
    }

    @Test("COACH-9: the server-mediated copy names 'your server', never a third-party provider")
    func serverMediatedCopyIsProviderAgnostic() {
        let src = Self.source(Self.consentSheetPath)
        #expect(!src.isEmpty)
        // Isolate the dedicated server-mediated copy builder and prove it points
        // at the user's own server rather than a named third party.
        guard let range = src.range(of: "private var serverConsentCopy: String {"),
              let end = src.range(of: "\n    }", range: range.lowerBound ..< src.endIndex) else
        {
            Issue.record("serverConsentCopy builder not found")
            return
        }
        let body = String(src[range.lowerBound ..< end.upperBound])
        #expect(body.contains("to your server"))
        // No concrete third-party assertion in the server path.
        #expect(!body.contains("OpenAI"))
        #expect(!body.contains("Anthropic"))
    }

    @Test("Phase 03-01: consent explicitly names stored documents, scans, and OCR text")
    func consentDisclosesDocumentProcessing() {
        let sheet = Self.source(Self.consentSheetPath)
        let catalog = Self.source("HealthLog/Resources/Localizable.xcstrings")
        #expect(sheet.contains("consent.documentProcessing"))
        #expect(catalog.contains("stored documents"))
        #expect(catalog.contains("scanned pages"))
        #expect(catalog.contains("OCR text"))
        #expect(catalog.contains("gespeicherte Dokumente"))
        #expect(catalog.contains("gescannte Seiten"))
        #expect(catalog.contains("OCR-Text"))
        #expect(sheet.contains("private var showsExternalProcessingDisclosure"))
        #expect(sheet.contains("case .serverMediated:\n            true"))
        #expect(sheet.contains("case .userChosen:\n            provider != .local"))
    }

    @Test("COACH-9: provider names appear ONLY under the userChosen (BYO/local) branch")
    func providerNamesAreUserChosenOnly() {
        let src = Self.source(Self.consentSheetPath)
        #expect(!src.isEmpty)
        // Scope the analysis to the `consentCopy` builder body only, so doc
        // comments elsewhere in the file (which mention "OpenAI GPT" while
        // explaining WHY it was removed from the server path) don't pollute the
        // string search. The body runs from its `switch context {` to the
        // matching close.
        guard let switchStart = src.range(of: "switch context {"),
              let bodyEnd = src.range(of: "\n        }", range: switchStart.upperBound ..< src.endIndex) else
        {
            Issue.record("consentCopy switch body not found")
            return
        }
        let body = String(src[switchStart.upperBound ..< bodyEnd.lowerBound])

        // Within that body: serverMediated is handled first and must NOT name a
        // provider; the named-provider literal lives under userChosen.
        guard let serverMediated = body.range(of: "case .serverMediated:"),
              let userChosen = body.range(of: "case .userChosen:") else
        {
            Issue.record("expected both branches inside consentCopy")
            return
        }
        #expect(serverMediated.lowerBound < userChosen.lowerBound)

        // The serverMediated branch (between its marker and userChosen) names no
        // concrete third party.
        let serverBranch = String(body[serverMediated.upperBound ..< userChosen.lowerBound])
        #expect(!serverBranch.contains("OpenAI"))
        #expect(!serverBranch.contains("Anthropic"))

        // The named-provider switch (the "OpenAI" code literal) lives AFTER
        // the userChosen marker — i.e. only on the path the user chose.
        guard let openAILiteral = body.range(of: "\"OpenAI\"") else {
            Issue.record("named-provider literal not found in consentCopy")
            return
        }
        #expect(openAILiteral.lowerBound > userChosen.lowerBound)
    }

    // MARK: - COACH-10 — loading vs truly-unconfigured gating

    @Test("COACH-10: AIProviderScreen shows a loading affordance while config == nil")
    func providerScreenGatesLoadingBeforeUnconfigured() {
        let src = Self.source(Self.providerScreenPath)
        #expect(!src.isEmpty)
        // The status badge must special-case the not-yet-loaded state with a
        // neutral ProgressView BEFORE it can claim "Not configured".
        #expect(src.contains("store.isLoading || store.config == nil"))
        #expect(src.contains("ProgressView()"))
        // And the loading branch must precede the unconfigured branch in source.
        guard let loading = src.range(of: "store.isLoading || store.config == nil"),
              let unconfigured = src.range(of: "store.serverProvider == .unconfigured") else
        {
            Issue.record("expected both badge branches present")
            return
        }
        #expect(loading.lowerBound < unconfigured.lowerBound)
    }

    /// **UI-Standard R3 (U4)** — die zweite Fundstelle der Ansage ist gefallen.
    ///
    /// `SettingsAIScreen` trug unter dem Quellen-Picker eine nahezu wortgleiche
    /// Kopie der Status-Karten-Caption aus `AIProviderSection` — und die Sektion
    /// ist auf **derselben scrollenden Seite** eingebettet, also beide Fassungen
    /// im selben Blick. Heimat ist die Status-Karte: dort steht das
    /// Bedienelement, das den Zustand ändert.
    ///
    /// Die COACH-10-Invariante selbst ist damit nicht weggefallen, sie hat nur
    /// noch **einen** Ort. Dieser Test hält beides fest: der Hinweis ist auf dem
    /// Host verschwunden, und die Bedingung „niemals ‚nicht konfiguriert‘
    /// behaupten, solange die Konfiguration erst lädt" lebt in der Sektion —
    /// geprüft von `providerScreenGatesLoadingBeforeUnconfigured` oben.
    @Test("COACH-10 + R3: the needs-provider hint lives once, in the provider section")
    func settingsHintHasASingleHome() {
        let host = Self.source(Self.settingsAIPath)
        #expect(!host.isEmpty)
        #expect(!host.contains("SettingsAIScreen.onlineNeedsProvider.hint"))
        #expect(!host.contains("Your server provides the AI provider"))

        let section = Self.source(Self.providerScreenPath)
        #expect(section.contains("Your server doesn't have an assistant provider set up yet"))
    }
}
