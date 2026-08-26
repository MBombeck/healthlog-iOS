import SwiftUI

/// W5-2 (v0.12 W5b) — the **Device health notifications** card on the Insights
/// overview, the iOS twin of the web `RhythmEventsCard`
/// (`src/components/insights/rhythm-events-card.tsx`).
///
/// **What it renders.** A timeline of the on-device notifications the user's
/// wearable (Apple Watch / Withings ScanWatch) already produced + synced —
/// irregular-rhythm / high-HR / low-HR / walking-steadiness /
/// breathing-disturbance — each with the DEVICE's own verdict surfaced
/// verbatim ("Your device flagged …"), plus a permanent, non-dismissible
/// regulatory disclaimer.
///
/// **Regulatory framing (LOAD-BEARING — do NOT soften).** This is AWARENESS /
/// SCREENING of the DEVICE's own certified decision, never a HealthLog
/// diagnosis. iOS shows ONLY the classification RESULT; it never re-classifies,
/// never implies HealthLog produced the assessment, never shows a waveform. The
/// disclaimer copy is lifted VERBATIM from the server/web copy contract
/// (`ios-coord/v1.10.0-server-to-ios-ingestion.md §2`, web catalog
/// `insights.rhythmEvents.disclaimer`) and is a permanent part of the surface —
/// no dismiss affordance.
///
/// **Self-suppression.** When there are no events the whole card renders
/// NOTHING (`EmptyView`) — never an empty / alarming shell. The data gate lives
/// in `RhythmEventsStore.events` (empty on `hasEvents:false` / 404 / 422 /
/// error). The call site additionally hides the card in standalone / no-server
/// (this is a pure server read).
///
/// **Monochrome + no glass.** Content card = `HLCard` over `HLSurface.secondary`,
/// `HLText.*` only; color carries no signal here. Reduce-motion-gated entrance.
struct InsightsRhythmEventsCard: View {
    /// The device-event rows (newest first). Empty → the card self-suppresses.
    let events: [RhythmEventsDTO.Event]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Self-suppress: no events → nothing. Calm doctrine, web parity
        // (`if (!data.hasEvents) return null`).
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader(
                    "Device health notifications",
                    subtitle: "Notifications your watch sent on its own. HealthLog only shows these — it does not detect, confirm, or interpret them."
                )
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        ForEach(events) { event in
                            row(for: event)
                            if event.id != events.last?.id {
                                Divider().overlay(HLText.tertiary.opacity(0.3))
                            }
                        }
                        disclaimer
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.rhythmEvents")
        }
    }

    // MARK: - Event row

    @ViewBuilder
    private func row(for event: RhythmEventsDTO.Event) -> some View {
        let label = Self.eventLabel(for: event.type)
        let verdict = Self.verdictLabel(for: event.classification)
        // The ingest source attributed to the DEVICE that produced the alert
        // (Apple Watch via Apple Health, Withings ScanWatch, …). The server
        // emits the SAME irregular-rhythm event type regardless of source, so
        // attribution is the only honest signal of WHICH device decided — a
        // Withings-sourced AFib/ECG event must read "Withings", never blank.
        let sourceLabel = Self.sourceLabel(for: event.source, deviceType: event.deviceType)
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: Self.symbol(for: event.type))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(label)
                    .font(.hlBody.weight(.medium))
                    .foregroundStyle(HLText.primary)
                if let verdict {
                    // The device's verdict, verbatim. Framed as the device's
                    // decision ("Your device flagged …"), never HealthLog's.
                    Text(verdict)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier("insights.rhythmEvents.verdict")
                }
                HStack(spacing: HLSpace.xs) {
                    Text(event.occurredAt, format: .dateTime.day().month().year().hour().minute())
                    if let sourceLabel {
                        // Honest device attribution — "· Withings" / "· Apple
                        // Watch". Tertiary, caption-weight: it qualifies the
                        // event without competing with the verdict.
                        Text(verbatim: "·")
                        Text(sourceLabel)
                            .accessibilityIdentifier("insights.rhythmEvents.source")
                    }
                }
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(label: label, verdict: verdict, source: sourceLabel))
    }

    /// Composes the row's combined VoiceOver label so the device attribution is
    /// spoken too ("… Recorded by Withings.").
    nonisolated static func accessibilityLabel(label: String, verdict: String?, source: String?) -> String {
        var parts = [label]
        if let verdict { parts.append(verdict) }
        if let source { parts.append(String(localized: "Recorded by \(source)")) }
        return parts.joined(separator: ". ")
    }

    // MARK: - Disclaimer (permanent, non-dismissible)

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "info.circle")
                .font(.hlFootnote)
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            // VERBATIM copy contract — `insights.rhythmEvents.disclaimer`.
            Text(
                // swiftlint:disable:next line_length
                "These are alerts your device produced using its own built-in detection. They are shown here for your awareness only. This is not a medical assessment by HealthLog, and HealthLog does not diagnose any condition. If a notification concerns you, talk to your doctor."
            )
            .font(.hlFootnote)
            .foregroundStyle(HLText.secondary)
        }
        .padding(HLSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HLSurface.tertiary, in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.rhythmEvents.disclaimer")
    }

    // MARK: - Type → label / verdict / symbol (web parity)

    /// `nonisolated static` so the resolvers are unit-testable off the main
    /// actor. Localized strings resolve through the catalog (EN source + DE).
    nonisolated static func eventLabel(for type: String) -> String {
        switch type {
        case "IRREGULAR_RHYTHM_NOTIFICATION": String(localized: "Irregular rhythm notification")
        case "HIGH_HEART_RATE_EVENT": String(localized: "High heart rate notification")
        case "LOW_HEART_RATE_EVENT": String(localized: "Low heart rate notification")
        case "WALKING_STEADINESS_EVENT": String(localized: "Walking steadiness alert")
        case "BREATHING_DISTURBANCE_EVENT": String(localized: "Breathing disturbance during sleep")
        default: type
        }
    }

    /// The device's verdict for a classification code, or `nil` when the row
    /// carried no classification. Verbatim from the copy contract.
    nonisolated static func verdictLabel(for classification: String?) -> String? {
        guard let classification else { return nil }
        switch classification {
        case "IRREGULAR": return String(localized: "Your device flagged a possible irregular rhythm.")
        case "NOT_DETECTED": return String(localized: "Your device did not flag an irregular rhythm.")
        case "INCONCLUSIVE": return String(localized: "Your device could not make a reading.")
        case "LOW": return String(localized: "Your device flagged low walking steadiness.")
        case "VERY_LOW": return String(localized: "Your device flagged very low walking steadiness.")
        case "FIRED": return String(localized: "Your device flagged this event.")
        default: return nil
        }
    }

    /// Honest device attribution for an event row, or `nil` when neither a
    /// device model nor a recognised ingest source is present (then the row
    /// carries no source qualifier rather than a blank "·").
    ///
    /// A concrete `deviceType` wins (it names the actual wearable, e.g.
    /// "Apple Watch" / "ScanWatch") since the device IS the producer of the
    /// verdict; otherwise the ingest `source` token resolves through the
    /// canonical `SourcePriorityRow.displayLabel(forSource:)` so "WITHINGS"
    /// reads "Withings" and "APPLE_HEALTH" reads "Apple Health" — the SAME
    /// labels the measurements/source-priority surfaces use. The raw `MANUAL`
    /// / `IMPORT` synthetic sources are suppressed: a device-flagged cardiac
    /// event never originates from a manual entry, so attributing one would be
    /// misleading.
    nonisolated static func sourceLabel(for source: String?, deviceType: String?) -> String? {
        if let deviceType, !deviceType.isEmpty { return deviceType }
        guard let source, !source.isEmpty else { return nil }
        switch source.uppercased() {
        case "MANUAL", "IMPORT": return nil
        default: return SourcePriorityRow.displayLabel(forSource: source)
        }
    }

    /// SF Symbol per event type (mono glyph; mirrors the web lucide mapping).
    nonisolated static func symbol(for type: String) -> String {
        switch type {
        case "IRREGULAR_RHYTHM_NOTIFICATION": "waveform.path.ecg"
        case "HIGH_HEART_RATE_EVENT", "LOW_HEART_RATE_EVENT": "heart.fill"
        case "WALKING_STEADINESS_EVENT": "figure.walk"
        case "BREATHING_DISTURBANCE_EVENT": "wind"
        default: "waveform.path.ecg"
        }
    }
}
