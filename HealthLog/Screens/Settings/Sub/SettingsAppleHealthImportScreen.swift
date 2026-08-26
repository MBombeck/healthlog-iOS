import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// `/settings/integrations/apple-health-import` — the real one-shot
/// "Apple Health Export ZIP" import.
///
/// Flow (v0.12 AHI wave): CTA → `UIDocumentPickerViewController` (UTType `.zip`)
/// → multipart upload to `POST /api/import/apple-health-export` → receive
/// `jobId` → poll `GET .../[jobId]/status` (bounded, calm progress) → stats
/// summary on `done` / clear error on `failed`. The upload + poll are driven by
/// ``AppleHealthImportService`` (actor); this screen owns only UI state.
///
/// **Why this surface matters (per R3 standalone-first user-journey):**
/// existing iPhone users typically carry years of HealthKit data inside the
/// `export.zip` archive the Health.app emits. The foreground HealthKit API only
/// streams forward from "now", which would leave that history behind. Server-side
/// XML parsing does the one-shot bulk import; iOS provides the file-picker +
/// progress display + post-import stats.
///
/// **Server-only:** the entry point in ``SettingsIntegrationsScreen`` is gated on
/// `backend.hasServer`; standalone never reaches this screen. This view is
/// defensive too — if it is ever opened without a container/server it renders a
/// disabled CTA rather than crashing.
///
/// **Visual contract (Theme-2.0):** hero icon paints `HLText.primary` (Tonal-Mono);
/// status pill reflects the live phase; progress is reduce-motion gated.
struct SettingsAppleHealthImportScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// audit v0162 H2 — the upload/poll orchestration (+ the security-scoped
    /// resource handling and terminal mapping) lives in ``ExportStore`` now; this
    /// screen owns only the picker-presentation flag and renders the store's
    /// published ``ExportStore/importPhase``.
    @State private var exportStore: ExportStore?
    @State private var isPickerPresented = false

    /// The live import phase, sourced from the store (idle until a store is
    /// created on first import). Re-typed onto the store's `ImportPhase`.
    private var phase: ExportStore.ImportPhase {
        exportStore?.importPhase ?? .idle
    }

    var body: some View {
        HLSettingsPage(title: "settings.applehealth_import.title") {
            heroCard
            privacyCard
        }
        .navigationTitle("settings.applehealth_import.title")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { exportStore?.cancelImport() }
        #if canImport(UIKit)
            .sheet(isPresented: $isPickerPresented) {
                AppleHealthImportDocumentPicker(
                    onPick: { url in
                        isPickerPresented = false
                        let store = exportStore ?? container?.makeExportStore()
                        exportStore = store
                        store?.startAppleHealthImport(fileURL: url)
                    },
                    onCancel: { isPickerPresented = false }
                )
                .ignoresSafeArea()
            }
        #endif
    }

    // MARK: - Hero card

    private var heroCard: some View {
        HLSettingsCard(
            icon: "tray.and.arrow.down.fill",
            title: "settings.applehealth_import.hero_title",
            // Audit-Gruppe 8 — „Jahre an Historie in einem Import." war die
            // dritte von vier Stufen derselben Ansage (Karten-Untertitel vor
            // dem Absprung → toter Seiten-Untertitel → hier → Explainer).
            // Heimat sind die erste und die letzte: der Untertitel auf der
            // Apple-Health-Seite orientiert vor dem Tippen, der Explainer im
            // Kartenkörper trägt als einziger die Begründung („der reguläre
            // Sync deckt nur den Zeitraum ab jetzt ab").
            trailing: { statusPill },
            content: { heroBody }
        )
    }

    @ViewBuilder
    private var statusPill: some View {
        switch phase {
        case .idle:
            HLStatusPill(.disconnected(label: String(localized: "settings.applehealth_import.pill_ready")))
        case .uploading, .polling:
            HLStatusPill(.unknown(label: String(localized: "settings.applehealth_import.pill_running")))
        case .done:
            HLStatusPill(.connected(label: String(localized: "settings.applehealth_import.pill_done")))
        case .failed:
            HLStatusPill(.error(label: String(localized: "settings.applehealth_import.pill_failed")))
        }
    }

    private var heroBody: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            HStack {
                Spacer()
                Image(systemName: "tray.and.arrow.down")
                    // Cover-scale hero medallion (`HLIconSize.cover`) —
                    // decorative chrome on the canonical glyph scale.
                    .font(.hlIcon(HLIconSize.cover, weight: .light))
                    .foregroundStyle(HLText.primary)
                    .accessibilityHidden(true)
                Spacer()
            }
            .padding(.vertical, HLSpace.sm)

            Text("settings.applehealth_import.explainer")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch phase {
            case .idle, .failed:
                ctaButton
                if case let .failed(reason) = phase {
                    errorRow(reason)
                }
            case .uploading:
                progressBlock(
                    label: String(localized: "settings.applehealth_import.progress_uploading"),
                    percent: nil
                )
            case let .polling(status):
                progressBlock(
                    label: phaseLabel(status.status),
                    percent: status.progress?.percent
                )
            case let .done(status):
                statsSummary(status)
                importAnotherButton
            }
        }
    }

    private var ctaButton: some View {
        HLButton(
            String(localized: "settings.applehealth_import.cta"),
            icon: "tray.and.arrow.down.fill",
            // R9 — „Import ausführen" ist die Commit-Aktion dieses Screens.
            variant: .primary
        ) {
            isPickerPresented = true
        }
        .disabled(container?.api == nil)
        .accessibilityIdentifier("settings.applehealth_import.cta")
    }

    private var importAnotherButton: some View {
        HLButton(
            String(localized: "settings.applehealth_import.import_another"),
            icon: "arrow.clockwise",
            variant: .secondary
        ) {
            exportStore?.resetImport()
        }
        .accessibilityIdentifier("settings.applehealth_import.importAnother")
    }

    // MARK: - Progress

    private func progressBlock(label: String, percent: Int?) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.md) {
                // Reduce-motion gate: spinner only animates when motion is
                // allowed; otherwise a static glyph stands in.
                if reduceMotion {
                    Image(systemName: "hourglass")
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(HLText.secondary)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(label)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
            }
            if let percent {
                ProgressView(value: Double(percent), total: 100)
                    .tint(HLText.primary)
                    .accessibilityLabel(Text("settings.applehealth_import.progress_uploading"))
                    .accessibilityValue(Text(HLNumberFormat.percent(percent)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Stats summary

    private func statsSummary(_ status: AppleHealthImportStatusDTO) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            let totals = status.result?.totals
            summaryRow(
                icon: "checkmark.circle.fill",
                label: String(localized: "settings.applehealth_import.summary_records"),
                value: formattedCount(totals?.recordsRead)
            )
            summaryRow(
                icon: "square.and.arrow.down.fill",
                label: String(localized: "settings.applehealth_import.summary_upserted"),
                value: formattedCount(totals?.rowsUpserted)
            )

            if let ecg = status.result?.ecg {
                ecgSummary(ecg)
            }

            if let perType = status.result?.perType, !perType.isEmpty {
                Text("settings.applehealth_import.summary_by_type")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                ForEach(perType.sorted(by: { $0.key < $1.key }), id: \.key) { key, stats in
                    summaryRow(
                        icon: "circle.fill",
                        label: key,
                        value: formattedCount(stats.inserted.map { $0 + (stats.updated ?? 0) })
                    )
                }
            }
        }
    }

    // MARK: - ECG summary (server v1.34.1 — `result.ecg`)

    /// What the archive import did with the ECG strips in the `export.zip`.
    ///
    /// This block is the only feedback loop the ECG surface has: the archive
    /// import is currently the ONLY way an ECG reaches HealthLog (no JSON ingest
    /// route, no HealthKit live-sync — see ``AppleHealthImportEcgStatsDTO``), so
    /// after an upload this is where someone finds out whether any recordings
    /// were in there and what happened to them.
    ///
    /// **Counters only — no verdict.** Nothing here interprets a recording; the
    /// device's own classification lives on the ECG surface and nowhere else.
    /// Zero discovered is a calm statement of fact, not an error.
    private func ecgSummary(_ ecg: AppleHealthImportEcgStatsDTO) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text("settings.applehealth_import.ecg_heading")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)

            if (ecg.discovered ?? 0) == 0 {
                Text("settings.applehealth_import.ecg_none")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                summaryRow(
                    icon: "waveform.path.ecg",
                    label: String(localized: "settings.applehealth_import.ecg_discovered"),
                    value: formattedCount(ecg.discovered)
                )
                summaryRow(
                    icon: "square.and.arrow.down.fill",
                    label: String(localized: "settings.applehealth_import.ecg_imported"),
                    value: formattedCount(ecg.imported)
                )
                summaryRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: String(localized: "settings.applehealth_import.ecg_updated"),
                    value: formattedCount(ecg.updated)
                )
                summaryRow(
                    icon: "minus.circle",
                    label: String(localized: "settings.applehealth_import.ecg_skipped"),
                    value: formattedCount(ecg.skipped)
                )
            }

            // Failures are stated whenever they happened — including on an
            // otherwise empty discovery, where a non-zero count is the only
            // honest explanation for the missing recordings.
            if (ecg.failed ?? 0) > 0 {
                summaryRow(
                    icon: "exclamationmark.triangle.fill",
                    label: String(localized: "settings.applehealth_import.ecg_failed"),
                    value: formattedCount(ecg.failed)
                )
            }
        }
        .accessibilityIdentifier("settings.applehealth_import.ecgSummary")
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.secondary)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer()
            Text(value)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
        }
    }

    private func errorRow(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.secondary)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            Text(reason)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Privacy card

    private var privacyCard: some View {
        HLSettingsCard(
            icon: "lock.shield",
            title: "settings.applehealth_import.privacy_title",
            footer: "settings.applehealth_import.privacy_footer"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                privacyRow(icon: "arrow.up.doc.fill", text: "settings.applehealth_import.privacy_upload")
                privacyRow(icon: "doc.text.magnifyingglass", text: "settings.applehealth_import.privacy_parse")
                privacyRow(icon: "chart.bar.fill", text: "settings.applehealth_import.privacy_stats")
                privacyRow(icon: "trash.fill", text: "settings.applehealth_import.privacy_delete")
            }
        }
    }

    private func privacyRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.secondary)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func phaseLabel(_ phase: AppleHealthImportPhase) -> String {
        switch phase {
        case .queued: String(localized: "settings.applehealth_import.phase_queued")
        case .unpacking: String(localized: "settings.applehealth_import.phase_unpacking")
        case .parsing: String(localized: "settings.applehealth_import.phase_parsing")
        case .upserting: String(localized: "settings.applehealth_import.phase_upserting")
        case .done, .failed, .other: String(localized: "settings.applehealth_import.phase_queued")
        }
    }

    private func formattedCount(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }
}

#Preview("SettingsAppleHealthImportScreen") {
    NavigationStack {
        SettingsAppleHealthImportScreen()
    }
}
