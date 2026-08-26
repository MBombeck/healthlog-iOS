import SwiftUI

// Splitting note (A360-4 / file_length-Disziplin): the assessment warm-poll
// (`loadAssessment` / `pollUntilReady`) + its helpers were lifted out of
// `InsightsMetricScreen.swift` to keep that file under the 600-line budget.
// Pure code movement — no behaviour change. The members reach the screen's
// `@State` / `@Environment` properties as an extension on the same type.

extension InsightsMetricScreen {
    // MARK: - Assessment (W46 — un-gated read)

    /// Fetches the per-metric assistant assessment through the
    /// `MetricInsightsRepository.fetchAssessment` read path.
    ///
    /// **Task #49 — re-gated behind the single remote-AI opt-in.** Task #46
    /// (commit `c1c2f1bd`) made this read un-gated so the assessment showed
    /// regardless of consent; the operator now wants ONE Settings opt-in to
    /// govern every remote-AI surface. We keep #46's SWR/decode mechanism but
    /// put the consent check back in FRONT of it: when the master opt-in is OFF
    /// we never fetch and leave `assessment` nil so `AssessmentCard`
    /// self-suppresses (hidden — `consentClosed: false`, never the consent CTA
    /// on this page). When ON, hide/show is then carried by `hasServer`
    /// (standalone) and the server envelope's `hasProvider` (no provider).
    /// **Task #50 — preparing→poll→ready.** The server serves the assessment
    /// stale-while-revalidate: on a cold cache it returns
    /// `{ hasProvider:true, text:null, preparing:true }` and warms the prose OUT
    /// OF BAND. The web POLLS the endpoint (`use-insight-status.ts`, 4 s cadence,
    /// 12-attempt ceiling) until ready text lands, then stops. iOS previously did
    /// a ONE-SHOT fetch → got the `preparing`/null body → `AssessmentCard`
    /// self-suppressed → the text never surfaced even though the server produced
    /// it seconds later (Task #50 root cause). This method mirrors the web poll:
    /// first paint from the daily SWR cache (yesterday's good prose), then poll
    /// the un-cached read until the warmed assessment arrives.
    ///
    /// Stops polling on: ready text, `insufficient`, no-provider, the attempt cap,
    /// or `Task` cancellation (page disappear / key flip — the `.task(id:)`
    /// modifier cancels this automatically, so the bounded `Task.sleep` throws
    /// and the loop exits with no leak).
    ///
    /// Best-effort — a failure leaves `assessment` nil (the card self-suppresses).
    ///
    /// **b177 W-ASSESS2 — gate widened to the explicit External-AI CHOICE, not
    /// only a completed grant.** `remoteAIEnabled` is true only once an informed-
    /// consent grant exists for a configured provider. Two real states broke the
    /// page with the old `remoteAIEnabled`-only gate while Settings still showed
    /// "Externe KI" as the selected source: (a) `.online` picked but the server
    /// has no provider configured yet (`aiOnlineIntentPending` — the pick is held
    /// as intent), and (b) a grant wiped by the logout cascade after the user had
    /// long since opted in. In both, the user's single master choice IS External
    /// AI, the GET is read-only (no health-data transmission — W46 doc on
    /// `fetchAssessment`), and the server envelope (`hasProvider`) carries the
    /// authoritative hide/show. `.none` / on-device / BYO still never fetch.
    func loadAssessment() async {
        guard backend.hasServer,
              externalAIChosen,
              let repo = appContainer?.metricInsightsRepo else
        {
            assessment = nil
            return
        }
        assessmentLoading = true
        // QoS-3 — clear any prior terminal-failure flag so a pull-to-refresh /
        // foreground retry starts clean (the card returns to skeleton/ready).
        assessmentFailed = false
        defer { assessmentLoading = false }
        let locale = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "de"

        // Initial cache-first paint.
        let first: MetricStatusDTO?
        do {
            first = try await repo.fetchAssessment(metric: kind, locale: locale)
        } catch {
            logAssessmentFailure(error)
            assessment = nil
            // QoS-3 — surface the terminal caption only when no prose ever
            // painted; a stale-good cached assessment would still be on screen.
            assessmentFailed = true
            return
        }
        assessment = first

        // Terminal payloads (ready text / insufficient / no-provider / no
        // surface) need no poll. Only a `preparing`/`revalidating` body keeps the
        // bounded poll alive — exactly the web's `preparing || revalidating`
        // predicate.
        guard let first, first.isPreparing else { return }
        await pollUntilReady(repo: repo, locale: locale)
    }

    /// Bounded poll of the un-cached assessment read while the server warms the
    /// prose. Mirrors the web ceiling: 4 s cadence, 12 attempts (~48 s). Cancels
    /// cleanly when the owning `.task(id:)` is torn down (the `Task.sleep` throws
    /// `CancellationError` and we exit without surfacing it).
    private func pollUntilReady(repo: MetricInsightsRepository, locale: String) async {
        for _ in 0 ..< Self.assessmentPollMaxAttempts {
            do {
                try await Task.sleep(for: Self.assessmentPollInterval)
            } catch {
                return // cancelled — page gone / key flipped.
            }
            let next: MetricStatusDTO?
            do {
                next = try await repo.pollAssessment(metric: kind, locale: locale)
            } catch {
                logAssessmentFailure(error)
                // QoS-3 — a transient error stops the poll. Flip the preparing
                // skeleton to the terminal "couldn't load — pull to refresh"
                // caption instead of leaving it spinning indefinitely.
                assessmentFailed = true
                return
            }
            guard let next else { return }
            assessment = next
            // Stop the moment the payload is terminal — ready text just landed,
            // the metric is insufficient, or the provider config changed.
            if !next.isPreparing {
                // Persist a freshly-warmed assessment so the next mount paints it
                // instantly (cache-first). No-op for non-ready terminal bodies.
                await repo.cacheReadyAssessment(metric: kind, locale: locale, dto: next)
                return
            }
        }
        // Cap reached — QoS-3: if we exhausted the bounded window still in the
        // preparing state (no ready text ever landed), flip to the terminal
        // caption so the user can pull-to-refresh instead of staring at an
        // indefinite skeleton. A last-good/ready payload set `assessment` to a
        // non-preparing body above and already returned, so this only fires when
        // the card is genuinely still preparing.
        if assessment?.isPreparing == true {
            assessmentFailed = true
        }
    }

    /// b177 W-ASSESS2 — true when the user's chosen assistant source is External
    /// AI: either fully granted (`remoteAIEnabled`) or held as the explicit
    /// `.online` intent (provider not configured yet / grant record lost). Drives
    /// the read-only assessment fetch; see `loadAssessment` doc.
    var externalAIChosen: Bool {
        guard let appContainer else { return false }
        return appContainer.remoteAIEnabled || appContainer.aiOnlineIntentPending
    }

    private func logAssessmentFailure(_ error: Error) {
        let detail = LogSanitizer.redact(String(describing: error))
        HLLog.api.warning(
            "InsightsMetric assessment fetch failed for \(kind.rawValue, privacy: .public): \(detail)"
        )
    }

    /// Poll cadence — mirrors the web `STATUS_POLL_MS` (4 s).
    static var assessmentPollInterval: Duration {
        .seconds(4)
    }

    /// Poll ceiling — mirrors the web `STATUS_POLL_MAX_ATTEMPTS` (12 ≈ 48 s).
    static var assessmentPollMaxAttempts: Int {
        12
    }
}
