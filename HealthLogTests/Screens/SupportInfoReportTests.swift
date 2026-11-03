// App-target symbols (`SupportInfoReport`) are not in the SPM library; the
// SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **#134 (server v1.43) — "Support-Info kopieren".**
    ///
    /// The text is what a person pastes into a support request, so the test
    /// that matters most is what it leaves out. The fixture's failures went
    /// through the real recorder with a body that names an e-mail, a user name,
    /// a reading and the server host, and a server version answer whose build
    /// field carries an address; none of it may reach the text.
    @Suite("#134: Support info text")
    struct SupportInfoReportTests {
        private static let now = Date(timeIntervalSince1970: 1_792_141_923) // 2026-10-16T09:12:03Z
        private static let requestID = "3f9a2c1b-7d4e-4f10-9a2b-c3d4e5f60718"

        private static func input(
            server: ServerVersionInfo? = ServerVersionInfo(version: "1.43.0", buildSha: "d06ce36"),
            lastKnown: String? = "1.42.4",
            failures: [RecentFailure] = []
        ) -> SupportInfoReport.Input {
            SupportInfoReport.Input(
                generatedAt: now,
                build: AppBuildMetadata(marketingVersion: "1.3.0", build: "300"),
                osVersion: "26.5.0",
                deviceClass: "iPhone",
                appLanguage: "de",
                server: server,
                lastKnownServerVersion: lastKnown,
                failures: failures
            )
        }

        @Test("the whole text, line by line")
        func fullText() {
            let failure = RecentFailure(
                at: Self.now, method: "GET", route: "/api/medications/:id", status: 500,
                errorCode: "internal_error", requestId: Self.requestID, kind: .status
            )
            let text = SupportInfoReport(Self.input(failures: [failure])).text
            #expect(text == [
                "HealthLog support info",
                "generated: 2026-10-16T09:12:03Z",
                "app: 1.3.0 (300)",
                "os: iOS 26.5.0",
                "device: iPhone",
                "language: de",
                "server version: 1.43.0 (build d06ce36)",
                // A4 (#134) — the account and Apple Health lines, here as
                // they read before anything was loaded (`A4DiagnosticsSupportInfoTests`
                // pins them loaded).
                "time zone: unknown",
                "modules: not loaded",
                "ai: not reported",
                "[server] GET /api/integrations/healthkit",
                "not loaded",
                "recent errors:",
                "  2026-10-16T09:12:03Z GET /api/medications/:id 500 internal_error id 3f9a2c1b-7d4e-4f10-9a2b-c3d4e5f60718"
            ].joined(separator: "\n") + "\n")
        }

        @Test("server not reachable: the last known version, or say so")
        func serverFallbacks() {
            let lastKnown = SupportInfoReport(Self.input(server: nil)).text
            #expect(lastKnown.contains("server version: 1.42.4 (last known, not reachable now)\n"))
            let none = SupportInfoReport(Self.input(server: nil, lastKnown: nil)).text
            #expect(none.contains("server version: not reachable\n"))
            let noSha = SupportInfoReport(Self.input(server: ServerVersionInfo(version: "1.43.0"))).text
            #expect(noSha.contains("server version: 1.43.0\n"))
            #expect(SupportInfoReport(Self.input()).text.contains("recent errors: none\n"))
        }

        @Test("no e-mail, user name, server host, value or record id")
        func redaction() throws {
            let log = RecentFailureLog()
            let body = Data(
                """
                {"data":null,"error":"Zara Quillfeather <zara.quillfeather@example.org> 142/91 mmHg on test.healthlog.local",\
                "meta":{"requestId":"\(Self.requestID)","errorCode":"internal_error","email":"zara.quillfeather@example.org"}}
                """.utf8
            )
            let url = try #require(URL(string: "https://test.healthlog.local/api/measurements/meas_az09kqmzp1x7?user=zara"))
            let response = try #require(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
            log.record(
                HLError.server(status: 500, code: "internal_error", message: "Zara Quillfeather 142/91 mmHg"),
                method: .patch,
                path: "/api/measurements/meas_az09kqmzp1x7?user=zara",
                response: response,
                body: body
            )
            let text = SupportInfoReport(Self.input(
                server: ServerVersionInfo(version: "1.43.0", buildSha: "zara.quillfeather@example.org"),
                failures: log.snapshot()
            )).text
            for leak in [
                "zara",
                "Zara",
                "Quillfeather",
                "@",
                "example.org",
                "142",
                "mmHg",
                "test.healthlog.local",
                "https",
                "meas_az09kqmzp1x7",
                "user="
            ] {
                #expect(!text.contains(leak), "leaked \(leak)")
            }
            #expect(text.contains("PATCH /api/measurements/:id 500 internal_error id \(Self.requestID)"))
            #expect(text.contains("server version: 1.43.0\n"))
        }

        @Test("plain ASCII, none of the forbidden punctuation")
        func plainCharacters() {
            let failures = [
                RecentFailure(
                    at: Self.now,
                    method: "GET",
                    route: "/api/labs/overview",
                    status: 200,
                    errorCode: nil,
                    requestId: nil,
                    kind: .decoding
                ),
                RecentFailure(
                    at: Self.now,
                    method: "POST",
                    route: "/api/measurements/batch",
                    status: 503,
                    errorCode: "x",
                    requestId: Self.requestID,
                    kind: .status
                )
            ]
            for text in [SupportInfoReport(Self.input(failures: failures)).text, SupportInfoReport(Self.input(server: nil)).text] {
                let isASCII = text.unicodeScalars.allSatisfy(\.isASCII)
                #expect(isASCII)
                for glyph in ["\u{00B7}", "\u{2014}", "\u{2013}", "\u{2192}"] {
                    #expect(!text.contains(glyph))
                }
            }
        }

        @Test("tokens outside the narrow shape are left out")
        func tokens() {
            #expect(SupportInfoReport.token("1.43.0-rc.1") == "1.43.0-rc.1")
            #expect(SupportInfoReport.token("de") == "de")
            #expect(SupportInfoReport.token("1.43 beta") == nil)
            #expect(SupportInfoReport.token("") == nil)
            #expect(SupportInfoReport.token(String(repeating: "a", count: 41)) == nil)
            #expect(SupportInfoReport.token("Zaras iPhone") == nil)
        }
    }
#endif
