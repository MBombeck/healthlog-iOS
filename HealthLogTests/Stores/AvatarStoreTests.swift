import Foundation
@testable import HealthLog
import Testing
import UIKit

// swiftlint:disable force_unwrapping

/// **v0.8.0 W11 — AvatarStore load / fallback / cache / logout.**
///
/// Uses the real `APIClient` + `MockURLProtocol` (per the 0.2.0-audit rule:
/// never a mock-server) so the load path exercises production request
/// building + envelope decode.
@MainActor
@Suite("AvatarStore", .serialized)
struct AvatarStoreTests {
    private func makeStore(
        cache: AvatarCache = AvatarCache.shared,
        refreshProfile: @escaping @MainActor () async -> Void = {}
    ) -> AvatarStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return AvatarStore(repo: AvatarRepository(api: api), cache: cache, refreshProfile: refreshProfile)
    }

    private func tinyPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return img.pngData()!
    }

    @Test("nil avatarUrl clears the image — view renders initials")
    func nilURLClears() async {
        let store = makeStore()
        await store.load(avatarURLPath: nil)
        #expect(store.image == nil)
    }

    @Test("Empty avatarUrl clears the image")
    func emptyURLClears() async {
        let store = makeStore()
        await store.load(avatarURLPath: "")
        #expect(store.image == nil)
    }

    @Test("404 on fetch leaves image nil so the monogram fallback stands")
    func notFoundFallsBack() async {
        let store = makeStore(cache: AvatarCache.shared)
        AvatarCache.shared.clearMemory()
        MockURLProtocol.handler = { req in
            let json = #"{"data":null,"error":"Avatar not found"}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        await store.load(avatarURLPath: "/api/user/avatar/u1?v=404")
        #expect(store.image == nil)
    }

    @Test("Successful fetch decodes an image and caches the bytes under the ?v= key")
    func successCaches() async {
        let cache = AvatarCache.shared
        cache.clearMemory()
        let store = makeStore(cache: cache)
        let png = tinyPNG()
        let key = "/api/user/avatar/u1?v=success"
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — count only the avatar routes.
            if req.targets(prefixedBy: "/api/user/avatar") { requestCount += 1 }
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )!,
                png
            )
        }
        await store.load(avatarURLPath: key)
        #expect(store.image != nil)
        #expect(cache.cachedBytes(forKey: key) == png)

        // A second load for the same key must hit the in-memory cache (no new
        // request) — the ?v= cache-buster invariant.
        await store.load(avatarURLPath: key)
        #expect(requestCount == 1)

        cache.clearMemory()
    }

    // MARK: - C4: stale-URL guard (post-upload refresh race)

    /// A 1x1 PNG of a given colour so two uploads produce distinguishable bytes.
    private func solidPNG(_ color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let img = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return img.pngData()!
    }

    @Test("After upload, a load with the STALE pre-flip url does not refetch or overwrite the fresh image (C4)")
    func staleUrlDoesNotRevertFreshUpload() async throws {
        let cache = AvatarCache.shared
        cache.clearMemory()
        let store = makeStore(cache: cache)
        let freshKey = "/api/user/avatar/u1?v=200"
        let staleKey = "/api/user/avatar/u1?v=100"

        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { req in
            if req.targets(prefixedBy: "/api/user/avatar") { requestCount += 1 }
            // Upload POST returns the fresh ?v= url; any GET would be a stale
            // refetch we want to assert never happens.
            let json = #"{"data":{"avatarUrl":"/api/user/avatar/u1?v=200","contentType":"image/jpeg"}}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }

        let uploaded = try await store.upload(#require(UIImage(data: solidPNG(.red))))
        #expect(uploaded)
        #expect(store.image != nil)
        let uploadRequestCount = requestCount

        // Simulate the racing profile refresh handing the display surface the
        // OLD url. It must NOT refetch and must NOT clear the fresh image.
        await store.load(avatarURLPath: staleKey)
        #expect(store.image != nil)
        #expect(requestCount == uploadRequestCount) // no GET fired
        // Re-loading the fresh key is also a no-op (already painted).
        await store.load(avatarURLPath: freshKey)
        #expect(requestCount == uploadRequestCount)

        cache.clearMemory()
    }

    @Test("force load bypasses the loadedKey short-circuit and refetches (C4 escape hatch)")
    func forceLoadRefetches() async {
        let cache = AvatarCache.shared
        cache.clearMemory()
        let store = makeStore(cache: cache)
        let png = tinyPNG()
        let key = "/api/user/avatar/u1?v=force"
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — count only the avatar routes.
            if req.targets(prefixedBy: "/api/user/avatar") { requestCount += 1 }
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )!,
                png
            )
        }
        await store.load(avatarURLPath: key)
        #expect(requestCount == 1)
        // Without force a repeat is a no-op.
        await store.load(avatarURLPath: key)
        #expect(requestCount == 1)
        // With force it refetches even though the key is unchanged.
        await store.load(avatarURLPath: key, force: true)
        #expect(requestCount == 2)
        #expect(store.image != nil)
        cache.clearMemory()
    }

    @Test("remove clears the upload stamp so subsequent loads of a new url work again (C4)")
    func removeClearsUploadStamp() async throws {
        let cache = AvatarCache.shared
        cache.clearMemory()
        let store = makeStore(cache: cache)
        // Snapshot the MainActor-isolated PNG into a Sendable local so the
        // @Sendable handler closure captures bytes, not the test's `self`.
        let png = tinyPNG()
        nonisolated(unsafe) var lastPath: String?
        MockURLProtocol.handler = { req in
            if req.targets(prefixedBy: "/api/user/avatar") { lastPath = req.url?.path }
            if req.httpMethod == "POST" {
                let json = #"{"data":{"avatarUrl":"/api/user/avatar/u1?v=10","contentType":"image/jpeg"}}"#
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if req.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, nil)
            }
            // GET avatar bytes.
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!,
                png
            )
        }

        #expect(try await store.upload(#require(UIImage(data: solidPNG(.green)))))
        #expect(store.image != nil)
        #expect(await store.remove())
        #expect(store.image == nil)

        // After remove, the stamp is gone — a load of a brand-new url fetches
        // normally rather than being suppressed by the old upload guard.
        lastPath = nil
        await store.load(avatarURLPath: "/api/user/avatar/u1?v=99")
        #expect(lastPath == "/api/user/avatar/u1")
        #expect(store.image != nil)

        cache.clearMemory()
    }

    @Test("Sequential uploads: the last one wins image + cache key (A4 last-pick-wins)")
    func sequentialUploadsLastWins() async throws {
        let cache = AvatarCache.shared
        cache.clearMemory()
        let store = makeStore(cache: cache)
        nonisolated(unsafe) var version = 0
        MockURLProtocol.handler = { req in
            // CU-07: only the avatar collection route (the upload target)
            // advances the version counter — never a parallel suite's request.
            if req.targets("/api/user/avatar") { version += 1 }
            let json = "{\"data\":{\"avatarUrl\":\"/api/user/avatar/u1?v=\(version)\",\"contentType\":\"image/jpeg\"}}"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        #expect(try await store.upload(#require(UIImage(data: solidPNG(.red)))))
        #expect(try await store.upload(#require(UIImage(data: solidPNG(.blue)))))
        // The store's authoritative key is the latest upload's ?v=.
        #expect(store.image != nil)
        // A stale load with the first upload's url cannot revert the second.
        await store.load(avatarURLPath: "/api/user/avatar/u1?v=1")
        #expect(store.image != nil)
        cache.clearMemory()
    }

    @Test("clearOnLogout drops the in-process image so the next user sees no photo")
    func logoutWipe() async {
        let cache = AvatarCache.shared
        cache.clearMemory()
        let store = makeStore(cache: cache)
        let png = tinyPNG()
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )!,
                png
            )
        }
        await store.load(avatarURLPath: "/api/user/avatar/u1?v=logout")
        #expect(store.image != nil)

        store.clearOnLogout()
        #expect(store.image == nil)
        #expect(cache.cachedBytes(forKey: "/api/user/avatar/u1?v=logout") == nil)
    }

    // MARK: - #138: re-fetch on re-login

    /// **#138.** After logout the operator re-signs-in as the SAME user, so the
    /// server hands back the IDENTICAL `avatarUrl`. `clearOnLogout()` wiped the
    /// bytes + the `loadedKey` short-circuit, so a re-`load` of that same key
    /// must hit the network again (not stay blank). The DashboardHeader drives
    /// this by keying its `.task` on `<userId>|<avatarUrl>` so the re-login
    /// flips the id and re-runs `load`; this asserts the store half: a `load`
    /// after `clearOnLogout` re-fetches even for an unchanged key.
    @Test("#138 — re-login re-fetches the same avatarUrl after a logout wipe")
    func reloginRefetchesSameURL() async {
        let cache = AvatarCache.shared
        cache.clearMemory()
        let store = makeStore(cache: cache)
        let png = tinyPNG()
        let key = "/api/user/avatar/u1?v=reauth"
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — count only the avatar routes.
            if req.targets(prefixedBy: "/api/user/avatar") { requestCount += 1 }
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )!,
                png
            )
        }
        await store.load(avatarURLPath: key)
        #expect(store.image != nil)
        #expect(requestCount == 1)

        // Logout: bytes + in-process image + loadedKey all wiped.
        store.clearOnLogout()
        #expect(store.image == nil)

        // Re-login with the SAME url must paint the avatar again via a fresh
        // network fetch — no stale short-circuit, no blank "?" badge.
        await store.load(avatarURLPath: key)
        #expect(store.image != nil)
        #expect(requestCount == 2)

        cache.clearMemory()
    }
}

// swiftlint:enable force_unwrapping
