import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// GH-iOS #27 — extra headers for a server behind Cloudflare Access, Pangolin
/// or a similar proxy: validation, Keychain round trip, the merge with the
/// build-time Cloudflare pair, and what survives a redirect.
@Suite("Server access headers")
struct ServerAccessHeadersTests {
    // MARK: - Validation

    @Test("Trims entries and drops rows left completely empty")
    func normalizesRows() throws {
        let result = try ServerAccessHeaders.normalized([
            ServerAccessHeader(name: "  CF-Access-Client-Id ", value: " abc.access \n"),
            ServerAccessHeader(name: "", value: " "),
            ServerAccessHeader(name: "CF-Access-Client-Secret", value: "s3cr3t")
        ])
        #expect(result == [
            ServerAccessHeader(name: "CF-Access-Client-Id", value: "abc.access"),
            ServerAccessHeader(name: "CF-Access-Client-Secret", value: "s3cr3t")
        ])
    }

    @Test("Rejects names the app owns, case-insensitively")
    func rejectsReservedNames() {
        for name in ["Authorization", "cookie", "X-Device-Id", "Idempotency-Key", "Host", "Sec-Fetch-Mode", "Proxy-Foo"] {
            #expect(throws: ServerAccessHeaders.ValidationError.reservedName(index: 0)) {
                try ServerAccessHeaders.normalized([ServerAccessHeader(name: name, value: "x")])
            }
        }
    }

    @Test("Rejects a value that would split the request")
    func rejectsHeaderInjection() {
        #expect(throws: ServerAccessHeaders.ValidationError.invalidValue(index: 0)) {
            try ServerAccessHeaders.normalized([ServerAccessHeader(name: "X-Token", value: "a\r\nX-Evil: 1")])
        }
        #expect(throws: ServerAccessHeaders.ValidationError.invalidValue(index: 0)) {
            try ServerAccessHeaders.normalized([ServerAccessHeader(name: "X-Token", value: "tö")])
        }
    }

    @Test("Rejects malformed and duplicate names, missing values and too many rows")
    func rejectsMalformedInput() {
        #expect(throws: ServerAccessHeaders.ValidationError.invalidName(index: 0)) {
            try ServerAccessHeaders.normalized([ServerAccessHeader(name: "X Token", value: "a")])
        }
        #expect(throws: ServerAccessHeaders.ValidationError.emptyName(index: 0)) {
            try ServerAccessHeaders.normalized([ServerAccessHeader(name: " ", value: "a")])
        }
        #expect(throws: ServerAccessHeaders.ValidationError.emptyValue(index: 0)) {
            try ServerAccessHeaders.normalized([ServerAccessHeader(name: "X-Token", value: "")])
        }
        #expect(throws: ServerAccessHeaders.ValidationError.duplicateName(index: 1)) {
            try ServerAccessHeaders.normalized([
                ServerAccessHeader(name: "X-Token", value: "a"),
                ServerAccessHeader(name: "x-token", value: "b")
            ])
        }
        let nine = (0 ... ServerAccessHeaders.maximumCount).map {
            ServerAccessHeader(name: "X-H\($0)", value: "v")
        }
        #expect(throws: ServerAccessHeaders.ValidationError.tooMany) {
            try ServerAccessHeaders.normalized(nine)
        }
    }

    @Test("Presets carry the names each proxy documents")
    func presetNames() {
        #expect(ServerAccessHeaders.Preset.cloudflareAccess.headerNames == ["CF-Access-Client-Id", "CF-Access-Client-Secret"])
        #expect(ServerAccessHeaders.Preset.pangolin.headerNames == ["P-Access-Token-Id", "P-Access-Token"])
    }

    // MARK: - Persistence

    @Test("Save and load round-trip through the Keychain; an empty list removes the entry")
    func keychainRoundTrip() throws {
        let keychain = InMemoryKeychain()
        let headers = [
            ServerAccessHeader(name: "P-Access-Token-Id", value: "id"),
            ServerAccessHeader(name: "P-Access-Token", value: "token")
        ]
        try ServerAccessHeaders.save(headers, keychain: keychain)
        #expect(ServerAccessHeaders.load(keychain: keychain) == headers)

        try ServerAccessHeaders.save([], keychain: keychain)
        #expect(keychain.getString(forKey: KeychainKey.serverAccessHeaders) == nil)
        #expect(ServerAccessHeaders.load(keychain: keychain).isEmpty)
    }

    @Test("A corrupt Keychain entry reads as no headers")
    func corruptEntryReadsEmpty() throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("not json", forKey: KeychainKey.serverAccessHeaders)
        #expect(ServerAccessHeaders.load(keychain: keychain).isEmpty)
    }

    @Test("resolve carries stored headers with and without a stored address")
    func resolveCarriesHeaders() throws {
        let keychain = InMemoryKeychain()
        let headers = [ServerAccessHeader(name: "X-Gate", value: "open")]
        try ServerAccessHeaders.save(headers, keychain: keychain)
        #expect(AppEnvironment.resolve(keychain: keychain).accessHeaders.contains(headers[0]))

        let server: URL = try #require(URL(string: "https://health.example.org"))
        try AppEnvironment.setCustomBaseURL(server, keychain: keychain)
        let env = AppEnvironment.resolve(keychain: keychain)
        #expect(env.baseURL?.host == "health.example.org")
        #expect(env.accessHeaders.contains(headers[0]))
    }

    // MARK: - Merge with Info.plist

    @Test("The build-time Cloudflare pair is sent under Cloudflare's names; a stored header of the same name wins")
    func mergeWithBundlePair() throws {
        let env = AppEnvironment(
            baseURL: URL(string: "https://health.example.org"),
            cfAccessClientID: "bundle-id",
            cfAccessClientToken: "bundle-secret",
            accessHeaders: [ServerAccessHeader(name: "cf-access-client-secret", value: "stored-secret")],
            bundleID: "dev.healthlog.app",
            appVersion: "1.4.1",
            buildNumber: "1"
        )
        #expect(env.accessHeaders == [
            ServerAccessHeader(name: "CF-Access-Client-Id", value: "bundle-id"),
            ServerAccessHeader(name: "cf-access-client-secret", value: "stored-secret")
        ])
        var request = try URLRequest(url: #require(URL(string: "https://health.example.org/api/x")))
        env.applyAccessHeaders(to: &request)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "bundle-id")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "stored-secret")
    }

    // MARK: - Redirects

    @Test("A redirect to another host keeps only harmless fields")
    func crossHostRedirectStripsCredentials() throws {
        let original = try URLRequest(url: #require(URL(string: "https://health.example.org/api/x")))
        var proposed = try URLRequest(url: #require(URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login")))
        proposed.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        proposed.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        proposed.setValue("device", forHTTPHeaderField: "X-Device-Id")
        proposed.setValue("application/json", forHTTPHeaderField: "Accept")
        proposed.setValue("native", forHTTPHeaderField: "X-Client-Type")

        let followed = ServerAccessHeaders.redirectRequest(original: original, proposed: proposed)
        #expect(followed.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(followed.value(forHTTPHeaderField: "X-Device-Id") == nil)
        #expect(followed.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(followed.value(forHTTPHeaderField: "X-Client-Type") == "native")
    }

    @Test("A redirect on the same host, including http to https, passes unchanged")
    func sameHostRedirectKeepsHeaders() throws {
        let original = try URLRequest(url: #require(URL(string: "http://Health.example.org/api/x")))
        var proposed = try URLRequest(url: #require(URL(string: "https://health.example.org/api/x/")))
        proposed.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        let followed = ServerAccessHeaders.redirectRequest(original: original, proposed: proposed)
        #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
    }

    @Test("A different port counts as a different host")
    func portChangeStrips() throws {
        let original = try URLRequest(url: #require(URL(string: "https://health.example.org/api/x")))
        var proposed = try URLRequest(url: #require(URL(string: "https://health.example.org:8443/api/x")))
        proposed.setValue("secret", forHTTPHeaderField: "P-Access-Token")
        let followed = ServerAccessHeaders.redirectRequest(original: original, proposed: proposed)
        #expect(followed.value(forHTTPHeaderField: "P-Access-Token") == nil)
    }

    // MARK: - Reachability probe

    @Test("A probe answered by another host reports the redirect instead of reachable")
    func probeClassifiesProxyRedirect() throws {
        let asked = try #require(URL(string: "https://health.example.org/api/auth/registration-status"))
        #expect(ServerReachabilityProbe.classify(
            statusCode: 200,
            requestedURL: asked,
            answeredURL: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login")
        ) == .redirectedToOtherHost("team.cloudflareaccess.com"))
        #expect(ServerReachabilityProbe.classify(statusCode: 200, requestedURL: asked, answeredURL: asked) == .reachable)
        #expect(ServerReachabilityProbe.classify(statusCode: 404, requestedURL: asked, answeredURL: asked) == .notHealthLogServer)
        #expect(ServerReachabilityProbe.classify(statusCode: 403, requestedURL: asked, answeredURL: asked) == .unexpectedStatus(403))
    }
}
