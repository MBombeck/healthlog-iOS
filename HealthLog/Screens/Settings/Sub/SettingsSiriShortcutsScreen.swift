import AppIntents
import SwiftUI

/// **v0.15 W-SIRI** — Settings → Siri & Shortcuts.
///
/// A read-only explainer surface for the app's App Intents stack: it lists,
/// in plain language, what the user can say to Siri (or wire into a Shortcut)
/// and how each action behaves. The Shortcuts/Siri stack is otherwise
/// invisible — iOS surfaces the phrases in Spotlight and the Shortcuts app,
/// but a user who never opens those never learns the affordances exist. This
/// screen is the in-app discovery surface the operator mandate asks for.
///
/// `ShortcutsLink` jumps straight into the Shortcuts app filtered to
/// HealthLog's actions; `SiriTipView` renders Apple's native "Add to Siri"
/// affordance for one representative intent. Both are pure system controls —
/// no parallel intent registration, no donation here (the
/// `AppShortcutsProvider` already donates at app launch).
struct SettingsSiriShortcutsScreen: View {
    var body: some View {
        HLSettingsPage(title: "Siri & Shortcuts") {
            phrasesCard
            quickActionsCard
            howItWorksCard
        }
        .navigationTitle("Siri & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - What you can say

    private var phrasesCard: some View {
        HLSettingsCard(
            icon: "mic.fill",
            title: "What you can say",
            footer: "Start any phrase with “Hey Siri”. Replace the example values and medication names with your own."
        ) {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                ForEach(Array(Self.phrases.enumerated()), id: \.offset) { idx, entry in
                    phraseRow(entry)
                    if idx < Self.phrases.count - 1 {
                        Divider().opacity(0.6)
                    }
                }
            }
        }
    }

    private func phraseRow(_ entry: PhraseEntry) -> some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: entry.symbol)
                .font(.hlSubhead)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(entry.phrase)
                    .font(.hlSubhead.weight(.medium))
                    .foregroundStyle(HLText.primary)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shortcuts app + Add to Siri

    /// UI-Standard R2 — der Karten-Footer erzählte die zwei System-Controls
    /// darunter nach („Öffne die Kurzbefehle-App …, oder füge eine zu Siri
    /// hinzu."). `ShortcutsLink` und `SiriTipView` beschriften sich selbst.
    /// Gefallen.
    private var quickActionsCard: some View {
        HLSettingsCard(
            icon: "square.stack.3d.up.fill",
            title: "Build your own"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                ShortcutsLink()
                    .shortcutsLinkStyle(.automatic)
                    .accessibilityIdentifier("settings.siri.shortcutsLink")
                SiriTipView(intent: LogMeasurementIntent())
                    .siriTipViewStyle(.automatic)
                    .accessibilityIdentifier("settings.siri.tip")
            }
        }
    }

    // MARK: - How it works

    private var howItWorksCard: some View {
        HLSettingsCard(
            icon: "info.circle.fill",
            title: "How it works"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text(
                    """
                    Logging by voice goes through the same secure path as the app: your entry is saved to your \
                    account, mirrored to Apple Health when relevant, and queued safely if you’re offline — it \
                    syncs the next time you open HealthLog.
                    """
                )
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "You need to be signed in. If you’re signed out, Siri will ask you to open HealthLog first."
                )
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
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
    /// **UI-Standard R2 (U5).** Vier Beschreibungen sind gefallen, weil sie den
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
