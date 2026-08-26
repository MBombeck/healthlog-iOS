import Foundation
@testable import HealthLog
import Testing

/// **N2 — der Nährstoff-Leerzustand muss sagen, was tatsächlich zutrifft.**
///
/// Die Fläche hatte für „keine Zeilen" genau einen Satz: „Sobald Apple Health
/// Vitamin-, Mineralstoff- oder Wasserdaten liefert, erscheinen hier die
/// Tageswerte." Bei ausgeschaltetem `nutrients`-Modul ist dieser Satz falsch —
/// und zwar auf die teuerste Art: Apple Health liefert, die App fragt nur nicht.
/// Er benennt eine Bedingung, die nicht die fehlende ist, und schickt den Leser
/// ins Warten auf etwas, das nie eintritt. Der Betreiber hat deshalb nie nach
/// einem Schalter gesucht („Mir war nicht bewusst, dass das Opt-in in der App
/// ist.").
///
/// Diese Suite nagelt die drei Zustände fest, die es wirklich gibt, und die vier
/// Arten, auf die die Kopie zurückfaulen könnte:
///
/// 1. **Die drei Fälle bleiben getrennt.** Modul aus / wird gerade vorbereitet /
///    an, gefragt, nichts da sind verschiedene Tatsachen.
/// 2. **Nur der handelbare Fall trägt eine Handlung.** Und die Handlung ist ein
///    Ziel, kein Wegweisersatz (UI-Standard R4).
/// 3. **Keine Behauptung über eine Ablehnung.** HealthKit beantwortet einen
///    verweigerten Lesetyp exakt wie einen leeren; die App kann es nicht wissen
///    und sagt es folglich nicht.
/// 4. **Der Modul-aus-Satz benennt den Zustand, ohne zu beschuldigen oder ein
///    Datum zu versprechen.**
///
/// Liest den eingecheckten Katalog direkt (``ParityCatalog``) statt über
/// `Bundle.localizedString` — dort löst eine fehlende Übersetzung auf ihren
/// eigenen Schlüssel auf und würde genau den Drift verdecken, den diese Suite
/// bewacht. Derselbe Grund, aus dem sie neben den anderen i18n-Wächtern liegt.
@Suite("N2 — Nährstoff-Leerzustand ist ehrlich")
struct NutrientEmptyStateHonestyTests {
    // MARK: - Fixtures

    /// Jeder Schlüssel, den der Leerzustand rendern kann.
    static let emptyStateKeys = [
        "nutrients.list.empty.title",
        "nutrients.list.empty.subtitle",
        "nutrients.list.empty.moduleOff.title",
        "nutrients.list.empty.moduleOff.message",
        "nutrients.list.empty.moduleOff.action"
    ]

    private func value(_ key: String, _ language: String) throws -> String {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings[key], "\(key) fehlt im Katalog")
        return try #require(ParityCatalog.value(entry, language: language), "\(key)/\(language) leer")
    }

    // MARK: - Katalog

    @Test("Alle Leerzustand-Schlüssel sind in DE und EN gefüllt")
    func keysArePresentInBothLocales() throws {
        for key in Self.emptyStateKeys {
            for language in ["de", "en"] {
                let text = try value(key, language)
                #expect(!text.isEmpty, "\(key)/\(language) ist leer")
            }
        }
    }

    // MARK: - 1. Die drei Fälle bleiben getrennt

    @Test("Die Zustände rendern verschiedene Texte — kein Fall erbt die Erklärung eines anderen")
    func casesDoNotShareCopy() {
        let moduleOff = NutrientEmptyState.moduleOff.presentationDescriptor()
        let noData = NutrientEmptyState.noData.presentationDescriptor()
        #expect(moduleOff?.titleKey != noData?.titleKey)
        #expect(moduleOff?.messageKey != noData?.messageKey)
        // `preparing` bekommt keinen Textblock — der Ladezustand ist dort die
        // ehrliche Darstellung. Ein Satz müsste eine Ursache erfinden.
        #expect(NutrientEmptyState.preparing.presentationDescriptor() == nil)
        // Und jeder Fall des Modells ist abgedeckt: keiner rutscht durch.
        #expect(NutrientEmptyState.allCases.count == 3)
    }

    @Test("Der alte Satz bleibt — aber nur noch dort, wo er stimmt")
    func theOldSentenceSurvivesOnlyWhereItIsTrue() throws {
        // Modul an, gefragt, nichts da: hier ist „sobald Apple Health liefert"
        // die zutreffende Aussage und bleibt wörtlich stehen.
        let descriptor = try #require(NutrientEmptyState.noData.presentationDescriptor())
        #expect(descriptor.messageKey == "nutrients.list.empty.subtitle")
        let de = try value("nutrients.list.empty.subtitle", "de")
        #expect(de.contains("Apple Health"))
        // Der Modul-aus-Fall darf ihn NICHT tragen.
        let moduleOff = try #require(NutrientEmptyState.moduleOff.presentationDescriptor())
        #expect(moduleOff.messageKey != "nutrients.list.empty.subtitle")
    }

    // MARK: - 2. Nur der handelbare Fall trägt eine Handlung

    @Test("Genau ein Fall bietet eine Handlung an — der einzige, in dem sie wirkt")
    func onlyTheActionableCaseCarriesAnAction() {
        #expect(NutrientEmptyState.moduleOff.presentationDescriptor()?.primaryAction == .enableModule)
        #expect(NutrientEmptyState.noData.presentationDescriptor()?.primaryAction == nil)
        #expect(NutrientEmptyState.noData.presentationDescriptor()?.actionKey == nil)
    }

    @Test("Die Handlung ist ein Ziel, kein Wegweisersatz")
    func theActionIsADestinationNotASignpost() throws {
        let cta = try value("nutrients.list.empty.moduleOff.action", "de")
        #expect(cta.count <= 40, "eine Beschriftung, kein Wegweiser-Satz")
        // R4: der Text darf den Nutzer nicht woandershin schicken — die
        // Schaltfläche erledigt es hier.
        for language in ["de", "en"] {
            let message = try value("nutrients.list.empty.moduleOff.message", language).lowercased()
            for needle in [
                "einstellungen", "unter mehr", "module-bildschirm",
                "in settings", "go to", "head to", "under more"
            ] {
                #expect(
                    !message.contains(needle),
                    "moduleOff.message/\(language) weist hin statt zu handeln: '\(needle)'"
                )
            }
        }
    }

    // MARK: - 3. Keine Behauptung über eine Ablehnung

    @Test("Nichts behauptet, die Berechtigung sei verweigert — das kann die App nicht wissen")
    func nothingClaimsADeniedPermission() throws {
        let forbidden: [(language: String, needles: [String])] = [
            ("de", [
                "verweigert", "abgelehnt", "verboten", "keine berechtigung",
                "nicht erlaubt", "zugriff verweigert", "kein zugriff"
            ]),
            ("en", [
                "denied", "refused", "not permitted", "no permission",
                "access denied", "not authorised", "not authorized"
            ])
        ]
        for key in Self.emptyStateKeys {
            for group in forbidden {
                let text = try value(key, group.language).lowercased()
                for needle in group.needles {
                    #expect(
                        !text.contains(needle),
                        "\(key)/\(group.language) behauptet eine Ablehnung, die HealthKit nie meldet: '\(needle)'"
                    )
                }
            }
        }
    }

    // MARK: - 4. Der Modul-aus-Satz: Zustand, keine Schuld, kein Termin

    @Test("Der Modul-aus-Satz benennt den Zustand und die echte Ursache")
    func moduleOffCopyNamesTheCondition() throws {
        let title = try value("nutrients.list.empty.moduleOff.title", "de")
        #expect(title.lowercased().contains("ausgeschaltet"))
        let titleEn = try value("nutrients.list.empty.moduleOff.title", "en")
        #expect(titleEn.lowercased().contains("switched off"))
        // Die Ursache ist: die App FRAGT nicht — nicht: es gibt nichts.
        let de = try value("nutrients.list.empty.moduleOff.message", "de")
        #expect(de.contains("fragt"))
        #expect(de.contains("Apple Health"))
        let en = try value("nutrients.list.empty.moduleOff.message", "en")
        #expect(en.lowercased().contains("asks"))
        #expect(en.contains("Apple Health"))
    }

    @Test("Kein Vorwurf und kein Termin")
    func moduleOffCopyNeitherBlamesNorPromises() throws {
        let forbidden = [
            // Schuldzuweisung
            "du hast", "leider", "vergessen", "you forgot", "you have not", "unfortunately",
            // Termin-Versprechen
            "demnächst", "in kürze", "bald", "geplant für", "coming soon", "shortly", "planned for"
        ]
        let moduleOffKeys = [
            "nutrients.list.empty.moduleOff.title",
            "nutrients.list.empty.moduleOff.message",
            "nutrients.list.empty.moduleOff.action"
        ]
        for key in moduleOffKeys {
            for language in ["de", "en"] {
                let text = try value(key, language).lowercased()
                for needle in forbidden {
                    #expect(!text.contains(needle), "\(key)/\(language): '\(needle)'")
                }
                #expect(
                    text.range(of: #"\b20\d{2}\b"#, options: .regularExpression) == nil,
                    "\(key)/\(language) nennt eine Jahreszahl"
                )
            }
        }
    }
}
