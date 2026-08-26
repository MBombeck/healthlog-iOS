import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// M-6 (v0.6.2) — locks the strict `[A-Za-z0-9_-]` allowlist + 64-char cap
/// shared by `HealthKitBackfillWindowStore.partitionToken` and
/// `HealthKitService.partitionToken`. The two implementations are deliberately
/// duplicated (the store lives in the iOS-free core; the service requires
/// HealthKit). Drifting them would partition the same user under two distinct
/// keys, so this suite parameterises over both call sites with the same
/// fixtures to keep them aligned.
///
/// **v0.6.2.3 F3-SEC reconcile:** `HKReadinessStore.partitionToken` was missed
/// in the v0.6.2.0 W-SEC-B landing — it kept the legacy
/// `replacingOccurrences(of: ".", with: "_")` mapping while the two sites
/// above moved to the strict allowlist. The drift meant a userId like
/// `anna.fischer` produced `anna_fischer` in the readiness store but
/// `annafischer` in the backfill-window + service stores. Production userIds
/// are `usr_<cuid>`-shaped (so the drift was a no-op in practice), but
/// allowing two sites to diverge is the kind of state that compounds. The
/// readiness store is now brought in line + pinned by the cross-site drift
/// suite below.
@Suite("partitionToken allowlist + cap (M-6)")
struct PartitionTokenHardeningTests {
    /// Drop-in shim so the suite can call both implementations with a single
    /// fixture body.
    private static func storeToken(_ id: String?) -> String {
        HealthKitBackfillWindowStore.partitionToken(for: id)
    }

    #if canImport(HealthKit)
        private static func serviceToken(_ id: String?) -> String {
            HealthKitService.partitionToken(for: id)
        }
    #endif

    #if !SWIFT_PACKAGE
        /// Derives the readiness-store partition token from a public key
        /// helper. `HKReadinessStore.partitionToken` itself is `private`
        /// (the helper is only exposed via the `lastSyncedKey` /
        /// `requestedKey` / `bannerDismissedKey` builders), so we strip
        /// the documented prefix to read the inner token back out. Lives
        /// in the App-target-only build (`#if !SWIFT_PACKAGE`) because the
        /// readiness store doesn't compile in the iOS-free core.
        private static func readinessToken(_ id: String?) -> String {
            let key = HKReadinessStore.requestedKey(for: id)
            let prefix = HKReadinessStore.requestedKeyPrefix
            #expect(key.hasPrefix(prefix), "Readiness key must carry the documented prefix")
            return String(key.dropFirst(prefix.count))
        }
    #endif

    // MARK: - Anonymous + happy paths

    @Test("nil / empty / whitespace → _anonymous")
    func anonymousPaths() {
        #expect(Self.storeToken(nil) == "_anonymous")
        #expect(Self.storeToken("") == "_anonymous")
        #expect(Self.storeToken("   ") == "_anonymous")
        #expect(Self.storeToken("\t\n") == "_anonymous")
        #if canImport(HealthKit)
            #expect(Self.serviceToken(nil) == "_anonymous")
            #expect(Self.serviceToken("") == "_anonymous")
            #expect(Self.serviceToken("   ") == "_anonymous")
        #endif
    }

    @Test("Canonical cuid passes through unchanged")
    func canonicalCuid() {
        let cuid = "cm5abc123def456ghi789"
        #expect(Self.storeToken(cuid) == cuid)
        #if canImport(HealthKit)
            #expect(Self.serviceToken(cuid) == cuid)
        #endif
    }

    @Test("Canonical UUID passes through unchanged (hyphens allowed)")
    func canonicalUUID() {
        let uuid = "11111111-2222-3333-4444-555555555555"
        #expect(Self.storeToken(uuid) == uuid)
        #if canImport(HealthKit)
            #expect(Self.serviceToken(uuid) == uuid)
        #endif
    }

    // MARK: - Disallowed-char stripping

    @Test("Slash + dot + colon are stripped, not aliased")
    func slashDotColonStripped() {
        // The legacy implementation only handled `.`, so `/` would have
        // survived into the UserDefaults key. M-6 strips slashes too.
        #expect(Self.storeToken("user/x.y:z") == "userxyz")
        #if canImport(HealthKit)
            #expect(Self.serviceToken("user/x.y:z") == "userxyz")
        #endif
    }

    @Test("Path-traversal `..` is reduced to empty → _anonymous")
    func traversalAttempt() {
        #expect(Self.storeToken("..") == "_anonymous")
        #expect(Self.storeToken("../../etc/passwd") == "etcpasswd")
        #if canImport(HealthKit)
            #expect(Self.serviceToken("..") == "_anonymous")
        #endif
    }

    @Test("Unicode look-alike characters are dropped")
    func unicodeDropped() {
        // German umlauts, emoji, Cyrillic look-alikes — none are in the
        // ASCII allowlist, so they vanish.
        #expect(Self.storeToken("user_äöü") == "user_")
        #expect(Self.storeToken("user_🔥") == "user_")
        // Cyrillic 'а' (U+0430) looks identical to ASCII 'a' but is dropped.
        #expect(Self.storeToken("аbc") == "bc")
        #if canImport(HealthKit)
            #expect(Self.serviceToken("user_äöü") == "user_")
        #endif
    }

    @Test("Whitespace inside the id is dropped")
    func internalWhitespace() {
        #expect(Self.storeToken("user with spaces") == "userwithspaces")
        #if canImport(HealthKit)
            #expect(Self.serviceToken("user with spaces") == "userwithspaces")
        #endif
    }

    @Test("Allowlist preserves all of A-Z, a-z, 0-9, `_`, `-`")
    func allowlistCoverage() {
        let raw = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        #expect(raw.count == 64) // exactly at the cap
        #expect(Self.storeToken(raw) == raw)
        #if canImport(HealthKit)
            #expect(Self.serviceToken(raw) == raw)
        #endif
    }

    // MARK: - Length cap

    @Test("Over-length input is truncated to 64 chars")
    func lengthCap() {
        let oversized = String(repeating: "a", count: 200)
        let token = Self.storeToken(oversized)
        #expect(token.count == 64)
        #expect(token == String(repeating: "a", count: 64))
        #if canImport(HealthKit)
            let svc = Self.serviceToken(oversized)
            #expect(svc.count == 64)
            #expect(svc == String(repeating: "a", count: 64))
        #endif
    }

    @Test("Truncation happens AFTER stripping (disallowed chars don't pad the cap)")
    func truncationAfterStripping() {
        // 70 dots followed by 65 'a's. After stripping → 65 'a's; cap → 64 'a's.
        let raw = String(repeating: ".", count: 70) + String(repeating: "a", count: 65)
        let token = Self.storeToken(raw)
        #expect(token.count == 64)
        #expect(token == String(repeating: "a", count: 64))
    }

    @Test("Exactly 64 chars passes through unchanged")
    func exactly64() {
        let raw = String(repeating: "x", count: 64)
        #expect(Self.storeToken(raw) == raw)
        #if canImport(HealthKit)
            #expect(Self.serviceToken(raw) == raw)
        #endif
    }

    // MARK: - Cross-site drift

    #if canImport(HealthKit)
        @Test(
            "Store + service implementations stay aligned for tricky inputs",
            arguments: [
                "simple",
                "user.with.dots",
                "user_with_hyphens-and-numbers123",
                "../../etc/passwd",
                "üñîçødé",
                "user/path/traversal",
                String(repeating: "a", count: 70),
                "MixedCase_ID-123"
            ]
        )
        func storeAndServiceMatch(input: String) {
            #expect(Self.storeToken(input) == Self.serviceToken(input))
        }
    #endif

    #if !SWIFT_PACKAGE
        /// v0.6.2.3 F3-SEC reconcile: the readiness store is the third call
        /// site for `partitionToken` and was missed in the v0.6.2.0 hardening
        /// landing. Same fixtures as the store/service drift test above —
        /// any future refactor that touches one site must touch all three
        /// or this assertion lights up.
        @Test(
            "Readiness store stays aligned with backfill + service for tricky inputs",
            arguments: [
                "simple",
                "user.with.dots",
                "user_with_hyphens-and-numbers123",
                "../../etc/passwd",
                "üñîçødé",
                "user/path/traversal",
                String(repeating: "a", count: 70),
                "MixedCase_ID-123",
                "usr_clm5abcdefghij" // shape of canonical production userId
            ]
        )
        func readinessMatchesStoreAndService(input: String) {
            #expect(Self.readinessToken(input) == Self.storeToken(input))
            #expect(Self.readinessToken(input) == Self.serviceToken(input))
        }

        @Test("Readiness anonymous fallback: nil / empty / whitespace → _anonymous")
        func readinessAnonymousFallback() {
            #expect(Self.readinessToken(nil) == "_anonymous")
            #expect(Self.readinessToken("") == "_anonymous")
            #expect(Self.readinessToken("   ") == "_anonymous")
        }

        @Test("Readiness strips slash + dot + colon (was: only dot replaced)")
        func readinessStripsDisallowed() {
            // The legacy readiness-store mapping was
            // `replacingOccurrences(of: ".", with: "_")`, so
            // `user.with.dots` produced `user_with_dots` — drifting from
            // both other sites which produce `userwithdots`. Pin the new
            // behaviour explicitly so the regression can't sneak back.
            #expect(Self.readinessToken("user.with.dots") == "userwithdots")
            #expect(Self.readinessToken("user/x.y:z") == "userxyz")
            #expect(Self.readinessToken("..") == "_anonymous")
        }

        @Test("Readiness truncates to 64 chars")
        func readinessLengthCap() {
            let oversized = String(repeating: "x", count: 200)
            #expect(Self.readinessToken(oversized).count == 64)
        }
    #endif
}
