import SwiftUI

/// **CU-34 (Brief C6) — the Today hero-item picker.**
///
/// Lets the user say which of the eight ``HeroItemKind``s may surface under
/// "Worth a look" on Today. On Save it hands the chosen kinds back to the
/// caller, which persists them via
/// ``DashboardLayoutStore/setEnabledHeroItemKinds(_:)`` (the widgets PUT with
/// the preserve-when-absent contract, `baseUpdatedAt`-guarded).
///
/// **Switching everything off is a legal, deliberate choice** — it is not a
/// disabled Save. The server distinguishes an explicit empty set ("show
/// nothing") from an omitted field ("keep what is stored"), so the sheet must
/// let the user reach the empty set; the footnote below says what it will mean
/// instead of the UI silently refusing.
///
/// This sheet CONFIGURES the rail. It does not build or render rail entries —
/// that data path belongs to the Today surface and is deliberately untouched
/// here.
struct HeroItemKindSelectionSheet: View {
    /// The kinds currently enabled, used to pre-check the rows.
    let initialSelection: [HeroItemKind]
    /// Called with the new set when the user saves. May be EMPTY — see above.
    let onSave: ([HeroItemKind]) -> Void

    @State private var selection: Set<HeroItemKind>

    init(initialSelection: [HeroItemKind], onSave: @escaping ([HeroItemKind]) -> Void) {
        self.initialSelection = initialSelection
        self.onSave = onSave
        _selection = State(initialValue: Set(initialSelection))
    }

    var body: some View {
        HLSheetScaffold(
            "settings.dashboard.heroItems.sheetTitle",
            size: .standard,
            action: .save {
                onSave(HeroItemKind.allCases.filter(selection.contains))
                return true
            },
            isDirty: selection != Set(initialSelection)
        ) {
            HLPage {
                // UI-Standard R3 — der einleitende Satz ist gefallen. Er
                // trug denselben Katalogschlüssel wie der Karten-Subtitle
                // auf „Aussehen", der dieses Sheet öffnet: der Nutzer las
                // ihn zweimal in derselben Interaktion. Die Heimat ist die
                // Karte *vor* der Entscheidung, nicht das Sheet danach.
                HLCard(layout: .rows) {
                    ForEach(HeroItemKind.allCases, id: \.self) { kind in
                        row(for: kind)
                    }
                }

                footnotes
            }
        }
    }

    private func row(for kind: HeroItemKind) -> some View {
        let isSelected = selection.contains(kind)
        return HLChoiceRow(title: Text(kind.label), isSelected: isSelected, mode: .multiple) {
            if isSelected {
                selection.remove(kind)
            } else {
                selection.insert(kind)
            }
        }
        .accessibilityIdentifier("settings.heroItems.\(kind.rawValue)")
    }

    /// One honest note rather than a disabled button: what an empty selection
    /// does. It is zustandsabhängig (only visible when the selection *is*
    /// empty) and names a consequence the UI cannot show by itself — R2
    /// Kategorie „Folge", und damit die einzige Fußnote, die hier bleibt.
    ///
    /// **UI-Standard R4 —** die zweite Fußnote („Benachrichtigungseinstellungen
    /// werden separat verwaltet.") ist gefallen. Sie war ein Wegweiser ohne
    /// Ziel: sie nannte weder, wo diese Einstellungen liegen, noch bot sie
    /// einen Absprung an. Nach R4 gehört dorthin ein tippbares Element oder
    /// nichts.
    @ViewBuilder
    private var footnotes: some View {
        if selection.isEmpty {
            Text(String(
                localized: "With nothing selected, Today shows no highlights at all.",
                comment: "Today hero item picker — empty-selection note"
            ))
            .hlText(.rowSubtitle)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, HLSpace.sm)
            .accessibilityIdentifier("settings.heroItems.emptyNote")
        }
    }
}
