import SwiftUI

/// One ECG recording in detail (P8, web `EcgSection`'s detail view).
///
/// Shows — in this order — the DEVICE-attributed result, the waveform slot, the
/// metadata grid, the clinician note (only for a non-normal DEVICE verdict) and
/// the permanent disclaimer.
///
/// **Regulatory framing (load-bearing — do NOT soften).** Every value on this
/// screen is the recording device's own output, rendered verbatim. HealthLog
/// does not read the trace, does not measure intervals, does not annotate
/// beats, and produces no verdict of its own.
///
/// **Never dead.** The metadata comes from the list row the operator tapped, so
/// the screen is fully populated the moment it appears. Only the trace needs a
/// round-trip; if that fails the page keeps everything else and says one calm
/// sentence about the missing curve.
struct EcgDetailScreen: View {
    let recording: EcgRecordingDTO

    @Environment(EcgStore.self) private var store

    /// The fetched trace. `nil` while loading, or when the read failed / the
    /// recording is gone.
    @State private var detail: EcgDetailDTO?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        HLPage {
            resultLine
            waveformSlot
            metadataGrid
            if EcgPresentation.showsClinicianNote(for: recording.verdict) {
                clinicianNote
            }
        }
        .navigationTitle(Text("insights.ecg.title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("insights.ecg.detail")
        .task { await loadDetail() }
    }

    // MARK: - Sections

    /// The device's result, explicitly attributed to the device that produced
    /// it. The attribution footer is that statement; the line that
    /// repeated the result "as reported by the recording device" between the
    /// title and the old separate disclaimer card is gone.
    private var resultLine: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                // A card head's weight: the result is the card's subject, not
                // a second page title.
                Text(EcgPresentation.resultLabel(for: recording.verdict))
                    .hlText(.rowTitle)
                EcgAttributionFooter()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("insights.ecg.detail.result")
    }

    /// The trace. A failed / absent read leaves the REST of the page standing
    /// with one calm sentence here — the screen is never dead.
    @ViewBuilder
    private var waveformSlot: some View {
        if let detail, !detail.samples.isEmpty {
            HLCard {
                EcgWaveformView(
                    samples: detail.samples,
                    accessibilityDescription: waveformAccessibilityDescription
                )
            }
            .accessibilityIdentifier("insights.ecg.detail.waveform")
        } else if isLoading {
            HLCard {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 140)
            }
        } else if loadFailed {
            Text("insights.ecg.waveform.loadFailed")
                .hlText(.rowSubtitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("insights.ecg.detail.waveformFailed")
        }
    }

    /// The spoken description of the trace: when it was recorded, how long it
    /// is, the device's average heart rate and — verbatim — the DEVICE's own
    /// result. Mirrors the web's `insights.ecg.waveform.ariaLabel`. Never a
    /// HealthLog reading of the curve.
    private var waveformAccessibilityDescription: String {
        String(
            localized: """
            insights.ecg.waveform.a11y \
            \(HLDateFormat.dateTime(recording.recordedAt)) \
            \(EcgPresentation.durationValue(recording.durationSeconds)) \
            \(EcgPresentation.bpmValue(recording.averageHeartRate)) \
            \(EcgPresentation.resultLabel(for: recording.verdict))
            """
        )
    }

    /// Recorded / duration / lead / average HR / sampling rate — verbatim, with
    /// an honest dash where the device reported nothing.
    private var metadataGrid: some View {
        HLCard {
            HLFactGroup {
                HLFactRow("insights.ecg.meta.recorded", value: HLDateFormat.dateTime(recording.recordedAt))
                HLFactRow("insights.ecg.meta.duration", value: EcgPresentation.durationValue(recording.durationSeconds))
                HLFactRow("insights.ecg.meta.lead", value: EcgPresentation.leadValue(recording.lead))
                HLFactRow("insights.ecg.meta.averageHeartRate", value: EcgPresentation.bpmValue(recording.averageHeartRate))
                HLFactRow("insights.ecg.meta.samplingRate", value: EcgPresentation.hzValue(recording.samplingFrequency))
            }
        }
        .accessibilityIdentifier("insights.ecg.detail.meta")
    }

    /// Shown ONLY for a non-normal DEVICE verdict. It points at a conversation
    /// with a clinician — it is not, and must never read as, an assessment.
    private var clinicianNote: some View {
        HLCard {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "stethoscope")
                    .hlText(.note)
                    .accessibilityHidden(true)
                // The references sit once, with the result above.
                Text("insights.ecg.clinicianNote")
                    .hlText(.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("insights.ecg.detail.clinicianNote")
    }

    // MARK: - Load

    private func loadDetail() async {
        guard detail == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await store.detail(id: recording.id)
            loadFailed = detail == nil
        } catch {
            loadFailed = true
        }
    }
}
