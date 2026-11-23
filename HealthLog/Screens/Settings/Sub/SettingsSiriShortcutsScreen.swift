import AppIntents
import SwiftUI

/// Settings → Siri & Shortcuts.
///
/// A read-only explainer surface for the app's App Intents stack: it lists,
/// in plain language, what the user can say to Siri (or wire into a Shortcut)
/// and how each action behaves. The Shortcuts/Siri stack is otherwise
/// invisible — iOS surfaces the phrases in Spotlight and the Shortcuts app,
/// but a user who never opens those never learns the affordances exist. This
/// screen is the in-app discovery surface the operator mandate asks for.
///
/// An external row opens the Shortcuts app; `SiriTipView` renders Apple's
/// native "Add to Siri" affordance for one representative intent. No
/// parallel intent registration, no donation here (the
/// `AppShortcutsProvider` already donates at app launch).
struct SettingsSiriShortcutsScreen: View {
    @Environment(\.openURL) private var openURL

    /// Opens the Shortcuts app. iOS offers no public URL for one app's
    /// shortcuts; the system `ShortcutsLink` labelled itself with a bare
    /// "-Kurzbefehle" whenever the app name was not resolved.
    static let shortcutsAppURL = URL(string: "shortcuts://")

    var body: some View {
        HLPage {
            phrasesCard
            quickActionsCard
        }
        .navigationTitle("Siri & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        // What happens to a spoken entry, and that Siri needs you
        // signed in, is the screen's (i); the how-it-works card is gone.
        .hlPageActions([.info(Self.info, identifier: "settings.siri.info")])
    }

    static var info: HLInfoContent {
        HLInfoContent(
            title: String(localized: "Siri & Shortcuts"),
            identifier: "settings.siri.info.sheet",
            about: String(localized: "settings.siri.info.about"),
            sections: [
                HLInfoContent.Section(
                    title: String(localized: "settings.siri.info.signin.title"),
                    paragraphs: [
                        String(localized: "You need to be signed in. If you’re signed out, Siri will ask you to open HealthLog first.")
                    ]
                )
            ]
        )
    }

    // MARK: - What you can say

    private var phrasesCard: some View {
        // How to use the phrases, read before the list instead of
        // after it.
        HLCard(
            "What you can say",
            subtitle: "Start any phrase with “Hey Siri”. Replace the example values and medication names with your own."
        ) {
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                ForEach(Array(Self.phrases.enumerated()), id: \.offset) { _, entry in
                    phraseRow(entry)
                }
            }
        }
    }

    /// A phrase is a sentence to say, not a list entry: name and note wrap
    /// instead of ending in "…", in the row's title and detail type, with
    /// the symbol in the row's symbol column.
    private func phraseRow(_ entry: PhraseEntry) -> some View {
        HStack(alignment: .top, spacing: HLRowMetrics.gap) {
            HLRowGlyph(symbol: entry.symbol, tint: HLAccent.userBrandTint)
            VStack(alignment: .leading, spacing: HLRowMetrics.labelSpacing) {
                HLRowTitle(Text(entry.phrase))
                if let detail = entry.detail {
                    Text(detail)
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shortcuts app + Add to Siri

    /// The row's text is ours, so it reads the same in every language. The
    /// system's `SiriTipView` stood here and spoke the system language: an
    /// English "Log a measurement in HealthLog" under German phrases. The
    /// phrases card above already lists what to say, in the app's language.
    private var quickActionsCard: some View {
        HLCard("Build your own") {
            HLSettingsActionRow(
                icon: "square.2.layers.3d",
                title: "settings.siri.openShortcuts",
                presents: .external
            ) {
                if let url = Self.shortcutsAppURL { openURL(url) }
            }
            .accessibilityIdentifier("settings.siri.shortcutsLink")
        }
    }

    // MARK: - Phrase catalogue

    /// One example phrase + its plain-language description, plus the SF Symbol
    /// that fronts the row. A named value type (not a tuple) so the list reads
    /// declaratively and stays inside the lint budget.
    private struct PhraseEntry {
        let symbol: String
        let phrase: LocalizedStringKey
        /// `nil` where the phrase already says what the action does — the
        /// Beitext would only rephrase it (UI-Standard R2, Tautologie).
        let detail: LocalizedStringKey?
    }

    /// The phrases shown to the user. Kept in sync with ``HealthLogAppShortcuts``
    /// — every registered intent has a row here so the discovery surface never
    /// lies about what's available.
    ///
    /// **UI-Standard R2.** Vier Beschreibungen sind gefallen, weil sie den
    /// Satz darüber umformulierten („Blutdruck erfassen" → „Erfasse einen
    /// systolisch/diastolisch-Wert.", „Stimmung erfassen", „Medikament als
    /// genommen markieren", „Habe ich … heute schon genommen"). Die drei
    /// verbliebenen tragen etwas, das der Satz nicht sagt: den vollen Umfang
    /// hinter dem Beispielwert, den optionalen Mahlzeit-Kontext, und — bei
    /// „Wie ist meine Therapietreue" — dass die Antwort die *heutigen* Dosen
    /// nennt und keine Quote über einen Zeitraum (R2 Leseanleitung).
    private static let phrases: [PhraseEntry] = [
        PhraseEntry(
            symbol: "square.and.pencil",
            phrase: "“Log my weight 72 in HealthLog”",
            detail: "Log any measurement — weight, pulse, temperature, blood oxygen and more."
        ),
        PhraseEntry(
            symbol: "drop.fill",
            phrase: "“Log blood glucose in HealthLog”",
            detail: "Record a blood sugar reading, with an optional meal context."
        ),
        PhraseEntry(
            symbol: "heart.fill",
            phrase: "“Log blood pressure in HealthLog”",
            detail: nil
        ),
        PhraseEntry(
            symbol: "face.smiling",
            phrase: "“Log my mood in HealthLog”",
            detail: nil
        ),
        PhraseEntry(
            symbol: "pills.fill",
            phrase: "“Mark medication taken in HealthLog”",
            detail: nil
        ),
        PhraseEntry(
            symbol: "checkmark.seal",
            phrase: "“Did I take my naproxen today in HealthLog”",
            detail: nil
        ),
        PhraseEntry(
            symbol: "checklist",
            phrase: "“What’s my adherence rate in HealthLog”",
            detail: "Hear how many of today’s doses you’ve taken."
        )
    ]
}
