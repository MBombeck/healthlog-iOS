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

    @Test("Rechts nur die Zeichen, die iOS kennt: Chevron, Teilen, externes Ziel oder nichts")
    func indicatorMapping() {
        #expect(Row.indicator(for: .sheet) == .disclosure, "ein Sheet öffnet sich hinter dem Chevron, kein Stift")
        #expect(Row.indicator(for: .create) == .hidden, "Anlegen trägt das Plus vorn, rechts nichts")
        #expect(Row.indicator(for: .share) == .symbol("square.and.arrow.up"))
        #expect(Row.indicator(for: .external) == .symbol("arrow.up.right"))
        // `.confirm` löst an Ort und Stelle aus (bzw. öffnet einen
        // confirmationDialog) — die Zeile führt nirgendwohin, also kein Zeichen.
        #expect(Row.indicator(for: .confirm) == .hidden)
        #expect(Row.trailingSymbol(for: .sheet) == nil)
        #expect(Row.trailingSymbol(for: .external) == "arrow.up.right")
    }

    @Test("Kein Zubehör außer Chevron, Teilen und externem Ziel; nie Stift oder Plus rechts")
    func noPencilOrPlusOnTheRight() {
        for presents in Row.Presents.allCases {
            let symbol = Row.trailingSymbol(for: presents) ?? ""
            #expect(!symbol.contains("pencil"), "\(presents.rawValue) trägt einen Stift")
            #expect(!symbol.contains("plus"), "\(presents.rawValue) trägt ein Plus rechts")
        }
    }

    @Test("Eine Zeile, die etwas anlegt, trägt das Plus vorn, außer sie bringt ihr eigenes Symbol")
    func createLeadsWithPlus() {
        #expect(Row.leadingSymbol(icon: nil, presents: .create) == "plus")
        #expect(Row.leadingSymbol(icon: "camera", presents: .create) == "camera")
        #expect(Row.leadingSymbol(icon: nil, presents: .sheet) == nil)
        #expect(Row.leadingSymbol(icon: nil, presents: nil) == nil)
    }

    @Test("Only the row that leaves the app is a link for VoiceOver")
    func onlyExternalIsALink() {
        #expect(Row.isLink(.external))
        for presents in Row.Presents.allCases where presents != .external {
            #expect(!Row.isLink(presents), "\(presents) reads as a link")
        }
    }

    @Test("Der Aktions-Typ kennt genau die fünf R10-Fälle und keinen Push")
    func presentsHasNoPushCase() {
        #expect(Row.Presents.allCases.map(\.rawValue).sorted() == ["confirm", "create", "external", "share", "sheet"])
        #expect(!Row.Presents.allCases.contains { $0.rawValue == "push" })
    }
}
