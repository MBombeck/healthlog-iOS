import Foundation
@testable import HealthLog
import Testing

/// **Phase 08 Wave 1 — the resolver against the frozen matrix.**
///
/// Wave 0 wrote down what every server-answer × cache-shape cell has to come out
/// as; this measures the implementation against that table cell by cell instead
/// of restating it, so the two cannot drift apart without one of them failing.
///
/// It lives in an extension in its own file rather than inside
/// `OnboardingRouteResolverTests.swift`: that file is already 415 lines and the
/// strict-lint baseline refuses new `type_body_length` findings.
extension OnboardingRouteResolverTests {
    // MARK: - Every cell of the frozen matrix

    @Test("the resolver answers every frozen matrix cell exactly as Wave 0 wrote it")
    func resolverMatchesTheFrozenMatrix() {
        for row in Self.frozenMatrix {
            let actual = PostAuthenticationRouteResolver.resolve(server: row.server, cache: row.cache)
            #expect(
                actual == row.route,
                "\(row.server.rawValue) × \(row.cache) resolved to \(actual) but the matrix says \(row.route)"
            )
        }
    }

    @Test("the sign-in method is not an input to the decision")
    func methodIsNotAnInput() {
        for row in Self.frozenMatrix {
            let routes = Set(PostAuthenticationRouteInput.Method.allCases.map { method in
                PostAuthenticationRouteResolver.resolve(
                    PostAuthenticationRouteInput(
                        owner: .init(id: "owner-a", generation: 1),
                        method: method,
                        server: row.server,
                        cache: row.cache
                    )
                )
            })
            #expect(routes == [row.route], "\(row.server.rawValue) × \(row.cache) is method-dependent")
        }
    }

    @Test("the owner never changes the decision, only which cache may be offered")
    func ownerIdentityDoesNotSteerTheDecision() {
        let owners = [
            PostAuthenticationRouteInput.Owner(id: "owner-a", generation: 1),
            PostAuthenticationRouteInput.Owner(id: "owner-a", generation: 9),
            PostAuthenticationRouteInput.Owner(id: "owner-b", generation: 1)
        ]
        for row in Self.frozenMatrix {
            let routes = Set(owners.map { owner in
                PostAuthenticationRouteResolver.resolve(
                    PostAuthenticationRouteInput(
                        owner: owner,
                        method: .oidc,
                        server: row.server,
                        cache: row.cache
                    )
                )
            })
            #expect(routes == [row.route], "\(row.server.rawValue) × \(row.cache) reads the owner id")
        }
    }

    // MARK: - The two flags that are not the same flag

    @Test("a genuinely missing required datum is the only way back into setup")
    func missingRequiredDatumNarrowsShellToSetup() {
        for row in Self.frozenMatrix {
            let narrowed = PostAuthenticationRouteResolver.resolve(
                server: row.server,
                cache: row.cache,
                missingRequiredDatum: true
            )
            if row.route == .authenticatedShell {
                #expect(narrowed == .setup, "a missing required datum must divert the shell hand-off")
            } else {
                #expect(narrowed == row.route, "a missing datum may not turn ambiguity into an answer")
            }
        }
    }

    @Test("a declined optional permission moves no route at all")
    func declinedOptionalPermissionMovesNothing() {
        for row in Self.frozenMatrix {
            let declined = PostAuthenticationRouteResolver.resolve(
                PostAuthenticationRouteInput(
                    owner: .init(id: "owner-a", generation: 1),
                    method: .password,
                    server: row.server,
                    cache: row.cache,
                    optionalPermissionDenied: true
                )
            )
            #expect(declined == row.route, "declining an optional step must not read as unfinished setup")
        }
    }

    // MARK: - The properties the matrix exists to guarantee

    @Test("another account's cache is never spent, in any server state")
    func foreignCacheIsNeverEvidence() {
        for server in PostAuthenticationRouteInput.ServerCompletion.allCases {
            for completed in [true, false] {
                let foreign = PostAuthenticationRouteResolver.resolve(
                    server: server,
                    cache: .otherAccount(completed: completed)
                )
                let none = PostAuthenticationRouteResolver.resolve(server: server, cache: .absent)
                #expect(
                    foreign == none,
                    "\(server.rawValue) treats another account's \(completed) as evidence"
                )
            }
        }
    }

    @Test("an unresolved lookup without same-account evidence is always retryable")
    func ambiguityWithoutEvidenceIsAlwaysRetryable() {
        let unusable: [PostAuthenticationRouteInput.CachedCompletion] = [
            .absent, .otherAccount(completed: true), .otherAccount(completed: false)
        ]
        for cache in unusable {
            #expect(
                PostAuthenticationRouteResolver.resolve(server: .unavailable, cache: cache)
                    == .retryCompletionLookup
            )
        }
    }

    @Test("a deployment that carries no field is answered, not retried forever")
    func endpointAbsentNeverRetries() {
        for cache in Self.everyCacheShape {
            #expect(
                PostAuthenticationRouteResolver.resolve(server: .endpointAbsent, cache: cache)
                    != .retryCompletionLookup,
                "a server that will never answer must not be asked again on a loop"
            )
        }
    }

    @Test("a server answer outranks a same-account cache in both directions")
    func serverAnswerOutranksItsOwnMirror() {
        #expect(
            PostAuthenticationRouteResolver.resolve(
                server: .completed,
                cache: .sameAccount(completed: false)
            ) == .authenticatedShell
        )
        #expect(
            PostAuthenticationRouteResolver.resolve(
                server: .incomplete,
                cache: .sameAccount(completed: true)
            ) == .setup
        )
    }

    // MARK: - Fixtures

    struct FrozenCell {
        let server: PostAuthenticationRouteInput.ServerCompletion
        let cache: PostAuthenticationRouteInput.CachedCompletion
        let route: PostAuthenticationRoute
    }

    static let everyCacheShape: [PostAuthenticationRouteInput.CachedCompletion] = [
        .absent,
        .sameAccount(completed: false),
        .sameAccount(completed: true),
        .otherAccount(completed: false),
        .otherAccount(completed: true)
    ]

    /// The Wave-0 table, transcribed. Deliberately a second copy rather than a
    /// reference to the private one next door: if the two ever disagree, one of
    /// them is wrong and both files fail, which is the point.
    static let frozenMatrix: [FrozenCell] = [
        FrozenCell(server: .completed, cache: .absent, route: .authenticatedShell),
        FrozenCell(server: .completed, cache: .sameAccount(completed: false), route: .authenticatedShell),
        FrozenCell(server: .completed, cache: .sameAccount(completed: true), route: .authenticatedShell),
        FrozenCell(server: .completed, cache: .otherAccount(completed: false), route: .authenticatedShell),
        FrozenCell(server: .completed, cache: .otherAccount(completed: true), route: .authenticatedShell),
        FrozenCell(server: .incomplete, cache: .absent, route: .setup),
        FrozenCell(server: .incomplete, cache: .sameAccount(completed: false), route: .setup),
        FrozenCell(server: .incomplete, cache: .sameAccount(completed: true), route: .setup),
        FrozenCell(server: .incomplete, cache: .otherAccount(completed: false), route: .setup),
        FrozenCell(server: .incomplete, cache: .otherAccount(completed: true), route: .setup),
        FrozenCell(server: .endpointAbsent, cache: .absent, route: .setup),
        FrozenCell(server: .endpointAbsent, cache: .sameAccount(completed: false), route: .setup),
        FrozenCell(server: .endpointAbsent, cache: .sameAccount(completed: true), route: .authenticatedShell),
        FrozenCell(server: .endpointAbsent, cache: .otherAccount(completed: false), route: .setup),
        FrozenCell(server: .endpointAbsent, cache: .otherAccount(completed: true), route: .setup),
        FrozenCell(server: .unavailable, cache: .absent, route: .retryCompletionLookup),
        FrozenCell(server: .unavailable, cache: .sameAccount(completed: false), route: .setup),
        FrozenCell(server: .unavailable, cache: .sameAccount(completed: true), route: .authenticatedShell),
        FrozenCell(server: .unavailable, cache: .otherAccount(completed: false), route: .retryCompletionLookup),
        FrozenCell(server: .unavailable, cache: .otherAccount(completed: true), route: .retryCompletionLookup)
    ]
}
