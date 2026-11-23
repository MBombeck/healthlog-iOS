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
///   2. Per-domain CSV — Measurements / Mood / Medications.
///
/// **SET-V2-A (B.1 + C-2):** the full backup used to live one push deeper on a
/// dedicated `ExportScreen` — a structural double-hop (the hub subtitle
/// promised "Full backup, CSV per area" but delivered only after an extra
/// push). The former screen's body (format picker, `/api/export` download,
/// share) is now inlined as `FullBackupExportCard` below and the screen was
/// deleted; everything export lives on this ONE page.
///
/// The per-domain CSVs are *server-rendered* (canonical column order, locale,
/// audit columns). They have no byte-exact on-device twin. The full on-device backup
/// remains the offline data-portability path.
struct SettingsExportScreen: View {
    var body: some View {
        HLPage {
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
            // /api/export/encrypted`, HLX1 archive).
            EncryptedBackupExportCard()
            ImportDataCard()
            domainExportSection
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Labelled card pushing the doctor-handover hub. Mirrors the
    /// row chrome used across the Settings sub-screens (icon · title · subtitle ·
    /// "Open …" disclosure row) so it reads as a peer of the export cards below.
    private var shareWithDoctorCard: some View {
        // One row, one heading: the row carries title and a one-line
        // detail like the import row below.
        HLCard(layout: .rows) {
            HLSettingsActionRow(
                title: "settings.export.share_with_doctor.title",
                subtitle: "settings.export.share_with_doctor.rowSubtitle",
                presents: .push
            ) {
                UnifiedSharingScreen()
            }
            .accessibilityIdentifier("settings.export.shareWithDoctorRow")
        }
    }

    /// Restored per-domain CSV exports (dropped under the AC18
    /// placeholder). One card per domain; each downloads the server's canonical
    /// CSV and offers it via `ShareLink`.
    /// UI-Standard R2 (U6, Audit-Gruppe G9) — die drei Untertitel sagten
    /// dreimal, dass eine CSV eine Tabelle ist; jede Karte heißt bereits
    /// „… (CSV)". Ersatzlos gestrichen.
    @ViewBuilder
    private var domainExportSection: some View {
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
    }
}

/// The full JSON/CSV backup — the former `ExportScreen` body inlined as a card
/// (SET-V2-A / B.1). `GET /api/export?type=all` with the picked format (R2 / A4 —
/// it was a `POST`, which the route never answered but with 405), a step-up
/// proof when the server asks for one, persist into the temp directory under
/// `.completeFileProtection`, then offer the file via `ShareLink`. The share
/// button + error surfacing mirror `DomainCSVExportCard` below so the whole page
/// speaks exactly one interaction language (Quality Doctrine §6).
private struct FullBackupExportCard: View {
    @Environment(\.appContainer) private var container

    @State private var format: ExportFormat = .json
    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var stepUp = StepUpRetry()

    enum ExportFormat: String, CaseIterable, Identifiable {
        case json
        case csv
        var id: String {
            rawValue
        }

        var label: String {
            rawValue.uppercased()
        }

        /// Bridge to the service-owned format.
        var serviceFormat: ExportService.BackupFormat {
            switch self {
            case .json: .json
            case .csv: .csv
            }
        }
    }

    var body: some View {
        // The title says it: no subtitle, and no paragraph number
        // ("Art. 20") that gives nobody anything to do.
        HLCard("Full backup (JSON / CSV)") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLAdaptiveSegmentedPicker(
                    "Format",
                    selection: $format,
                    labels: ExportFormat.allCases.map { LocalizedStringKey($0.label) }
                ) {
                    ForEach(ExportFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }

                // The full-backup "Export erstellen" was a
                // `.large` full-fill CTA the operator called "creepy" / far too
                // UI-Standard R9 — `.restrained` ist gefallen. Voll-Backup
                // und verschlüsseltes Backup sind zwei gleichrangige
                // Karten-Aktionen auf einem Screen; „höchstens ein `.primary`
                // pro Screen" heißt hier: beide `.secondary`.
                HLButton(
                    "export.create.button",
                    systemImage: "square.and.arrow.down",
                    variant: .secondary,
                    isLoading: isWorking
                ) {
                    Task { await runExport() }
                }
                .accessibilityIdentifier("export.create.button")
                .stepUpConfirmation(stepUp) { await runExport() }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        HLButtonLabel("Share file", systemImage: "square.and.arrow.up", variant: .secondary)
                    }
                    .hlPressable()
                    .accessibilityIdentifier("settings.export.full.share")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.hlFootnote)
                        .foregroundStyle(StepUpRetry.messageTint(for: errorMessage))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runExport() async {
        // The `/api/export` service call + the
        // complete-file-protection persist are owned by `ExportStore` now (the
        // former in-view `ExportService` construction + file write were the last
        // in-view layering seam). The card keeps only its inline UI state.
        guard let store = container?.makeExportStore() else { return }
        isWorking = true
        errorMessage = nil
        exportURL = nil
        defer { isWorking = false }
        do {
            exportURL = try await store.downloadFullBackup(format.serviceFormat, elevation: stepUp.take())
        } catch let error as HLError {
            errorMessage = stepUp.requestIfProofRefusal(error)
                ? StepUpRetry.requiredMessage
                : error.userFacingDescription
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
    @State private var stepUp = StepUpRetry()

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
        HLCard(
            "export.encrypted.title",
            subtitle: "export.encrypted.subtitle",
            footer: "export.encrypted.footer"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                SecureField(String(localized: "export.encrypted.passphrase.placeholder"), text: $passphrase)
                    .hlSecretEntry()
                    .hlFieldPlate()
                    .accessibilityIdentifier("export.encrypted.passphrase")

                SecureField(String(localized: "export.encrypted.confirm.placeholder"), text: $confirmPassphrase)
                    .hlSecretEntry()
                    .hlFieldPlate()
                    .accessibilityIdentifier("export.encrypted.confirm")

                if !confirmPassphrase.isEmpty, !passphrasesMatch {
                    Text("export.encrypted.mismatch")
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusBad)
                }

                HLButton(
                    "export.encrypted.button",
                    systemImage: "lock.fill",
                    variant: .secondary,
                    isLoading: isWorking
                ) {
                    Task { await runExport() }
                }
                .disabled(!canExport)
                .accessibilityIdentifier("export.encrypted.button")
                .stepUpConfirmation(stepUp) { await runExport() }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        HLButtonLabel("Share file", systemImage: "square.and.arrow.up", variant: .secondary)
                    }
                    .hlPressable()
                    .accessibilityIdentifier("export.encrypted.share")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.hlFootnote)
                        .foregroundStyle(StepUpRetry.messageTint(for: errorMessage))
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
            exportURL = try await store.downloadEncryptedBackup(
                passphrase: passphrase,
                elevation: stepUp.take()
            )
            // The passphrase has served its purpose — drop it from memory once the
            // archive is minted (it is unrecoverable server-side anyway).
            passphrase = ""
            confirmPassphrase = ""
        } catch let error as HLError {
            // An account with a second factor is asked for that
            // factor (or a passkey); the passphrase stays for the retry.
            errorMessage = stepUp.requestIfProofRefusal(error)
                ? StepUpRetry.requiredMessage
                : error.userFacingDescription
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
        // One row, one heading.
        HLCard(layout: .rows) {
            HLSettingsActionRow(title: "import.card.title", subtitle: "import.card.subtitle", presents: .push) {
                ImportDataScreen()
            }
            .accessibilityIdentifier("settings.export.importRow")
        }
    }
}

/// One per-domain CSV export card. Encapsulates the download → persist → share
/// lifecycle plus error/rate-limit surfacing, so the three domains share exactly
/// one interaction language (Quality Doctrine §6: uniform, no bespoke per-card
/// behaviour). Glass discipline: pure `HLCard` content — no glass.
private struct DomainCSVExportCard: View {
    let domain: ExportService.Domain
    let icon: String
    let title: LocalizedStringKey

    @Environment(\.appContainer) private var container

    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        HLCard(title) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLRowButton {
                    Task { await run() }
                } label: {
                    HLRowLayout(
                        title: isWorking ? "Preparing…" : "Download CSV",
                        indicator: isWorking ? .hidden : .symbol("square.and.arrow.down")
                    ) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                    } leading: {
                        EmptyView()
                    }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("settings.export.csv.\(domain.rawValue)")

                if let exportURL {
                    ShareLink(item: exportURL) {
                        HLButtonLabel("Share file", systemImage: "square.and.arrow.up", variant: .secondary)
                    }
                    .hlPressable()
                    .accessibilityIdentifier("settings.export.csv.\(domain.rawValue).share")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.hlFootnote)
                        .foregroundStyle(StepUpRetry.messageTint(for: errorMessage))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func run() async {
        // The per-domain CSV service call + the complete-file-
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
