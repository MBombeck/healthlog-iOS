import SwiftUI

/// `/settings/about` — Über. Mirrors `about-section.tsx` (3 cards on web:
/// Identity, Links, Updates).
///
/// **PB3 scope:** Identity card shows Version + Build + Bundle-ID. License
/// + git-SHA + build-date are tracked as PA2 §4 follow-up — they require
/// either an Info.plist-generated set of build-time constants or a server
/// `/api/version` endpoint that iOS does not yet consume.
///
/// Links card surfaces the public Privacy / Repository / Docs anchors
/// against the managed host (the canonical production instance) — the
/// URLs themselves live in `SERVER-BACKLOG.md SB-3` and are referenced
/// fail-soft today. Reviewer cross-checks the privacy URL here against
/// the privacy manifest declarations; mismatch is a reject risk.
///
/// The web's Updates card has no iOS counterpart since 1.4 B2-c: the App
/// Store delivers updates and a card that only said so was removed.
struct SettingsAboutScreen: View {
    @Environment(\.appContainer) var container
    /// #134 — "Support-Info kopieren" (`SettingsAboutScreen+SupportInfo.swift`).
    @State var supportInfoState: SupportInfoCopyState = .idle

    var body: some View {
        HLSettingsPage(title: "About") {
            // v0.8.0 W7 W3/C4 — the Server card was promoted out of About
            // into its own "Server & sync" hub row (operational, not
            // "about the app"). About now leads with Identity, then the
            // legally-important Disclaimer, then Links + Updates.
            identityCard
            disclaimerCard
            linksCard
            supportCard
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// v0.7.0 W-APPSTORE — Apple Guideline 1.4.1 (medical-app safety):
    /// a surfaced "not for diagnosis / consult a doctor / methodology"
    /// disclaimer reachable from Settings → Über. HealthLog summarizes
    /// values + surfaces AI-derived insights, so App Review expects an
    /// explicit non-diagnostic disclaimer that the user can find inside
    /// the app, not only in the store listing. Localized (DE primary,
    /// EN parity) via `appstore.disclaimer.*`.
    private var disclaimerCard: some View {
        HLSettingsCard(
            icon: "exclamationmark.shield.fill",
            title: "appstore.disclaimer.card_title",
            subtitle: "appstore.disclaimer.card_subtitle",
            footer: "appstore.disclaimer.footer",
            // UI-Standard R5/E9 — die eine dokumentierte Doppelbelegung dieses
            // Screens. Beide Slots sind Klasse D und nicht verhandelbar: der
            // Subtitle ist die Leseaufforderung zur Guideline-1.4.1-Karte, der
            // Footer der Notruf-Hinweis (Klasse 4, R16-geschützt). Sie tragen
            // verschiedene Aussagen und dürfen nicht zusammengelegt werden.
            bothSlotsJustification: "Apple 1.4.1 Disclaimer-Karte: Leseaufforderung (D) und Notruf-Hinweis (Klasse 4) sind zwei geschützte Aussagen."
        ) {
            HLIconTextRow(icon: "stethoscope", "appstore.disclaimer.not_for_diagnosis")
            HLIconTextRow(icon: "cross.case.fill", "appstore.disclaimer.consult_doctor")
            HLIconTextRow(icon: "function", "appstore.disclaimer.methodology")
        }
        .accessibilityIdentifier("settings.about.disclaimerCard")
    }

    /// UI-Standard R2 — der Subtitle („App-Identität und Build-Informationen.")
    /// zählte die drei Zeilen darunter auf (Version, Build, Bundle-ID).
    /// Tautologie, gefallen.
    private var identityCard: some View {
        HLSettingsCard(
            icon: "info.circle.fill",
            title: "HealthLog"
        ) {
            // Y8 H-1: brand-anchor surface — the monochrome BrandMark
            // sits above the version stats so the about-card reads
            // as the app's identity card, not just a build-info dump.
            // Only the WelcomeStep carried the mark before; adopting
            // here gives the brand recognition a second anchor without
            // adding chrome the operator does not need.
            HStack {
                Spacer()
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                    .accessibilityHidden(true)
                Spacer()
            }
            .padding(.bottom, HLSpace.xs)
            statRow(label: "Version", value: appVersionString)
            statRow(label: "Build", value: buildNumberString)
            statRow(label: "Bundle ID", value: bundleIdentifierString)
        }
    }

    /// UI-Standard R2 — der Subtitle („Datenschutz und Dokumentation.") nannte
    /// exakt die zwei Zeilen, die direkt darunter „Datenschutzerklärung" und
    /// „Dokumentation" heißen. Gefallen.
    private var linksCard: some View {
        HLSettingsCard(
            icon: "book.fill",
            title: "Links"
        ) {
            // parity 2.9 — resolve against the CONFIGURED server, not the
            // hardcoded operator host. A self-hoster reading "Privacy policy"
            // was sent to the managed host's `/privacy` — someone else's
            // policy, describing someone else's data handling. Same bug class
            // as the forgot-password host fix (audit 02 · C-1).
            linkRow(
                title: "Privacy policy",
                // 09-03 — rendered from the configured-server value snapshot;
                // this body performs no Keychain query.
                url: (container?.configuredServer ?? .bundleFallback).privacyPolicyURL,
                identifier: "settings.about.privacyLink"
            )
            // #61 — `/docs` never existed on any instance. The server owners
            // resolved it to a deliberately EXTERNAL, instance-independent target,
            // so this URL is fixed and is NOT resolved against the configured
            // server host (unlike the privacy link above).
            linkRow(
                title: "Documentation",
                url: URL(string: "https://docs.healthlog.dev"),
                identifier: "settings.about.docsLink"
            )
            // 1.0.3 (App Review 1.4.1) — in-app hub of every medical source.
            NavigationLink {
                MedicalSourcesScreen()
            } label: {
                HStack(spacing: HLSpace.md) {
                    Text("settings.about.medicalSources")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.hlIcon(HLIconSize.sm))
                        .foregroundStyle(HLText.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.about.medicalSourcesLink")
        }
    }

    // 1.4 B2-c — the Updates card is gone. It had no function: "updates
    // ship through the App Store" plus "this app does not check", beside a
    // decorative (i) that did nothing when tapped.

    // MARK: - Helpers

    /// v0.11 W-settings-typography: `.hlSubhead` label, `.hlBody` value (the
    /// Server-screen statRow contract, b146/W37-P4). 1.4 B4: the shared
    /// `HLSettingsStatRow`, which stacks at the accessibility sizes.
    private func statRow(label: LocalizedStringKey, value: String) -> some View {
        HLSettingsStatRow(label: Text(label), value: value)
    }

    /// parity 2.9 — the in-product privacy policy of the **configured**
    /// instance. `/privacy` is a real server route, so this resolves to a live
    /// page on a self-hosted deployment too. Pure + static so it is unit-testable.
    /// `nil`, solange kein Server eingerichtet ist.
    static func privacyPolicyURL(keychain: KeychainStoring?) -> URL? {
        ConfiguredServerSnapshot.resolve(keychain: keychain).privacyPolicyURL
    }

    @ViewBuilder
    private func linkRow(title: LocalizedStringKey, url: URL?, identifier: String) -> some View {
        if let url {
            Link(destination: url) {
                HStack(spacing: HLSpace.md) {
                    Text(title)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.hlIcon(HLIconSize.sm))
                        .foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier(identifier)
        } else {
            HStack(spacing: HLSpace.md) {
                Text(title)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.tertiary)
                Spacer()
                Text("Not available")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            .accessibilityIdentifier(identifier)
        }
    }

    /// **08-07 — the version truth, read and never composed.**
    ///
    /// The two Info-dictionary keys are named here, at the presentation site,
    /// because this is where a reader checks what About shows against what
    /// the bundle says. Everything after the read is pure
    /// (``AppBuildMetadata``), so this seam is the whole impure surface of
    /// About's identity card and it is unit-testable without a view.
    ///
    /// Until 08-07 this method's predecessor computed the displayed version
    /// as `CFBundleShortVersionString + "." + (CFBundleVersion - 40)`. The two
    /// keys are independent strings and nothing on iOS relates them, so the
    /// result named a release that never existed. There is no arithmetic left
    /// here, and there must not be any again.
    static func buildMetadata(bundle: Bundle = .main) -> AppBuildMetadata {
        AppBuildMetadata(
            marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"),
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion")
        )
    }

    /// Stands in for a bundle value the binary does not carry. Localized,
    /// because "unknown" is a sentence shown to a user, not a placeholder
    /// glyph — and stating it is the honest alternative to inventing a
    /// number that looks like a version.
    private static var unknownValue: String {
        String(localized: "Unknown")
    }

    private var appVersionString: String {
        Self.buildMetadata().marketingVersionText(unknown: Self.unknownValue)
    }

    private var buildNumberString: String {
        Self.buildMetadata().buildText(unknown: Self.unknownValue)
    }

    private var bundleIdentifierString: String {
        Bundle.main.bundleIdentifier ?? Self.unknownValue
    }
}
