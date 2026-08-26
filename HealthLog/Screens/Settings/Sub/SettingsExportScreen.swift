import SwiftUI

/// `/settings/export` — Export (generic backup + per-domain CSV).
///
/// **v0.14.7 C1/C2 split:** this screen was the single "everything export" hub —
/// it carried BOTH generic data-portability (full JSON/CSV backup, per-domain
/// CSV) AND every doctor-handover surface (clinician share-link, health-record
/// ZIP, PDF doctor report, FHIR bundle). The operator walkthrough split the two
/// mental models:
///   - **Generic backup / measurements export → Einstellungen** (this screen,
///     back on the Settings hub `export` row — C1 reverts the v0.14.1 FB9 move
///     to "Mehr").
///   - **Doctor-handover surfaces → Mehr → "Mit dem Arzt teilen"**
///     (`UnifiedSharingScreen` since 18-03) — a fast "share X with my doctor" path at
///     the appointment.
///
/// So this screen now ships only the generic exports:
///   1. Full backup (JSON / CSV) — the weekly-auto-backup shape.
///   2. Per-domain CSV — Measurements / Mood / Medications (v0.11 W9).
///
/// **SET-V2-A (B.1 + C-2):** the full backup used to live one push deeper on a
/// dedicated `ExportScreen` — a structural double-hop (the hub subtitle
/// promised "Full backup, CSV per area" but delivered only after an extra
/// push). The former screen's body (format picker, `/api/export` download,
/// share) is now inlined as `FullBackupExportCard` below and the screen was
/// deleted; everything export lives on this ONE page.
///
/// The per-domain CSVs are *server-rendered* (canonical column order, locale,
/// audit columns). They have no byte-exact on-device twin, so each card gates on
/// `BackendAvailability.hasServer`: paired → live download + share; standalone →
/// the calm `HLCloudDerivedPlaceholder` (consistent with every other
/// server-derived surface — never a dead button). The full on-device backup
/// remains the offline data-portability path.
struct SettingsExportScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore

    var body: some View {
        HLSettingsPage(title: "Export") {
            // W-B187 (Settings consolidation §A / B.1) — labelled entry into the
            // doctor-handover surface (`UnifiedSharingScreen`: PDF report · FHIR ·
            // clinician share-link · health-record ZIP). The hub was previously
            // reachable ONLY via a bare share glyph in the More-tab header — a
            // high-value clinician surface hidden behind an unlabelled icon. This
            // card gives it a discoverable, labelled home on the Export screen
            // (the natural mental neighbour of "get my data out for someone").
            shareWithDoctorCard
            FullBackupExportCard()
            // 7.9 web-parity — passphrase-encrypted backup (`POST
            // /api/export/encrypted`, HLX1 archive). Server-only surface: paired
            // → live; standalone has no server to encrypt against.
            if backend.hasServer {
                EncryptedBackupExportCard()
            }
            ImportDataCard()
            domainExportSection
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// W-B187 — labelled card pushing the doctor-handover hub. Mirrors the
    /// row chrome used across the Settings sub-screens (icon · title · subtitle ·
    /// "Open …" disclosure row) so it reads as a peer of the export cards below.
    private var shareWithDoctorCard: some View {
        HLSettingsCard(
            icon: "stethoscope",
            title: "settings.export.share_with_doctor.title",
            subtitle: "settings.export.share_with_doctor.subtitle"
        ) {
            // UI-Standard R8/R10 (U6) — handgebaute Chevron-Zeile → Primitive;
            // das Chevron gehört dem `presents:`-Vertrag, nicht dem Aufrufer.
            HLSettingsActionRow(
                title: "settings.export.share_with_doctor.nav_row",
                presents: .push
            ) {
                UnifiedSharingScreen()
            }
            .accessibilityIdentifier("settings.export.shareWithDoctorRow")
        }
    }

    /// v0.11 W9 — restored per-domain CSV exports (dropped under the AC18
    /// placeholder). One card per domain; each downloads the server's canonical
    /// CSV and offers it via `ShareLink`. Adaptive: paired → live; standalone →
    /// `HLCloudDerivedPlaceholder` (server-only surface, no dead button).
    /// UI-Standard R2 (U6, Audit-Gruppe G9) — die drei Untertitel sagten
    /// dreimal, dass eine CSV eine Tabelle ist; jede Karte heißt bereits
    /// „… (CSV)". Ersatzlos gestrichen.
    @ViewBuilder
    private var domainExportSection: some View {
        if backend.hasServer {
            DomainCSVExportCard(
                domain: .measurements,
                icon: "waveform.path.ecg",
                title: "Measurements (CSV)"
            )
            DomainCSVExportCard(
                domain: .mood,
                icon: "face.smiling",
                title: "Mood (CSV)"
            )
            DomainCSVExportCard(
                domain: .medications,
                icon: "pills",
                title: "Medications (CSV)"
            )
        } else {
            HLCloudDerivedPlaceholder(
                variant: .inline,
                surfaceName: String(localized: "the per-area CSV exports"),
                onConnect: { authStore.beginServerPairing() }
            )
        }
    }
}

/// The full JSON/CSV backup — the former `ExportScreen` body inlined as a card
/// (SET-V2-A / B.1). Behaviour is carried over 1:1: `POST /api/export` with the
/// picked format, persist into the temp directory under
/// `.completeFileProtection`, then offer the file via `ShareLink`. The share
/// row + error surfacing mirror `DomainCSVExportCard` below so the whole page
/// speaks exactly one interaction language (Quality Doctrine §6).
private struct FullBackupExportCard: View {
    @Environment(\.appContainer) private var container

    @State private var format: ExportFormat = .json
    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    enum ExportFormat: String, CaseIterable, Identifiable {
        case json
        case csv
        var id: String {
            rawValue
        }

        var label: String {
            rawValue.uppercased()
        }

        /// Bridge to the service-owned format (AUD-7 H3).
        var serviceFormat: ExportService.BackupFormat {
            switch self {
            case .json: .json
            case .csv: .csv
            }
        }
    }

    var body: some View {
        HLSettingsCard(
            icon: "square.and.arrow.up.on.square.fill",
            title: "Full backup (JSON / CSV)",
            subtitle: "A single file containing all your data — same format as the weekly auto-backup."
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // R19 / privacy-review (U6, Audit-Gruppe G8) — der erste Satz
                // war der Karten-Subtitle in anderen Worten („eine einzige
                // Datei mit allen Daten"). Was bleibt, ist die rechtsrelevante
                // Hälfte: die Auskunft, welches Betroffenenrecht dieser Export
                // bedient. Die Zusage selbst ist unverändert.
                Text("GDPR Art. 20 — data portability.")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                // B3 (W-BUTTONS): the full-backup "Export erstellen" was a
                // `.large` full-fill CTA the operator called "creepy" / far too
                // UI-Standard R9 (U6) — `.restrained` ist gefallen. Voll-Backup
                // und verschlüsseltes Backup sind zwei gleichrangige
                // Karten-Aktionen auf einem Screen; „höchstens ein `.primary`
                // pro Screen" heißt hier: beide `.secondary`.
                HLButton(
                    String(localized: "export.create.button"),
                    icon: "square.and.arrow.down",
                    variant: .secondary,
                    isLoading: isWorking
                ) {
                    Task { await runExport() }
                }
                .accessibilityIdentifier("export.create.button")

                if let exportURL {
                    ShareLink(item: exportURL) {
                        HStack(spacing: HLSpace.md) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(HLColor.statusOK)
                            Text("Share file")
                                .font(.hlSubhead.weight(.semibold))
                                .foregroundStyle(HLText.primary)
                            Spacer()
                            // Trailing affordance glyph — fixed via HLIconSize.sm.
                            Image(systemName: "square.and.arrow.up")
                                .font(.hlIcon(HLIconSize.sm))
                                .foregroundStyle(HLText.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.export.full.share")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runExport() async {
        // AUD-7 H3 / audit v0162 H2 — the `/api/export` service call + the
        // complete-file-protection persist are owned by `ExportStore` now (the
        // former in-view `ExportService` construction + file write were the last
        // in-view layering seam). The card keeps only its inline UI state.
        guard let store = container?.makeExportStore() else { return }
        isWorking = true
        errorMessage = nil
        exportURL = nil
        defer { isWorking = false }
        do {
            exportURL = try await store.downloadFullBackup(format.serviceFormat)
        } catch let error as HLError {
            errorMessage = error.userFacingDescription
        } catch {
            errorMessage = String(localized: "Couldn't export. Please try again.")
        }
    }
}

/// 7.9 web-parity — the passphrase-encrypted backup. `POST /api/export/encrypted`
/// returns the same payload as the plaintext full backup, sealed into an `HLX1`
/// archive (Argon2id + AES-256-GCM) under a passphrase the user types here. The
/// passphrase never reaches disk or a log; there is **no server-side recovery**,
/// so the card says so before the user commits. Same download → persist → share
/// lifecycle as the plaintext cards.
private struct EncryptedBackupExportCard: View {
    @Environment(\.appContainer) private var container

    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    /// Minimum passphrase length the UI enforces before enabling export — the
    /// server bounds the upper end; this is a floor so a one-character archive
    /// key never ships.
    private static let minLength = 8

    private var passphrasesMatch: Bool {
        !passphrase.isEmpty && passphrase == confirmPassphrase
    }

    private var canExport: Bool {
        passphrase.count >= Self.minLength && passphrasesMatch && !isWorking
    }

    var body: some View {
        HLSettingsCard(
            icon: "lock.doc.fill",
            title: "export.encrypted.title",
            subtitle: "export.encrypted.subtitle",
            footer: "export.encrypted.footer"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                SecureField(String(localized: "export.encrypted.passphrase.placeholder"), text: $passphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("export.encrypted.passphrase")

                SecureField(String(localized: "export.encrypted.confirm.placeholder"), text: $confirmPassphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("export.encrypted.confirm")

                if !confirmPassphrase.isEmpty, !passphrasesMatch {
                    Text("export.encrypted.mismatch")
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusBad)
                }

                HLButton(
                    String(localized: "export.encrypted.button"),
                    icon: "lock.fill",
                    variant: .secondary,
                    isLoading: isWorking
                ) {
                    Task { await runExport() }
                }
                .disabled(!canExport)
                .accessibilityIdentifier("export.encrypted.button")

                if let exportURL {
                    ShareLink(item: exportURL) {
                        HStack(spacing: HLSpace.md) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(HLColor.statusOK)
                            Text("Share file")
                                .font(.hlSubhead.weight(.semibold))
                                .foregroundStyle(HLText.primary)
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .font(.hlIcon(HLIconSize.sm))
                                .foregroundStyle(HLText.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("export.encrypted.share")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runExport() async {
        guard let store = container?.makeExportStore() else { return }
        isWorking = true
        errorMessage = nil
        exportURL = nil
        defer { isWorking = false }
        do {
            exportURL = try await store.downloadEncryptedBackup(passphrase: passphrase)
            // The passphrase has served its purpose — drop it from memory once the
            // archive is minted (it is unrecoverable server-side anyway).
            passphrase = ""
            confirmPassphrase = ""
        } catch let error as HLError {
            errorMessage = error.userFacingDescription
        } catch {
            errorMessage = String(localized: "Couldn't export. Please try again.")
        }
    }
}

/// 7.9 web-parity — labelled nav row into the data-import surface (JSON / CSV
/// restore with a dry-run preview). Kept a peer of the export cards: "get my
/// data out" and "bring my data in" are the two halves of data portability.
private struct ImportDataCard: View {
    var body: some View {
        HLSettingsCard(
            icon: "square.and.arrow.down.on.square",
            title: "import.card.title",
            subtitle: "import.card.subtitle"
        ) {
            HLSettingsActionRow(title: "import.card.nav_row", presents: .push) {
                ImportDataScreen()
            }
            .accessibilityIdentifier("settings.export.importRow")
        }
    }
}

/// One per-domain CSV export card. Encapsulates the download → persist → share
/// lifecycle plus error/rate-limit surfacing, so the three domains share exactly
/// one interaction language (Quality Doctrine §6: uniform, no bespoke per-card
/// behaviour). Glass discipline: pure `HLSettingsCard` content — no glass.
private struct DomainCSVExportCard: View {
    let domain: ExportService.Domain
    let icon: String
    let title: LocalizedStringKey

    @Environment(\.appContainer) private var container

    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        HLSettingsCard(icon: icon, title: title) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Button {
                    Task { await run() }
                } label: {
                    HStack(spacing: HLSpace.md) {
                        Text(isWorking ? "Preparing…" : "Download CSV")
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(isWorking ? HLText.tertiary : HLText.primary)
                        Spacer()
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            // Trailing affordance glyph — fixed via HLIconSize.sm.
                            Image(systemName: "square.and.arrow.down")
                                .font(.hlIcon(HLIconSize.sm))
                                .foregroundStyle(HLText.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityIdentifier("settings.export.csv.\(domain.rawValue)")

                if let exportURL {
                    ShareLink(item: exportURL) {
                        HStack(spacing: HLSpace.md) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(HLColor.statusOK)
                            Text("Share file")
                                .font(.hlSubhead.weight(.semibold))
                                .foregroundStyle(HLText.primary)
                            Spacer()
                            // Trailing affordance glyph — fixed via HLIconSize.sm.
                            Image(systemName: "square.and.arrow.up")
                                .font(.hlIcon(HLIconSize.sm))
                                .foregroundStyle(HLText.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.export.csv.\(domain.rawValue).share")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func run() async {
        // audit v0162 H2 — the per-domain CSV service call + the complete-file-
        // protection persist (server filename matches the `DoctorReportTmpSweeper`
        // owned-prefix list) are owned by `ExportStore`. The card keeps only its
        // inline UI state + error surfacing.
        guard let store = container?.makeExportStore() else { return }
        isWorking = true
        errorMessage = nil
        exportURL = nil
        defer { isWorking = false }
        do {
            exportURL = try await store.downloadDomainCSV(domain)
        } catch let error as HLError {
            // Graceful 10/h rate-limit + every other error — friendly copy,
            // never a crash or a silent swallow.
            errorMessage = error.userFacingDescription
        } catch {
            errorMessage = String(localized: "Couldn't export. Please try again.")
        }
    }
}
