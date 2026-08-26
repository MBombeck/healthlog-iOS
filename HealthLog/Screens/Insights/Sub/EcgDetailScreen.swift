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
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                resultLine
                waveformSlot
                metadataGrid
                if EcgPresentation.showsClinicianNote(for: recording.verdict) {
                    clinicianNote
                }
                EcgDisclaimerBlock()
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxl)
        }
        .background(HLSurface.primary.ignoresSafeArea())
        .navigationTitle(Text("insights.ecg.title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("insights.ecg.detail")
        .task { await loadDetail() }
    }

    // MARK: - Sections

    /// The device's result, explicitly attributed to the device that produced it.
    private var resultLine: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(EcgPresentation.resultLabel(for: recording.verdict))
                    .font(.hlTitle3)
                    .foregroundStyle(HLText.primary)
                Text(EcgPresentation.attribution(for: recording.verdict))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
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
            VStack(spacing: 0) {
                metaRow("insights.ecg.meta.recorded", HLDateFormat.dateTime(recording.recordedAt))
                Divider().overlay(HLColor.separator)
                metaRow("insights.ecg.meta.duration", EcgPresentation.durationValue(recording.durationSeconds))
                Divider().overlay(HLColor.separator)
                metaRow("insights.ecg.meta.lead", EcgPresentation.leadValue(recording.lead))
                Divider().overlay(HLColor.separator)
                metaRow("insights.ecg.meta.averageHeartRate", EcgPresentation.bpmValue(recording.averageHeartRate))
                Divider().overlay(HLColor.separator)
                metaRow("insights.ecg.meta.samplingRate", EcgPresentation.hzValue(recording.samplingFrequency))
            }
        }
        .accessibilityIdentifier("insights.ecg.detail.meta")
    }

    private func metaRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: HLSpace.md) {
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: HLSpace.sm)
            Text(value)
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, HLSpace.sm)
        .accessibilityElement(children: .combine)
    }

    /// Shown ONLY for a non-normal DEVICE verdict. It points at a conversation
    /// with a clinician — it is not, and must never read as, an assessment.
    private var clinicianNote: some View {
        HLCard {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "stethoscope")
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
                    .accessibilityHidden(true)
                Text("insights.ecg.clinicianNote")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
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
