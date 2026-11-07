// swiftlint:disable force_unwrapping

// App-target symbols (`ServerURLStep`, `OnboardingDraftStore`); the SPM test
// build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// #151 — the server's cross-site write guard reads `Origin` (and the
    /// browser pair around it), so a user-defined header of that name could trip
    /// it. Both names are the app's, like `Authorization`.
    @Suite("Access headers: Origin and Referer are reserved (#151)")
    struct AccessHeadersOriginRefererTests {
        @Test("A stored list with a newly reserved name keeps its other entries")
        func loadSkipsNewlyReservedEntries() throws {
            let keychain = InMemoryKeychain()
            try keychain.setString(
                #"[{"name":"Referer","value":"x"},{"name":"P-Access-Token-Id","value":"pid"}]"#,
                forKey: KeychainKey.serverAccessHeaders
            )
            #expect(ServerAccessHeaders.load(keychain: keychain) == [ServerAccessHeader(name: "P-Access-Token-Id", value: "pid")])
        }

        @Test("Origin and Referer are rejected, in any case")
        func rejectsOriginAndReferer() {
            for name in ["Origin", "origin", "ORIGIN", "Referer", "referer"] {
                #expect(throws: ServerAccessHeaders.ValidationError.reservedName(index: 0)) {
                    try ServerAccessHeaders.normalized([ServerAccessHeader(name: name, value: "https://example.com")])
                }
            }
        }
    }

    /// #149 — a server that is still starting answers the address check with
    /// 503 (`reason: starting` on newer servers, a bare 503 on older ones). That
    /// is not "wrong address", it is "try again in a moment".
    @Suite("Address check: 503 means the server is starting (#149)")
    struct ServerStartingProbeTests {
        private static let asked = URL(string: "https://health.example.com/api/auth/registration-status")!

        @Test("503 is classified apart from other statuses")
        func classifies503() {
            let outcome = ServerReachabilityProbe.classify(statusCode: 503, requestedURL: Self.asked, answeredURL: Self.asked)
            #expect(outcome == .serverStarting)
            #expect(
                ServerReachabilityProbe.classify(statusCode: 502, requestedURL: Self.asked, answeredURL: Self.asked)
                    == .unexpectedStatus(502)
            )
        }

        @Test("A 503 from another host is still the proxy's redirect, not a starting server")
        func redirectWins() throws {
            let other = try #require(URL(string: "https://login.example.net/"))
            #expect(
                ServerReachabilityProbe.classify(statusCode: 503, requestedURL: Self.asked, answeredURL: other)
                    == .redirectedToOtherHost("login.example.net")
            )
        }

        @MainActor
        @Test("The server step turns it into the starting state with its retry")
        func serverStepState() {
            #expect(ServerURLStep.probeState(for: .serverStarting) == .starting)
        }

        @Test("The sentence exists in German and English")
        func sentence() throws {
            let key = "Your server is starting up. Try again in a moment."
            let bundle = Bundle.main // the test host is the app
            for (language, expected) in [
                ("de", "Dein Server startet gerade. Versuch es gleich noch einmal."),
                ("en", key)
            ] {
                let path = try #require(bundle.path(forResource: language, ofType: "lproj"))
                let localized = try #require(Bundle(path: path)).localizedString(forKey: key, value: "MISSING", table: nil)
                #expect(localized == expected)
            }
        }
    }

    /// #153 — the setup draft stays in memory until the user confirms.
    @MainActor
    @Suite("Setup draft stays in memory (#153)", .serialized)
    struct OnboardingDraftMemoryOnlyTests {
        private static let secret = "draft-secret-153-\(UUID().uuidString)"

        @Test("Typing into the draft writes nothing to UserDefaults, the Keychain or files")
        func draftIsNotPersisted() {
            let keychain = InMemoryKeychain()
            let started = Date()
            let defaultsBefore = UserDefaults.standard.dictionaryRepresentation().count
            let draft = OnboardingDraftStore()

            draft.step = .serverURL
            draft.chosenMode = .server
            draft.server.address = "health-\(Self.secret).example.com"
            draft.server.showsAdvanced = true
            draft.server.headerRows = [ServerAccessHeadersEditor.Row(name: "CF-Access-Client-Secret", value: Self.secret)]
            draft.inviteToken = Self.secret
            draft.settingsAccessHeaderRows = [ServerAccessHeadersEditor.Row(name: "X-Key", value: Self.secret)]
            draft.changeServerAddress = Self.secret
            UserDefaults.standard.synchronize()

            let defaults = UserDefaults.standard.dictionaryRepresentation()
            #expect(defaults.count == defaultsBefore)
            #expect(!defaults.values.contains { "\($0)".contains(Self.secret) })
            #expect(keychain.getString(forKey: KeychainKey.serverAccessHeaders) == nil)
            #expect(keychain.getString(forKey: KeychainKey.serverURL) == nil)
            #expect(Self.filesWritten(since: started, containing: Self.secret).isEmpty)
        }

        @Test("A new run after the hand-over, or after the session went away, starts clean")
        func startsOverWhenTheRunIsOver() {
            let draft = OnboardingDraftStore()
            draft.server.address = "health.example.com"
            draft.step = .done
            draft.prepareForAppearance(phase: .unauthenticated)
            #expect(draft.step == OnboardingFlow.initialStep)
            #expect(draft.server == ServerAddressDraft())

            draft.step = .anamnesis
            draft.chosenMode = .server
            draft.prepareForAppearance(phase: .unauthenticated)
            #expect(draft.step == OnboardingFlow.initialStep, "past the sign-in without a session is an orphan")
        }

        @Test("A rebuilt flow mid-setup keeps step and form; Settings drafts go")
        func keepsAnInterruptedRun() {
            let draft = OnboardingDraftStore()
            draft.step = .serverURL
            draft.server.address = "health.example.com"
            draft.settingsAccessHeaderRows = []
            draft.changeServerAddress = "x"
            draft.prepareForAppearance(phase: .unauthenticated)
            #expect(draft.step == .serverURL)
            #expect(draft.server.address == "health.example.com")
            #expect(draft.settingsAccessHeaderRows == nil)
            #expect(draft.changeServerAddress == nil)

            draft.step = .anamnesis
            draft.prepareForAppearance(phase: .authenticating(User(id: "u", email: nil, username: nil, displayName: nil, createdAt: .now)))
            #expect(draft.step == .anamnesis, "a sign-in in progress keeps the post-login tail")
        }

        /// Files in the app's own container written during the test whose bytes
        /// contain `needle`.
        private static func filesWritten(since start: Date, containing needle: String) -> [String] {
            let roots = [NSHomeDirectory() + "/Library", NSHomeDirectory() + "/Documents", NSTemporaryDirectory()]
            var hits: [String] = []
            let needleData = Data(needle.utf8)
            for root in roots {
                guard let walker = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
                ) else { continue }
                for case let url as URL in walker {
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          values.isRegularFile == true,
                          let modified = values.contentModificationDate, modified >= start,
                          let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                          data.range(of: needleData) != nil else { continue }
                    hits.append(url.path)
                }
            }
            return hits
        }
    }

#endif
