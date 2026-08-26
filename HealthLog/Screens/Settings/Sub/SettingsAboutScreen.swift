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
/// Updates card is iOS-only (TestFlight handles updates on Apple
/// platforms) — surfaced as a placeholder, not removed, so the IA matches
/// web column-for-column.
struct SettingsAboutScreen: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        HLSettingsPage(title: "About") {
            // v0.8.0 W7 W3/C4 — the Server card was promoted out of About
            // into its own "Server & sync" hub row (operational, not
            // "about the app"). About now leads with Identity, then the
            // legally-important Disclaimer, then Links + Updates.
            identityCard
            disclaimerCard
            linksCard
            updatesCard
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
            bothSlotsJustification: "Apple 1.4.1 Disclaimer-Karte — Leseaufforderung (D) und Notruf-Hinweis (Klasse 4) sind zwei geschützte Aussagen."
        ) {
            disclaimerRow(
                icon: "stethoscope",
                text: "appstore.disclaimer.not_for_diagnosis"
            )
            disclaimerRow(
                icon: "cross.case.fill",
                text: "appstore.disclaimer.consult_doctor"
            )
            disclaimerRow(
                icon: "function",
                text: "appstore.disclaimer.methodology"
            )
        }
        .accessibilityIdentifier("settings.about.disclaimerCard")
    }

    private func disclaimerRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: icon)
                .font(.hlCallout.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .frame(width: 24)
            Text(text)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
                    .aspectRatio(contentMode: .fit)
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
        }
    }

    /// PB-future PA2 §4 — Updates card on web auto-runs a version check
    /// against `/api/version/check-updates`. On iOS App-Store / TestFlight
    /// handles updates natively, so a manual check is non-functional. We
    /// surface the card so the IA matches web, with copy explaining the
    /// platform reality.
    ///
    /// UI-Standard R5 — die Karte belegte beide Beitext-Slots mit derselben
    /// Aussage („Updates werden über den App Store ausgeliefert." + „iOS
    /// verwendet den App Store für Updates — kein manueller Check nötig.").
    /// Der Subtitle bleibt, der Footer als Langfassung ist gefallen.
    ///
    /// **08-07 — die Zeile behauptete Aktualität, die niemand geprüft hatte.**
    /// Ein grünes Siegel plus die Aussage, die installierte Version sei die
    /// aktuelle, ist eine Behauptung über den App Store — und iOS fragt hier
    /// niemanden, weder den Store noch den Server. Die Karte bleibt (die IA
    /// spiegelt Web spaltenweise), sagt jetzt aber nur noch das, was diese App
    /// selbst weiß: sie prüft nicht. Der Subtitle nennt den Lieferweg, die
    /// Zeile die Grenze — zwei verschiedene Aussagen, kein R5-Fall.
    private var updatesCard: some View {
        HLSettingsCard(
            icon: "arrow.triangle.2.circlepath",
            title: "Updates",
            subtitle: "Updates ship through the App Store."
        ) {
            HStack(spacing: HLSpace.md) {
                Image(systemName: "info.circle")
                    .font(.hlIcon(HLIconSize.lg))
                    .foregroundStyle(HLText.secondary)
                Text("settings.about.updates.no_version_check")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                Spacer()
            }
            .accessibilityIdentifier("settings.about.updatesRow")
        }
    }

    // MARK: - Helpers

    private func statRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // v0.11 W-settings-typography: match the canonical Settings row
            // label scale (`.hlSubhead`, 15pt) like Server/Account — was
            // `.hlBody` (17pt), 2pt larger than every sibling row. Value drops
            // the numeric `.hlMetric` font for the semantic `.hlBody` token
            // (mirrors the Server-screen statRow contract, b146/W37-P4).
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.md)
            Text(value)
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
        }
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
