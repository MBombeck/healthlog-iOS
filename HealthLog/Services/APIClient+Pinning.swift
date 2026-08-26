import Foundation

// Aus `APIClient.swift` herausgeloest (reine Verschiebung, kein
// Verhaltenswechsel — PROJECT_GUIDE.md file_length-Disziplin). Die Datei stand seit
// dem Umzug der ISO8601-Helfer bei 999 von 1000 Zeilen; jede weitere Zeile —
// auch ein Kommentar — reisst das `file_length`-Error-Limit. Hier liegen die
// drei Datei-scope-Typen rund um TLS-Pinning und die Probe-Session, die mit
// dem Transport-Kern des Actors nichts zu tun haben.

// MARK: - Pinning Delegate

/// `internal` (not `private`) so the onboarding + Settings server-URL
/// probes can build a one-shot ephemeral `URLSession` that still runs
/// through the same pin-check contract as `APIClient` — see H-2.
/// Probe-side pinning is the only thing standing between an
/// attacker-controlled host and a Keychain write that re-targets the
/// entire authenticated session.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pinner: CertificatePinner

    init(pinner: CertificatePinner) {
        self.pinner = pinner
    }

    /// Disposition the delegate applies to a `NSURLAuthenticationMethodServerTrust`
    /// challenge, factored out as a pure value so the security-critical branch
    /// logic is unit-testable without synthesizing a live
    /// ``URLAuthenticationChallenge``.
    enum ServerTrustDisposition: Equatable {
        /// Hand the challenge back to the loading system so its DEFAULT X.509
        /// chain validation runs. The ONLY correct answer for a host we don't
        /// pin — vouching for a raw `URLCredential(trust:)` built from the
        /// UNEVALUATED trust would REPLACE (and thereby skip) system validation,
        /// accepting any attacker cert (audit C1). `.performDefaultHandling` is
        /// NOT a blanket accept: baseline trust eval still rejects untrusted /
        /// self-signed chains.
        case systemDefault
        /// Pinned host whose chain passed baseline eval AND matched a bundled
        /// SPKI pin — accept it explicitly.
        case pinnedValid
        /// Pinned host that FAILED the pin check — reject the connection.
        case pinnedInvalid
    }

    /// Pure disposition-selection for a server-trust challenge. `trustIsValid`
    /// is evaluated lazily so the (comparatively expensive) pin validation only
    /// runs on the pinned path. See ``ServerTrustDisposition`` for the C1
    /// rationale behind the two `.systemDefault` fallbacks.
    static func serverTrustDisposition(
        pinnerEnabled: Bool,
        isPinnedHost: Bool,
        trustIsValid: () -> Bool
    ) -> ServerTrustDisposition {
        // Pinning off entirely (e.g. a self-hoster who shipped no pin set):
        // defer to the system's default trust validation — NOT a blanket
        // accept (audit C1).
        guard pinnerEnabled else { return .systemDefault }
        // Host outside the configured pin set (the demo backend
        // `demo.healthlog.dev`, or any non-configured self-hosted instance):
        // system default trust validation still applies (audit C1).
        guard isPinnedHost else { return .systemDefault }
        return trustIsValid() ? .pinnedValid : .pinnedInvalid
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else
        {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Pin set targets the configured cert chain — by default the managed
        // cloud (via `HLPinnedHosts`); a self-hoster rebuilding
        // under their own bundle-id sets their own host(s) + SPKI hashes. Hosts
        // outside the configured list (the demo backend `demo.healthlog.dev`, or
        // any non-configured self-hosted instance), and the pinning-disabled
        // build, fall back to the loading system's DEFAULT X.509 chain
        // validation via `.performDefaultHandling`. This is NOT a blanket
        // accept: an attacker presenting an untrusted / self-signed cert for a
        // non-pinned host is still rejected by baseline trust eval (audit C1 —
        // previously these paths answered with a raw `URLCredential(trust:)`
        // over the UNEVALUATED trust, which SKIPPED validation entirely).
        // Pinned hosts additionally require an SPKI match. Release + Debug both
        // honour this — H-2 closed the Debug-only bypass that previously let
        // Release probe paths through with no pin check at all.
        let host = challenge.protectionSpace.host
        switch Self.serverTrustDisposition(
            pinnerEnabled: pinner.isEnabled,
            isPinnedHost: pinner.isPinnedHost(host),
            trustIsValid: { pinner.validate(trust: trust) }
        ) {
        case .systemDefault:
            completionHandler(.performDefaultHandling, nil)
        case .pinnedValid:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .pinnedInvalid:
            // Host-only logging is the mandated form ("Server-URLs: nur Host bleibt") — no path/query.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.security.error("Cert-Pinning failure for \(challenge.protectionSpace.host, privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Probe Session Factory

extension URLSession {
    /// Builds a one-shot ephemeral session for the onboarding +
    /// Settings server-URL probes that respects the same SPKI-pin
    /// contract as the production `APIClient`. Per H-2: the probe
    /// runs *before* Keychain is updated with the candidate URL, so
    /// if the user pastes a managed-cloud-looking host, the
    /// response must come from a server whose
    /// SPKI hash is in the bundled pin set — otherwise an attacker
    /// can flip the entire authenticated session at the probe step.
    ///
    /// Self-hosted hosts fall back to default server-trust validation
    /// (the documented model — the bundled pin set cannot cover BYO
    /// instances). Caller is responsible for `invalidateAndCancel()`.
    static func healthLogProbeSession(pinner: CertificatePinner) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let delegate = PinningDelegate(pinner: pinner)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

// MARK: - Test hook (M-2)

/// Internal escape-hatch so the `setEnvironment` post-auth guard test can
/// exercise the rejection branch without aborting the Debug test runner via
/// `assertionFailure`. Production code never flips this — the hook only
/// exists to make the guard observable in unit tests.
enum _HLAPIClientTestHook {
    nonisolated(unsafe) static var suppressAssertion: Bool = false
}
