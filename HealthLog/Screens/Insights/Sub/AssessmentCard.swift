import SwiftUI

/// v0.11 W22-W2 — the **Einschätzung / Assessment** block of the web-mirror
/// per-metric Insights page (`InsightsMetricScreen`). The iOS twin of the web
/// `<InsightStatusCard>` (`src/components/insights/insight-status-card.tsx`),
/// fed by the same server-generated `/api/insights/{metric}-status` envelope
/// that `ChartDetailStore.findings` already loads (`MetricStatusDTO`).
///
/// **ADAPTIVE (doctrine §6 — "nicht alles muss überall sein"):** every arm is a
/// real state, and the *absent* state renders **nothing** — a metric the server
/// has no assessment endpoint for (the ~30 long-tail kinds, exactly like web)
/// shows no empty block. Self-suppression matrix:
/// - **standalone / backend-down** → one calm `HLCloudDerivedPlaceholder` (the
///   assessment is server-only and has no on-device source of truth — it must
///   not spin forever offline, R4 §3.2). NOT suppressed-to-nothing: the operator
///   should understand *why* the block is quiet (connect a server).
/// - **loading / preparing** → a skeleton, never a bare spinner.
/// - **consent-closed** → a compact "enable assistant insight" CTA (mirrors the
///   `ChartDetailScreen` findings consent gate; the assessment is LLM prose so it
///   stays behind the same consent contract).
/// - **no provider** → the server's localized "assistant disabled" hint.
/// - **ready** → the assessment prose with cached / updated-at provenance.
/// - **empty / no endpoint for this kind** → renders nothing (self-suppress).
///
/// **Monochrome / glass:** sits inside the existing `HLCard` rhythm, no glass on
/// content, colour stays signal-only.
struct AssessmentCard: View {
    /// The server assessment envelope. `nil` = no endpoint for this kind, the
    /// endpoint 404'd, OR consent is closed (then `consentClosed` is true).
    let assessment: MetricStatusDTO?
    /// True while the first `/api/insights/{metric}-status` fetch is in flight
    /// and no cached prose has painted yet — drives the skeleton (not a spinner).
    let isLoading: Bool
    /// QoS-3 (A360-4) — true when the warm-poll exhausted its bounded window or
    /// stopped on a transient error while the assessment was still `preparing`,
    /// and no ready prose ever landed. Flips the indefinite "preparing" skeleton
    /// to a terminal "couldn't load — pull to refresh" caption so the user isn't
    /// stuck on a skeleton with no recovery signal. Ignored once ready text
    /// exists (a stale-good assessment wins over a failed revalidation).
    var failed: Bool = false
    /// True when the AI-consent gate is closed: distinguishes "user hasn't
    /// consented" (CTA) from "server returned no assessment" (silent).
    let consentClosed: Bool
    /// True iff this install is paired with a server. When `false` the
    /// assessment — server-only — yields the cloud-derived placeholder instead
    /// of a dead/spinning block (standalone calm-state).
    let hasServer: Bool
    /// Fired by the consent CTA — re-presents the AI consent sheet.
    let onRequestConsent: () -> Void
    /// Fired by the placeholder's "Server verbinden" CTA. `nil` hides the CTA
    /// (preview / no `AuthStore` in scope).
    var onConnectServer: (() -> Void)?

    var body: some View {
        switch state {
        case .suppressed:
            // ADAPTIVE: no assessment + nothing to prompt → render nothing.
            EmptyView()
        case .standalone:
            section {
                HLCloudDerivedPlaceholder(
                    variant: .inline,
                    surfaceName: String(localized: "insights.metric.assessment.title"),
                    onConnect: onConnectServer
                )
            }
        case .loading:
            section {
                AssessmentSkeleton()
            }
        case .failed:
            // QoS-3 — terminal caption: the warm-poll gave up while preparing.
            // Pull-to-refresh (added on the host screen in A360-4) re-drives it.
            section {
                Text("Couldn't load the assessment. Pull down to refresh.")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("insights.metric.assessment.failed")
            }
        case .consentRequired:
            section {
                consentCard
            }
        case let .noProvider(text):
            // #64 — inline (no card) to match the editorial assessment treatment:
            // the server's "assistant disabled" hint flows as calm body prose
            // under the section header, not a boxed slab.
            section {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    if let text, !text.isEmpty {
                        HLInsightProse(text: text)
                    } else {
                        Text("insights.metric.assessment.noProvider.title")
                            .font(.hlBody)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .ready(text, cached, updatedAt):
            section {
                AssessmentBody(text: text, cached: cached, updatedAt: updatedAt)
            }
        }
    }

    // MARK: - Section frame

    /// The web `Einschätzung` block header + content. The header self-suppresses
    /// with the content (it only renders inside a non-`.suppressed` arm).
    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // I-0 Item 1 — `flush: true` drops the header's `HLSpace.xs` inset so
            // the "Einschätzung" heading shares the left edge of the unpadded
            // `AssessmentBody` prose below it (the prose carries no matching
            // inset). The overview sections keep the default inset.
            InsightsSectionHeader("insights.metric.assessment.title", flush: true)
            content()
        }
    }

    // MARK: - Consent CTA

    private var consentCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(HLText.secondary)
                    Text("insights.metric.assessment.consentCTA.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                }
                Text(
                    "Your assistant provider only analyzes the values after your consent. Excerpts of this measurement series are then transmitted to the provider."
                )
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HLButton("Show insights", variant: .primary) {
                    onRequestConsent()
                }
                .accessibilityIdentifier("insights.metric.assessment.consentCTA")
            }
        }
    }

    // MARK: - State resolution

    private var state: State {
        Self.resolveState(
            assessment: assessment,
            isLoading: isLoading,
            failed: failed,
            consentClosed: consentClosed,
            hasServer: hasServer
        )
    }
}

// MARK: - Pure, testable state machine

/// The arm `AssessmentCard` renders. Internal + `Equatable` so the resolution
/// can be unit-tested without hosting the SwiftUI view (A360-4 QoS-3).
enum AssessmentCardState: Equatable {
    case suppressed
    case standalone
    case loading
    case failed
    case consentRequired
    case noProvider(text: String?)
    case ready(text: String, cached: Bool, updatedAt: Date?)
}

extension AssessmentCard {
    typealias State = AssessmentCardState

    /// Pure resolution of the card's arm from the inputs. Extracted from the
    /// `body` so the QoS-3 `failed`/`loading` precedence and the Task #50
    /// ready/insufficient/preparing matrix are unit-testable. `nonisolated` —
    /// the decision is pure (no view state), so it needn't hop to the main actor.
    nonisolated static func resolveState(
        assessment: MetricStatusDTO?,
        isLoading: Bool,
        failed: Bool,
        consentClosed: Bool,
        hasServer: Bool
    ) -> AssessmentCardState {
        // Server-only surface: no server → calm placeholder, never a spinner.
        if !hasServer {
            return .standalone
        }
        // Consent-closed wins over stale prose — never paint an assessment for a
        // user who has not consented in the current session.
        if consentClosed {
            return .consentRequired
        }
        if let assessment {
            if !assessment.hasProvider {
                return .noProvider(text: assessment.text)
            }
            // Task #50 — ready prose wins (the server may serve last-good text
            // with `revalidating:true`; paint it immediately, the screen keeps
            // polling for the upgrade).
            if assessment.hasReadyText, let text = assessment.text {
                return .ready(text: text, cached: assessment.cached, updatedAt: assessment.updatedAt)
            }
            // Task #50 — the metric has no readings: the server skipped the
            // provider (`insufficient:true`). Calm-suppress — a sparse metric
            // reads as a clean heading + chart, never a spinner-forever box.
            if assessment.insufficient {
                return .suppressed
            }
            // Task #50 — the server is warming the assessment out of band
            // (`preparing`/`revalidating`, no ready text yet). Mirror the web's
            // preparing skeleton; the screen polls until ready text lands.
            if assessment.isPreparing {
                // QoS-3 — the poll gave up while still preparing → terminal
                // caption instead of an indefinite skeleton.
                return failed ? .failed : .loading
            }
            // Provider present but server returned empty prose, terminal → suppress.
            return .suppressed
        }
        // No envelope yet: skeleton while preparing, the QoS-3 terminal caption
        // when a fetch failed before any envelope landed, else nothing to show.
        if isLoading { return .loading }
        return failed ? .failed : .suppressed
    }
}

// MARK: - Assessment prose body

/// #64 (v0.12 W5a, OPERATOR-REFINEMENTS #5) — the ready assessment now renders
/// as **inline flowing text**, NOT a boxed `HLCard`. The operator asked for the
/// Einschätzung to read like the descriptive paragraph that sits under Puls —
/// "das gibt dem Ganzen mehr Ruhe und mehr Rahmen": calmer, more editorial, less
/// boxed (Oura's editorial model / Apple Health Highlights / the 2026-ADA winner
/// Harvee's flowing-prose precedent in `RESEARCH-competitive-ios26.md`).
///
/// **What changed:** the surrounding `HLCard` chrome is gone — the prose flows
/// directly in the screen column (the section frame supplies the "Einschätzung"
/// header above). **What is KEPT (#50 contract):** the provenance line
/// ("KI-Einschätzung · vor X" + cached glyph), the verbatim-model disclaimer,
/// and — upstream — the `remoteAIEnabled` gate + preparing→ready polling (those
/// live in `InsightsMetricScreen`/the state machine, untouched here). Only the
/// PRESENTATION is card→inline.
private struct AssessmentBody: View {
    let text: String
    let cached: Bool
    let updatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            // v0.14.1 §5/§7 — the Einschätzung prose now reads in the SAME grey
            // flowing style as the intro `descriptionSlot` (`HLText.secondary`),
            // not near-black `HLText.primary`. The operator wants Einschätzung +
            // Zusammenhänge to match the calm grey intro text on EVERY metric —
            // one flowing voice, never a louder white block.
            // v0162 readability — render as flowing prose (inline Markdown +
            // preserved paragraph breaks + line spacing) instead of a dense
            // plain-`Text` block. See `HLInsightProse`.
            HLInsightProse(text: text)

            // Provenance line — one calm caption beneath the prose. The operator
            // did not recognise the old card as a server-generated AI assessment
            // ("wo kommt das her, keine Ahnung"); we keep the plain attribution
            // inline: "KI-Einschätzung · vor X", mirroring the briefing hero's
            // `generatedPrefix`. The relative-time + cached glyph self-suppress
            // when absent.
            HStack(spacing: HLSpace.xxs) {
                Text(String(localized: "insights.metric.assessment.aiLabel"))
                if cached {
                    Text(verbatim: "·")
                    Image(systemName: "tray.and.arrow.down")
                        .accessibilityLabel(Text(String(localized: "Cached")))
                }
                if let updatedAt {
                    Text(verbatim: "·")
                    Text(String(localized: "insights.briefingHero.generatedPrefix"))
                    Text(updatedAt, format: .relative(presentation: .named))
                }
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("insights.metric.assessment.generated")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "AI finding: \(text)")))
    }
}

// MARK: - Loading skeleton

/// A calm placeholder while the assessment prepares — three shimmer-free
/// lines on the recessed well, reduce-motion-safe (no animation at all). Beats
/// a bare spinner: the operator sees the shape the prose will fill.
private struct AssessmentSkeleton: View {
    var body: some View {
        // #64 — inline (no card) so the preparing state previews the SAME
        // flowing-prose shape the ready assessment fills, not a boxed slab.
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            ForEach(0 ..< 3, id: \.self) { index in
                RoundedRectangle(cornerRadius: HLRadius.xs, style: .continuous)
                    .fill(HLSurface.tertiary)
                    .frame(height: 12)
                    .frame(maxWidth: index == 2 ? 180 : .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text(String(localized: "Preparing the assistant's explanation")))
    }
}
