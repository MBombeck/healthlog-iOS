import Foundation
import ImageIO
import Observation
import SwiftUI
import UIKit

/// **v0.8.0 W11 — self-hosted avatar display + upload orchestration.**
///
/// Owns the avatar image lifecycle for the display surfaces (DashboardHeader,
/// ProfileScreen) and the edit surface (EditProfileScreen). The Gravatar leak
/// is gone (v0.6.2); the photo now lives on the OWN server and is fetched
/// owner-scoped through the pinned `APIClient` session — never a bare
/// `AsyncImage(url:)`, which would carry neither the Bearer token nor the
/// SPKI cert-pin.
///
/// Flow:
///  - `load(avatarURLPath:)` — resolves the bytes for the profile's
///    `avatarUrl`. Hits `AvatarCache` (in-memory, version-keyed) first; on a
///    miss it downloads through `AvatarRepository.fetchImageData` (pinned +
///    authenticated) and caches the bytes under the `?v=`-suffixed key. A 404
///    or any decode/transport failure leaves `image == nil` so the view falls
///    back to the initials monogram — never a broken state.
///  - `upload(_:)` — downscales the picked image to ≤ 2048px + recompresses
///    under the 2 MiB cap, POSTs multipart (idempotent), then refreshes the
///    profile so the new `avatarUrl` (`?v=` flipped) propagates.
///  - `remove()` — DELETEs the avatar + clears the in-memory image.
///
/// Logout wipe: the underlying bytes live in `AvatarCache.shared`, whose
/// `clearAll()` is already invoked from every logout path
/// (`AppContainer.performFullLocalLogout`). `clearOnLogout()` here drops the
/// in-process `image` + `loadedKey` so a SwiftUI re-paint between sign-out and
/// the cache-drop can't flash the previous user's photo.
@MainActor
@Observable
public final class AvatarStore {
    /// The resolved avatar image, or `nil` when none is loaded / load failed —
    /// the display primitive then renders initials.
    public private(set) var image: Image?
    /// `true` while an upload (or its post-refresh) is in flight — drives the
    /// progress affordance in the edit surface.
    public private(set) var isUploading: Bool = false
    /// Surfaced to the edit surface on a failed upload / delete.
    public private(set) var error: HLError?

    /// The `?v=`-suffixed avatar URL currently rendered, so a repeat `load`
    /// with the same key is a no-op and a flipped key (re-upload) forces a
    /// refetch.
    private var loadedKey: String?

    /// **v0.8.2 W1c (C4) — stale-image guard.** The `?v=` key of the most
    /// recently *uploaded* avatar. `upload` sets `image` directly from the
    /// freshly-encoded bytes, then calls `refreshProfile()`. If that refresh
    /// races and returns the *pre-flip* (old) `avatarUrl`, the display surface
    /// re-runs `load` with that stale key — which differs from `loadedKey`, so
    /// without this guard the old bytes would be fetched and overwrite the
    /// fresh photo. While set, `load` ignores any key that is NOT this one:
    /// the bytes we just uploaded are authoritative until a genuinely new
    /// upload (which re-stamps this) or a `remove` / explicit `load` clears it.
    private var lastUploadedKey: String?

    private let repo: AvatarRepository
    private let cache: AvatarCache
    /// Refreshes the user profile after a successful upload / delete so the
    /// `avatarUrl` (`?v=` cache-buster) propagates to the display surfaces.
    /// Injected so the store doesn't reach into `SettingsStore` directly.
    private let refreshProfile: @MainActor () async -> Void

    public init(
        repo: AvatarRepository,
        cache: AvatarCache = .shared,
        refreshProfile: @escaping @MainActor () async -> Void
    ) {
        self.repo = repo
        self.cache = cache
        self.refreshProfile = refreshProfile
    }

    // MARK: - Load

    /// Resolves the image for `avatarURLPath` (the profile's `avatarUrl`).
    /// `nil` clears the image (user removed the photo / never had one).
    ///
    /// `force` (v0.8.2 W1c / C4): when `true`, bypasses the `loadedKey`
    /// short-circuit and refetches even if the key is unchanged — a defensive
    /// escape hatch for the case where the server reuses the same `avatarUrl`
    /// after a re-upload (no `?v=` flip) and the operator would otherwise be
    /// stuck on a stale photo with no way to force a refresh.
    public func load(avatarURLPath: String?, force: Bool = false) async {
        guard let key = avatarURLPath, !key.isEmpty else {
            image = nil
            loadedKey = nil
            lastUploadedKey = nil
            return
        }
        // Stale-URL guard: a fresh upload set `image` directly and stamped
        // `lastUploadedKey`. A racing profile refresh that returns the OLD url
        // must NOT overwrite the just-uploaded photo. Only the upload's own key
        // (or a `force` reload of it) is honoured while the stamp stands.
        if let uploaded = lastUploadedKey, key != uploaded, !force { return }
        if key == loadedKey, image != nil, !force { return }

        // A `force` reload skips the in-memory cache too — the whole point is to
        // re-pull bytes when the server reused the URL (no `?v=` flip), so the
        // cached bytes for that key are exactly what we must not trust.
        if !force, let cached = cache.cachedBytes(forKey: key), let img = await Self.makeImageOffMain(from: cached) {
            image = img
            loadedKey = key
            return
        }

        do {
            guard let data = try await repo.fetchImageData(avatarURLPath: key),
                  let img = await Self.makeImageOffMain(from: data) else
            {
                // 404 / undecodable — fall back to initials, no broken state.
                image = nil
                loadedKey = key
                return
            }
            cache.storeBytes(data, forKey: key)
            image = img
            loadedKey = key
        } catch {
            // Transport failure — keep whatever we last painted (or initials);
            // do not surface as a user-facing error on a read.
            HLLog.cache.debug("Avatar fetch failed; using initials fallback")
        }
    }

    // MARK: - Upload

    /// Downscales + recompresses `uiImage` under the server limits and uploads
    /// it. On success refreshes the profile so the new `avatarUrl` lands, then
    /// the display surfaces reload through `load`.
    @discardableResult
    public func upload(_ uiImage: UIImage) async -> Bool {
        error = nil
        // v0.12 W8-5 — the encode is an up-to-12MP downscale + multi-pass JPEG
        // re-compression; running it on `@MainActor` stutters the picker
        // dismissal. `AvatarImageProcessor` is a pure enum over value types and
        // `UIImage` is `Sendable`, so the work moves off-main without a data
        // race. The result `(Data, String)` is `Sendable` and hops back cleanly.
        let encoded = await Task.detached(priority: .userInitiated) {
            AvatarImageProcessor.encode(uiImage)
        }.value
        guard let (data, mime) = encoded else {
            error = .unknown("Could not process the selected image.")
            return false
        }
        isUploading = true
        defer { isUploading = false }
        do {
            let result = try await repo.upload(imageData: data, mimeType: mime)
            // Seed the cache under the fresh `?v=` key so the next paint is
            // instant and doesn't re-download bytes we already hold.
            cache.storeBytes(data, forKey: result.avatarUrl)
            if let img = Self.makeImage(from: data) {
                image = img
                loadedKey = result.avatarUrl
                // Stamp the fresh key so a racing post-refresh `load` with a
                // stale url can't revert the photo we just uploaded (C4).
                lastUploadedKey = result.avatarUrl
            }
            await refreshProfile()
            return true
        } catch let err as HLError {
            error = err
            return false
        } catch {
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    // MARK: - Remove

    /// Deletes the stored avatar + clears the in-process image. Refreshes the
    /// profile so `avatarUrl` flips to `nil`.
    @discardableResult
    public func remove() async -> Bool {
        error = nil
        isUploading = true
        defer { isUploading = false }
        do {
            try await repo.delete()
            image = nil
            loadedKey = nil
            lastUploadedKey = nil
            cache.clearMemory()
            await refreshProfile()
            return true
        } catch let err as HLError {
            error = err
            return false
        } catch {
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    // MARK: - Logout

    public func clearOnLogout() {
        image = nil
        loadedKey = nil
        lastUploadedKey = nil
        error = nil
        isUploading = false
        // Bytes themselves are dropped by `AvatarCache.clearAll()` in the
        // shared logout cascade; clear the RAM copy here too in case this
        // store is reset on a path that doesn't run the full cascade.
        cache.clearMemory()
    }

    // MARK: - Helpers

    private static func makeImage(from data: Data) -> Image? {
        guard let ui = decodedImage(from: data) else { return nil }
        return Image(uiImage: ui)
    }

    /// **20-03 (R6) — the avatar is decoded ONCE to a bounded thumbnail.**
    ///
    /// The upload path allows up to 2048 px under a 2 MiB cap, the server stores
    /// what it is given, and `AvatarRepository` asks for the bytes back with no
    /// size parameter — there is none server-side and this plan invents none.
    /// The display surfaces are 44 pt (`DashboardHeader`) and 64 pt
    /// (`ProfileScreen`). A bare `UIImage(data:)` therefore handed SwiftUI a
    /// full-size bitmap at **scale 1.0**: the render server downscaled the whole
    /// upload on every pass, and UIKit was told the image was 1024 POINTS wide,
    /// so layout reasoned about it wrongly too.
    ///
    /// ImageIO's thumbnail decode reads only what it needs, so the ~23×
    /// reduction happens once per fetch instead of once per draw, and the
    /// `UIImage` carries the screen scale so `size × scale` is the pixel truth.
    ///
    /// A `SwiftUI.Image` exposes neither pixel dimensions nor a scale, which is
    /// why this seam exists at all: it is what `AvatarThumbnailTests` addresses.
    static func decodedImage(from data: Data) -> UIImage? {
        guard let thumbnail = thumbnailCGImage(from: data) else { return nil }
        return UIImage(cgImage: thumbnail, scale: UIScreen.main.scale, orientation: .up)
    }

    /// 64 pt at 3× is 192 px; 256 px is the next power-of-two above it and is
    /// the bound every avatar bitmap stays under.
    nonisolated static let thumbnailMaxPixelSize = 256

    /// The expensive half — reading only the pixels the bound needs — kept
    /// `nonisolated` so `load()` can run it off the main actor. Undecodable
    /// bytes stay `nil` so the display primitive falls back to the initials
    /// monogram: never a broken state.
    nonisolated static func thumbnailCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The decode `load()` uses: the ImageIO pass runs off the main actor, and
    /// only the (cheap) `UIImage` wrap with the screen scale happens back here.
    private static func makeImageOffMain(from data: Data) async -> Image? {
        let thumbnail = await Task.detached(priority: .userInitiated) {
            thumbnailCGImage(from: data)
        }.value
        guard let thumbnail else { return nil }
        return Image(uiImage: UIImage(cgImage: thumbnail, scale: UIScreen.main.scale, orientation: .up))
    }
}
