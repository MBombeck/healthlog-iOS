import Foundation
@testable import HealthLog
import Testing

/// **1.5 L10N-CORE — what every route sends as its language (R2 3.2).**
///
/// Each case runs the app's own code under a pinned interface language and
/// reads the value off the wire object the route actually sends: the query of
/// the narrative GET, the encoded body of the Coach and document chat POSTs,
/// the screener body. The French device is the case the old code got wrong:
/// iOS shows it the English interface, and it used to receive German prose.
@Suite("AppLanguage request locale capture")
struct AppLanguageRequestLocaleTests {
    /// The four interfaces of the acceptance check. The French device is
    /// resolved by the same algorithm iOS runs on launch.
    enum Interface: String, CaseIterable, CustomTestStringConvertible {
        case german
        case english
        case dutch
        case frenchDevice

        var language: AppLanguage {
            switch self {
            case .german: .de
            case .english: .en
            case .dutch: .nl
            case .frenchDevice:
                AppLanguage.resolve(
                    Bundle.preferredLocalizations(
                        from: AppLanguage.allCases.map(\.rawValue),
                        forPreferences: ["fr-FR"]
                    ).first
                )
            }
        }

        var testDescription: String {
            rawValue
        }
    }

    // MARK: - Open routes: narrative, status, prefetch, chart detail, export

    @Test("Narrative GET carries the interface language", arguments: Interface.allCases)
    func narrativeQuery(interface: Interface) async throws {
        let api = ScriptedDocumentsAPI()
        let seen = QueryBox()
        api.route = { _, path, query in
            await seen.record(path: path, query: query)
            throw HLError.server(status: 404, code: nil, message: "")
        }
        let repository = NarrativeRepository(api: api)
        let sent = try await AppLanguage.$pinned.withValue(interface.language) {
            // The exact expression `InsightsScreen` hands the store.
            let locale = AppLanguage.current.serverCode
            _ = try await repository.fetch(period: .week, locale: locale, bypassCache: true)
            return await seen.value(for: "locale")
        }
        #expect(await seen.path == "/api/insights/narrative")
        #expect(sent == Self.expectedOpenRoute[interface])
    }

    /// The French device sends `en` everywhere; nothing sends `de` for it.
    static let expectedOpenRoute: [Interface: String] = [
        .german: "de", .english: "en", .dutch: "nl", .frenchDevice: "en"
    ]

    @Test("Every open route reads AppLanguage.current.serverCode at its call site")
    func openRouteCallSites() throws {
        let sites: [(file: String, expression: String)] = [
            ("HealthLog/Screens/Insights/InsightsScreen.swift", "let narrativeLocale = AppLanguage.current.serverCode"),
            ("HealthLog/Screens/Insights/InsightsScreen.swift", "let locale = AppLanguage.current.serverCode"),
            ("HealthLog/Screens/Insights/InsightsMetricScreen+Assessment.swift", "let locale = AppLanguage.current.serverCode"),
            ("HealthLog/Services/InsightsPrefetchService.swift", "AppLanguage.current.serverCode"),
            ("HealthLog/Stores/ChartDetailStore.swift", "AppLanguage.current.serverCode"),
            // L10N-REPORT: the PDF goes out in the chosen report language,
            // which starts as the interface language.
            ("HealthLog/Screens/Sharing/UnifiedSharingScreen.swift", "locale: store.reportLanguage.rawValue,"),
            ("HealthLog/Stores/UnifiedSharingStore.swift", "reportLanguage: ReportLocale = .init(AppLanguage.current)"),
            ("HealthLog/Services/AI/CoachConversationStore+Helpers.swift", "AppLanguage.current.chatServerCode()"),
            ("HealthLog/Stores/DocumentChatStore.swift", "AppLanguage.current.chatServerCode()"),
            ("HealthLog/Stores/MentalHealthStore.swift", "AppLanguage.current.regionTag")
        ]
        for site in sites {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(site.file), encoding: .utf8)
            #expect(text.contains(site.expression), "\(site.file) no longer reads `\(site.expression)`")
            #expect(!text.contains("languageCode"), "\(site.file) decides a language on its own again")
        }
    }

    // MARK: - Chat bodies

    /// R2 3.2: German and English always; Dutch only to a server known to be
    /// 1.46.2 or newer, otherwise no field. Unknown version counts as too old.
    @Test(
        "Coach and document chat bodies follow the server version",
        arguments: Interface.allCases,
        [nil as String?, "1.46.1", "1.46.2"]
    )
    func chatBodies(interface: Interface, serverVersion: String?) throws {
        let suite = "AppLanguageRequestLocaleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let serverVersion {
            KnownServerVersion.record(ServerVersionInfo(version: serverVersion), defaults: defaults)
        }
        let locale = AppLanguage.$pinned.withValue(interface.language) {
            AppLanguage.current.chatServerCode(defaults: defaults)
        }

        let coach = try APIRequest<Data>.coachChat(
            body: ChatRequestBody(conversationId: nil, message: "Hallo", locale: locale),
            encoder: .hlDefault
        )
        let document = try APIRequest<Data>.documentChat(
            id: "doc-1",
            body: DocumentChatRequest(message: "Hallo", locale: locale)
        )
        let expected: String? = switch interface {
        case .german: "de"
        case .english, .frenchDevice: "en"
        case .dutch: serverVersion == "1.46.2" ? "nl" : nil
        }
        for request in [coach, document] {
            let body = try #require(request.body)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["locale"] as? String == expected, "\(request.path) \(serverVersion ?? "unknown")")
            if expected == nil {
                #expect(json.keys.contains("locale") == false, "no locale field for an older server")
            }
        }
    }

    // MARK: - Screener

    /// L10N-MH: the screener sends the interface language with the device
    /// region (``AppLanguage/regionTag``), so the server picks the country's
    /// crisis set. The language part is the interface language, never `de`
    /// for a French device.
    @Test("The screener body carries the interface language with the device region", arguments: Interface.allCases)
    @MainActor
    func screenerBody(interface: Interface) throws {
        let locale = AppLanguage.$pinned.withValue(interface.language) {
            MentalHealthStore.deviceDisplayLocale()
        }
        let body = CreateAssessmentRequest(instrument: .phq9, items: Array(repeating: 0, count: 9), locale: locale)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        let sent = try #require(json["locale"] as? String)
        let expectedLanguage = try #require(Self.expectedOpenRoute[interface])
        #expect(sent == interface.language.regionTag)
        #expect(sent == expectedLanguage || sent.hasPrefix("\(expectedLanguage)-"), "\(sent)")
    }

    // MARK: - Helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Util
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
    }
}

private actor QueryBox {
    private(set) var path: String?
    private var query: [(String, String)] = []

    func record(path: String, query: [(String, String)]) {
        self.path = path
        self.query = query
    }

    func value(for name: String) -> String? {
        query.first { $0.0 == name }?.1
    }
}
