@testable import HealthLog
import SwiftUI
import Testing

/// **UI-Standard E3 / R10** — der Glyph-Vertrag der Auslöse-Zeile.
///
/// Der Komponenten-Audit fand auf `SettingsDashboardScreen` vier optisch
/// identische Chevron-Zeilen, von denen zwei ein Sheet öffnen statt zu pushen
/// („Ein Chevron nach rechts ist in iOS die Ansage ‚es geht weiter nach
/// rechts'. Zwei von vier lösen das nicht ein."). Nach dem Umbau wählt nicht
/// mehr der Aufrufer das Trailing-Glyph, sondern der Pflichtparameter
/// `presents:`.
///
/// Zwei Hälften erzwingen das:
///
/// - **Der Compiler** verhindert die falsche Kombination. `.push` liegt in
///   einem eigenen Typ (`HLSettingsActionRow.Push`), der nur vom
///   `destination:`-Initializer angenommen wird; `Presents` — der Typ des
///   Aktions-Initializers — kennt keinen `.push`-Fall. Ein Chevron mit
///   Sheet-Verhalten ist damit nicht formulierbar, nicht nur unerwünscht.
/// - **Dieser Test** nagelt die Zuordnung Fall → Symbol fest, damit niemand
///   den Vertrag später still im Primitive verschiebt.
@Suite("UI-Standard E3 — HLSettingsActionRow: das Glyph gehört dem Primitive")
struct HLSettingsActionRowContractTests {
    typealias Row = HLSettingsActionRow<EmptyView, EmptyView>

    @Test("Jeder Präsentationsfall trägt exakt das von R10 verlangte Symbol")
    func glyphMapping() {
        #expect(Row.trailingSymbol(for: .sheet) == "pencil")
        #expect(Row.trailingSymbol(for: .create) == "plus.circle")
        #expect(Row.trailingSymbol(for: .share) == "square.and.arrow.up")
        #expect(Row.trailingSymbol(for: .external) == "arrow.up.right.square")
        // `.confirm` löst an Ort und Stelle aus (bzw. öffnet einen
        // confirmationDialog) — die Zeile führt nirgendwohin, also kein Glyph.
        #expect(Row.trailingSymbol(for: .confirm) == nil)
    }

    @Test("Kein Präsentationsfall malt einen Chevron — der ist dem Push vorbehalten")
    func noActionCaseWearsAChevron() {
        for presents in Row.Presents.allCases {
            let symbol = Row.trailingSymbol(for: presents) ?? ""
            #expect(
                !symbol.hasPrefix("chevron"),
                """
                \(presents.rawValue) trägt „\(symbol)". Ein Chevron ist in iOS die Ansage \
                „es geht weiter nach rechts" und darf ausschließlich am Push stehen. \
                Push ist über HLSettingsActionRow(presents: .push, destination:) erreichbar, \
                der den NavigationLink selbst baut.
                """
            )
        }
    }

    @Test("Der Aktions-Typ kennt genau die fünf R10-Fälle und keinen Push")
    func presentsHasNoPushCase() {
        #expect(Row.Presents.allCases.map(\.rawValue).sorted() == ["confirm", "create", "external", "share", "sheet"])
        #expect(!Row.Presents.allCases.contains { $0.rawValue == "push" })
    }
}
