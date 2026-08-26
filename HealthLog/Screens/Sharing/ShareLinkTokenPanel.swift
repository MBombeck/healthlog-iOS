import SwiftUI

/// The one-time share-link reveal, as a panel rather than a screen.
///
/// **Extracted in 18-02, not rewritten.** The raw `hls_…` token comes back from
/// the server exactly once, and this is the single moment the user can copy or
/// share it — so the copy that says so, the passphrase block, the QR and the
/// clipboard guards are a Class-D surface that must exist once. The unified
/// sharing screen shows the reveal **in place** (it has no modal at all), while
/// `ShareLinkTokenSheet` still presents it from the link-management surface;
/// both render this panel, so neither can drift from the other's promises.
///
/// The shareable artifact is the full doctor URL (`<baseURL>/c/<token>`), which
/// is what the clinician opens. The token is never logged.
struct ShareLinkTokenPanel: View {
    let store: ShareLinkStore
    /// The configured server's base URL — used only to compose `<base>/c/<token>`
    /// for older server responses that carry no absolute `shareUrl`.
    let baseURL: URL?

    @State private var didCopy = false
    @State private var didCopyPassphrase = false

    private var shareURL: URL? {
        // Prefer the absolute `shareUrl` the server returns on create (v1.18.7);
        // fall back to composing `<base>/c/<token>` for older responses.
        if let absolute = store.freshShareUrl, let url = URL(string: absolute) {
            return url
        }
        guard let token = store.freshToken, let baseURL else { return nil }
        return baseURL.appendingPathComponent("c").appendingPathComponent(token)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            header

            if let url = shareURL {
                urlBox(url)

                ShareLink(item: url) {
                    actionRow(icon: "square.and.arrow.up", title: "Share link")
                }
                .hlPressable()
                .accessibilityIdentifier("shareLink.token.share")

                Button {
                    copy(url.absoluteString)
                } label: {
                    actionRow(
                        icon: didCopy ? "checkmark.circle.fill" : "doc.on.doc",
                        title: didCopy ? "Copied" : "Copy link",
                        tint: didCopy ? HLColor.statusOK : nil
                    )
                }
                .hlPressable()
                .accessibilityIdentifier("shareLink.token.copy")
            }

            if let passphrase = store.freshPassphrase, !passphrase.isEmpty {
                passphraseSection(passphrase)
            }

            warning
        }
        .sensoryFeedback(.success, trigger: didCopy) { _, new in new }
        .sensoryFeedback(.success, trigger: didCopyPassphrase) { _, new in new }
    }

    // MARK: - Passphrase + QR (v1.18.7 — passphrase-2FA)

    private func passphraseSection(_ passphrase: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "lock.shield.fill")
                        .font(.hlIcon(HLIconSize.sm))
                        .foregroundStyle(HLColor.statusOK)
                    Text("share.passphrase.title")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                }
                Text("share.passphrase.subtitle")
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(passphrase)
                .font(.hlTitle3.monospaced())
                .foregroundStyle(HLText.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(HLSpace.md)
                .background(
                    RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                        .fill(HLSurface.secondary)
                )
                .accessibilityIdentifier("shareLink.passphrase.value")

            Button {
                copyPassphrase(passphrase)
            } label: {
                actionRow(
                    icon: didCopyPassphrase ? "checkmark.circle.fill" : "doc.on.doc",
                    title: didCopyPassphrase ? "share.passphrase.copied" : "share.passphrase.copy",
                    tint: didCopyPassphrase ? HLColor.statusOK : nil
                )
            }
            .hlPressable()
            .accessibilityIdentifier("shareLink.passphrase.copy")

            if let qrUrl = store.freshQrUrl, !qrUrl.isEmpty {
                VStack(spacing: HLSpace.sm) {
                    QRCodeImage(payload: qrUrl, side: 200)
                        .accessibilityIdentifier("shareLink.qr.image")
                    Text("share.qr.caption")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(HLSpace.md)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .fill(HLColor.statusOK.opacity(0.08))
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.hlIcon(HLIconSize.hero))
                .foregroundStyle(HLColor.statusOK)
            if let label = store.freshLinkLabel {
                Text(label)
                    .font(.hlTitle3.weight(.semibold))
                    .foregroundStyle(HLText.primary)
            }
            Text("Send this link to your doctor. It opens a read-only view of your health record.")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.freshProtected {
                HLBadge(
                    String(localized: "share.protected.badge"),
                    icon: "lock.shield.fill",
                    tone: .success
                )
                .accessibilityIdentifier("shareLink.protected.badge")
            }
        }
    }

    private func urlBox(_ url: URL) -> some View {
        Text(url.absoluteString)
            .font(.hlFootnote.monospaced())
            .foregroundStyle(HLText.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HLSpace.md)
            .background(
                RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                    .fill(HLSurface.secondary)
            )
    }

    private func actionRow(icon: String, title: LocalizedStringKey, tint: Color? = nil) -> some View {
        HStack(spacing: HLSpace.md) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(tint ?? HLText.primary)
            Text(title)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, HLSpace.sm)
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HLColor.statusWarn)
            Text("This link is shown only once. We can't show it again — copy or share it now. You can always revoke it later.")
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HLSpace.md)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .fill(HLColor.statusWarn.opacity(0.12))
        )
    }

    private func copy(_ string: String) {
        // The clipboard guards (local-only + 120 s expiry) live on
        // `ShareLinkTokenSheet` and stay there: a source-level security pin
        // (`A360SecurityAppStoreFixTests`) reads that file by name, so moving
        // the helper would move the surface the pin watches.
        #if canImport(UIKit)
            ShareLinkTokenSheet.copySensitive(string)
        #endif
        didCopy = true
        // Reset the "Copied" affirmation so the row returns to its actionable
        // "Copy link" state — a stuck checkmark reads as a permanently-disabled
        // control on this one-time surface.
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func copyPassphrase(_ string: String) {
        #if canImport(UIKit)
            ShareLinkTokenSheet.copySensitive(string)
        #endif
        didCopyPassphrase = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyPassphrase = false
        }
    }
}
