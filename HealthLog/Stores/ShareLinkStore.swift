import Foundation
import Observation

/// `@Observable` store over ``ShareLinkRepository`` for the clinician share-link
/// surface (create / list / revoke).
///
/// **State machine.** `links` is the authoritative server list. `freshToken` holds
/// the raw `hls_…` token from the most recent create — surfaced **once** for
/// copy/share, then cleared (it is unrecoverable). `error` carries a user-facing
/// string (rate-limit 429 included, via `userFacingDescription`).
///
/// **Secrets.** `freshToken` is the only place a raw token lives, and only
/// transiently; it is never logged, never written to disk, and dropped on
/// `clearFreshToken()` / `clearOnLogout()`.
@MainActor
@Observable
public final class ShareLinkStore {
    public private(set) var links: [ShareLinkDTO] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isCreating: Bool = false
    public private(set) var error: String?
    /// The just-minted raw token, surfaced once for copy/share. `nil` once
    /// consumed or after `clearFreshToken()`.
    public private(set) var freshToken: String?
    /// The label of the just-minted link, so the one-time token sheet can name it.
    public private(set) var freshLinkLabel: String?
    /// The auto-minted passphrase from the most recent create, surfaced **once**
    /// alongside the token (server v1.18.7). `nil` once consumed/cleared. Secret —
    /// never logged, never persisted.
    public private(set) var freshPassphrase: String?
    /// Absolute share URL from the create response (`<base>/c/<token>`). Used as the
    /// shareable artifact; `nil` once cleared.
    public private(set) var freshShareUrl: String?
    /// Absolute QR payload (share URL with passphrase in the `#k=` fragment). This is
    /// what the QR image encodes; `nil` once cleared. Secret — never logged.
    public private(set) var freshQrUrl: String?
    /// Whether the just-minted link is passphrase-protected (v1.18.7+). Legacy =
    /// `false`.
    public private(set) var freshProtected: Bool = false
    /// Leaf ids this route may offer: the server's live vocabulary minus what
    /// ``ShareLinkSelectionPolicy`` forbids, in catalogue order. Empty until the
    /// capabilities call lands — never a local fallback list.
    public private(set) var offeredLeaves: [String] = []
    /// The **full** live vocabulary (including forbidden ids), for pre-flight
    /// ``ReportSelection/validate(against:)``. Empty until loaded.
    public private(set) var leafVocabulary: Set<String> = []
    /// Whether the server actually served a usable v2 selection vocabulary. When
    /// `false` the UI must say so rather than present an empty picker that reads
    /// as "nothing to share".
    public private(set) var hasSelectionVocabulary: Bool = false

    private let repo: ShareLinkRepository
    private let capabilities: ServerCapabilitiesRepository

    public init(repo: ShareLinkRepository, capabilities: ServerCapabilitiesRepository) {
        self.repo = repo
        self.capabilities = capabilities
    }

    /// Active (non-revoked, non-expired) links, newest expiry-window first.
    public var activeLinks: [ShareLinkDTO] {
        links.filter(\.active)
    }

    /// Links the server retired during the v2-selection migration (0275). They
    /// are dead — no reissue exists — and the only honest recovery is minting a
    /// fresh link, which also means a fresh token and passphrase.
    public var retiredLinks: [ShareLinkDTO] {
        links.filter(\.needsReselection)
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            links = try await repo.list()
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't load share links. Please try again.")
        }
    }

    /// Pull the live leaf vocabulary from `GET /api/meta/capabilities`.
    ///
    /// A failure here is **not** surfaced as an error banner: the link list is
    /// still usable and the create sheet renders its own honest "the selection
    /// list couldn't be loaded" state off ``hasSelectionVocabulary``. Silently
    /// substituting a local list is the one thing we must not do — the whole
    /// point of the capabilities route is that the client has no opinion about
    /// which leaves exist.
    public func loadSelectionVocabulary() async {
        do {
            let share = try await capabilities.fetch().share
            leafVocabulary = share.leafVocabulary
            offeredLeaves = ShareLinkSelectionPolicy.offeredLeaves(from: share.leaves)
            hasSelectionVocabulary = share.hasSelectionVocabulary
        } catch {
            leafVocabulary = []
            offeredLeaves = []
            hasSelectionVocabulary = false
            HLLog.api.warning("share-link selection vocabulary unavailable — create sheet degrades")
        }
    }

    /// Mint a new link. On success, refreshes the list and stashes the one-time
    /// raw token in ``freshToken`` for the caller to present. Returns `true` on
    /// success so the UI can drive the one-time-token presentation.
    @discardableResult
    public func create(_ body: CreateShareLinkBody) async -> Bool {
        isCreating = true
        error = nil
        defer { isCreating = false }
        do {
            let link = try await repo.create(body)
            freshToken = link.token
            freshLinkLabel = link.label
            freshPassphrase = link.passphrase
            freshShareUrl = link.shareUrl
            freshQrUrl = link.qrUrl
            freshProtected = link.protected
            await load()
            return true
        } catch let err as ShareLinkError {
            // A selection refusal (422 share-link.selection.*) — say what was
            // refused, never the wire code.
            error = err.userFacingDescription
            return false
        } catch let err as HLError {
            error = err.userFacingDescription
            return false
        } catch {
            self.error = String(localized: "Couldn't create the share link. Please try again.")
            return false
        }
    }

    /// Revoke a link. A 404 (already gone) is treated as success by the
    /// repository, so this only surfaces genuine failures.
    public func revoke(id: String) async {
        error = nil
        do {
            try await repo.revoke(id: id)
            await load()
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't revoke the share link. Please try again.")
        }
    }

    /// Drop the one-time token once the user has copied/shared (or dismissed) it.
    public func clearFreshToken() {
        freshToken = nil
        freshLinkLabel = nil
        freshPassphrase = nil
        freshShareUrl = nil
        freshQrUrl = nil
        freshProtected = false
    }

    public func clearError() {
        error = nil
    }

    public func clearOnLogout() {
        links = []
        offeredLeaves = []
        leafVocabulary = []
        hasSelectionVocabulary = false
        freshToken = nil
        freshLinkLabel = nil
        freshPassphrase = nil
        freshShareUrl = nil
        freshQrUrl = nil
        freshProtected = false
        error = nil
    }
}
