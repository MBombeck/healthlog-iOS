import SwiftUI

/// `Settings → Export → Share with clinician` — mint, list, and revoke
/// clinician share-links (server v1.12.1 B1). A share-link is a scoped,
/// time-limited, revocable link the user hands a doctor; the doctor opens the
/// rendered health-record view on the web. What the link exposes is the v2
/// selection the user picks while minting (CU-12); the never-built FHIR-API
/// affordance is gone.
///
/// **Retired links (migration 0275).** The v1.32.39 selection migration revoked
/// *every* link minted before it, because an old scope had no honest translation
/// into the new leaf grammar. Those rows come back carrying
/// `needsReselection: true`, and until CU-12 nothing decoded that flag — a dead
/// link looked exactly like a live one. ``retiredCard`` names the state and
/// offers the only real recovery: mint a replacement. It is not a renewal, and
/// the copy must not pretend otherwise.
///
/// Server-only surface: gates on `BackendAvailability.hasServer` (standalone →
/// the calm `HLCloudDerivedPlaceholder`, never a dead button), mirroring the
/// per-domain CSV exports.
struct ShareWithClinicianScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container

    @State private var store: ShareLinkStore?

    var body: some View {
        HLSettingsPage(title: "Share with clinician") {
            if backend.hasServer {
                connectedBody
            } else {
                HLCloudDerivedPlaceholder(
                    variant: .inline,
                    surfaceName: String(localized: "clinician sharing"),
                    onConnect: { authStore.beginServerPairing() }
                )
            }
        }
        .navigationTitle("Share with clinician")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard backend.hasServer, store == nil, let api = container?.api else { return }
            let s = ShareLinkStore(
                repo: ShareLinkRepository(api: api),
                capabilities: ServerCapabilitiesRepository(api: api)
            )
            store = s
            await s.load()
            // The leaf vocabulary is only needed once the create sheet opens, but
            // fetching it here means the sheet paints its picker instead of a
            // spinner. A failure is silent by design — the sheet renders its own
            // honest unavailable state.
            await s.loadSelectionVocabulary()
        }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if let store {
            createCard(store: store)
            if !store.retiredLinks.isEmpty {
                retiredCard(store: store)
            }
            linksCard(store: store)
            infoCard
        }
    }

    /// **18-03 — this screen no longer mints anything.**
    ///
    /// Creating a link asks *what* and *for how long* and *in which form*, and
    /// those are the unified surface's three questions. Keeping a second
    /// create form here would be the fifth surface the consolidation exists to
    /// remove, so the row is a door rather than a sheet — which is also why the
    /// one-time token reveal no longer happens on this screen: the link is
    /// minted where it is configured, and revealed there.
    ///
    /// **R19 / privacy-review (U6, Audit-Gruppe G1).** Der Footer sagte „Der
    /// Link wird nur einmal angezeigt … er kann später nicht wiederhergestellt
    /// werden" — an einer Stelle, an der es den Link noch gar nicht gibt und
    /// der Nutzer nichts tun kann. Die Aussage steht unverkürzt in
    /// ``ShareLinkTokenPanel`` (Warn-Block), also genau in dem Moment, in dem
    /// sie handlungsleitend ist: der Link liegt vor und muss jetzt kopiert
    /// oder geteilt werden. Die Klasse-D-Zusage verliert damit nichts an
    /// Stärke, sie steht nur noch an ihrer Heimat (R3/R19).
    private func createCard(store: ShareLinkStore) -> some View {
        HLSettingsCard(
            icon: "link.badge.plus",
            title: "New share link",
            subtitle: "Pick a label, a time range, and an expiry date."
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSettingsActionRow(
                    title: "Create link",
                    presents: .push
                ) {
                    UnifiedSharingScreen(preselectedForm: .link)
                }
                .accessibilityIdentifier("settings.shareLinks.create")

                if let error = store.error {
                    Text(error)
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Names the migration-0275 casualties and offers the only recovery there
    /// is. Deliberately worded as a replacement, not a renewal: the old link
    /// stays revoked, the new one carries a new token **and** a new passphrase,
    /// and the recipient needs both again.
    private func retiredCard(store: ShareLinkStore) -> some View {
        HLSettingsCard(
            icon: "exclamationmark.triangle",
            title: "shareLink.retired.title",
            subtitle: "shareLink.retired.subtitle"
        ) {
            // R19 / privacy-review (U6, G5) — Subtitle und Body sagten dasselbe
            // in kurz und lang, direkt untereinander. Der Subtitle benennt den
            // Zustand („bei einem Server-Update zurückgezogen"); die
            // vollständige Erklärung — neues Token, neue Passphrase, beide
            // müssen neu zur Ärztin — steht in `shareLink.remint.body` als
            // Preambel des Erstellen-Sheets, also dort, wo der Ersatz-Link
            // tatsächlich entsteht. Keine Aussage geht verloren.
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // 18-03 — the unabridged statement used to be the create
                // sheet's preamble. The sheet is gone, so it lands here, which
                // is where the user actually meets the retired link: a
                // replacement carries a NEW token and a NEW passphrase, and the
                // recipient needs both again.
                Text("shareLink.remint.body")
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shareLink.remint.body")
                ForEach(store.retiredLinks) { link in
                    HStack(spacing: HLSpace.md) {
                        Text(link.label)
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.primary)
                        Spacer()
                        NavigationLink {
                            UnifiedSharingScreen(preselectedForm: .link)
                        } label: {
                            Text("shareLink.retired.action")
                                .font(.hlFootnote.weight(.semibold))
                                .foregroundStyle(HLColor.statusWarn)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.shareLinks.retired.remint")
                    }
                }
            }
        }
    }

    private func linksCard(store: ShareLinkStore) -> some View {
        // R19 / privacy-review (U6, G2) — dieser Subtitle war wörtlich die
        // dritte Zeile der Info-Karte darunter („Widerrufe jeden Link
        // jederzeit, um den Zugriff sofort zu beenden."). Die Aussage bleibt
        // zweifach: erklärend in der Info-Karte und — unverkürzt — im
        // Bestätigungsdialog des Widerrufs, dem Ort der Handlung.
        HLSettingsCard(
            icon: "list.bullet.rectangle",
            title: "Active links"
        ) {
            if store.isLoading, store.links.isEmpty {
                HStack { Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            } else if store.activeLinks.isEmpty {
                Text("No active share links.")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            } else {
                VStack(spacing: HLSpace.md) {
                    ForEach(store.activeLinks) { link in
                        ShareLinkRow(link: link) {
                            Task { await store.revoke(id: link.id) }
                        }
                    }
                }
            }
        }
    }

    private var infoCard: some View {
        HLSettingsCard(
            icon: "lock.shield",
            title: "How sharing works"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                infoRow(icon: "clock", text: "Every link expires automatically (max 90 days).")
                infoRow(icon: "eye.slash", text: "Links open a read-only record view — no account access.")
                infoRow(icon: "xmark.circle", text: "Revoke any link at any time to end access instantly.")
            }
        }
    }

    private func infoRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.tertiary)
                .frame(width: 20)
            Text(text)
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Link row

private struct ShareLinkRow: View {
    let link: ShareLinkDTO
    let onRevoke: () -> Void

    @State private var confirmRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                Text(link.label)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Spacer()
                Button(role: .destructive) {
                    confirmRevoke = true
                } label: {
                    Text("Revoke")
                        .font(.hlFootnote.weight(.semibold))
                        .foregroundStyle(HLColor.statusBad)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.shareLinks.revoke")
            }
            HStack(spacing: HLSpace.md) {
                Label(expiryText, systemImage: "clock")
                Label("\(link.accessCount)", systemImage: "eye")
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
        }
        .padding(.vertical, HLSpace.xs)
        .hlConfirmDestructive(
            Text("Revoke this share link?"),
            isPresented: $confirmRevoke,
            message: Text("The doctor will lose access immediately. This can't be undone."),
            confirm: Text("Revoke link"),
            cancel: Text("Cancel"),
            action: onRevoke
        )
    }

    private var expiryText: String {
        guard let date = ShareLinkDateFormat.parse(link.expiresAt) else {
            return String(localized: "Expires soon")
        }
        let formatted = HLDateFormat.date(date, style: .abbreviated)
        return String(localized: "Until \(formatted)")
    }
}

// MARK: - ISO date helpers

/// Shared ISO-8601-with-offset parsing/formatting for the share-link surface.
/// The server requires ISO with offset on `rangeStart` / `rangeEnd` / `expiresAt`.
enum ShareLinkDateFormat {
    /// Emits the offset in the timestamp. `ISO8601DateFormatter` always renders a
    /// trailing `Z` when its `timeZone` is UTC; the server accepts `Z` as a valid
    /// offset, and `Z` keeps the wire unambiguous regardless of device locale.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Produce an ISO-8601 string **with** offset (here `Z` = +00:00), as the
    /// server requires on `rangeStart` / `rangeEnd` / `expiresAt`.
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func parse(_ raw: String) -> Date? {
        formatter.date(from: raw) ?? ISO8601DateFormatter.fractional.date(from: raw)
    }
}
