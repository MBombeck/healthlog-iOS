import Foundation
@testable import HealthLog
import Testing

/// **CU-37 — the ECG empty state must state what is actually true.**
///
/// The surface it guards was empty for a reason nobody could read off it. When
/// CU-37 rewrote the copy there was no HealthKit ECG reader and no JSON ingest
/// route, so an empty ECG surface meant *nothing was ever uploaded*, not *no
/// recording exists* — and the copy it replaced ("recordings sync from a
/// compatible single-lead device") asserted a transfer that did not happen.
///
/// **GH #74 / server v1.35.3 changed the premise, not the standard.** There is
/// now a live path (`POST /api/insights/ecg`) behind a device-local switch that
/// starts OFF, so the surface has gained a second, actionable reason to be
/// empty. The two new keys join ``emptyStateKeys`` rather than sitting outside
/// it: everything below — no phantom sync, no dated promise, no assessment —
/// must hold for them too.
///
/// This suite pins the copy against four ways it could rot back:
///
/// 1. **No phantom sync.** The copy may not describe an automatic transfer.
/// 2. **The honest distinction survives.** "Nothing uploaded yet" and "this
///    device cannot record ECGs" are different facts and must stay separate;
///    the hardware sentence stays calm — no error framing, no hardware sales
///    pitch.
/// 3. **The path that works today is named and walkable.** Apple Health →
///    `export.zip` → Einstellungen → Apple-Health-Import, with a route
///    (``AppRouter/requestAppleHealthImport()``) rather than only a description.
/// 4. **The non-diagnostic framing holds.** Nothing on this branch interprets,
///    classifies, measures or judges; the permanent disclaimer and the
///    non-normal clinician note on the populated branch stay intact.
///
/// Reads the checked-in catalog JSON directly rather than through
/// `Bundle.localizedString` — a missing translation resolves to its own key
/// there, which would hide exactly the drift this guards (same rationale as the
/// sibling i18n guards, see ``ParityCatalog``). That loader anchors on the
/// CALLER's `#filePath`, which is why this suite lives in `i18n/` next to them
/// rather than under `Screens/Insights/`.
@Suite("CU-37 — EKG-Leerzustand ist ehrlich")
struct EcgEmptyStateHonestyTests {
    // MARK: - Fixtures

    /// Every key the empty branch renders.
    static let emptyStateKeys = [
        "insights.ecg.empty.title",
        "insights.ecg.empty.body",
        "insights.ecg.empty.pathTitle",
        "insights.ecg.empty.pathStep1",
        "insights.ecg.empty.pathStep2",
        "insights.ecg.empty.pathStep3",
        "insights.ecg.empty.cta",
        "insights.ecg.empty.hardwareNote",
        // GH #74 — the third reason the surface can be empty, and the only one
        // with an action behind it. Joins the list rather than sitting outside
        // it, so every guard below (no phantom sync, no dated promise, no
        // assessment) covers it too.
        "insights.ecg.empty.uploadOff",
        "insights.ecg.empty.uploadOffCta"
    ]

    private func value(_ key: String, _ language: String) throws -> String {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings[key], "\(key) fehlt im Katalog")
        return try #require(ParityCatalog.value(entry, language: language), "\(key)/\(language) leer")
    }

    // MARK: - Catalog presence

    @Test("Alle Leerzustand-Keys sind in DE und EN gefüllt")
    func keysArePresentInBothLocales() throws {
        for key in Self.emptyStateKeys {
            for language in ["de", "en"] {
                let text = try value(key, language)
                #expect(!text.isEmpty, "\(key)/\(language) ist leer")
            }
        }
    }

    // MARK: - 1. No phantom sync

    @Test("Der Leerzustand behauptet keine automatische Übertragung mehr")
    func noPhantomSyncClaim() throws {
        // The exact claim that was there before CU-37, plus the family of
        // wordings a well-meaning copy edit would reach for next.
        let forbidden: [(language: String, needles: [String])] = [
            ("de", ["synchronisiert", "synchronisieren", "wird übertragen", "automatisch übertragen"]),
            ("en", ["sync from", "syncs from", "are synced", "automatically transferred"])
        ]
        for key in Self.emptyStateKeys {
            for group in forbidden {
                let text = try value(key, group.language).lowercased()
                for needle in group.needles {
                    #expect(
                        !text.contains(needle.lowercased()),
                        "\(key)/\(group.language) verspricht eine Übertragung, die es nicht gibt: '\(needle)'"
                    )
                }
            }
        }
    }

    @Test("Der Rumpf benennt die Ursache: nichts hochgeladen, nicht: nichts vorhanden")
    func bodyNamesTheRealCause() throws {
        let de = try value("insights.ecg.empty.body", "de")
        let en = try value("insights.ecg.empty.body", "en")
        // The load-bearing half-sentence: the absence is an upload gap, and the
        // copy explicitly denies the wrong reading.
        #expect(de.contains("nicht, weil keine existiert"))
        #expect(en.lowercased().contains("not because none exists"))
        // …and it states plainly that the app does not fetch them itself.
        #expect(de.contains("Apple Health"))
        #expect(en.contains("Apple Health"))
    }

    @Test("Kein Versprechen mit Datum — der Live-Sync wird nirgends terminiert")
    func noDatedPromise() throws {
        // GH #74 is unscheduled. A "coming in <version/date>" line would be a
        // commitment nobody made.
        let forbidden = [
            "demnächst", "in kürze", "bald", "geplant für", "ab version", "kommt mit",
            "coming soon", "shortly", "planned for", "in a future release", "will soon"
        ]
        for key in Self.emptyStateKeys {
            for language in ["de", "en"] {
                let text = try value(key, language).lowercased()
                for needle in forbidden {
                    #expect(!text.contains(needle), "\(key)/\(language) verspricht einen Termin: '\(needle)'")
                }
                // No bare year either ("ab 2026").
                #expect(
                    text.range(of: #"\b20\d{2}\b"#, options: .regularExpression) == nil,
                    "\(key)/\(language) nennt eine Jahreszahl"
                )
            }
        }
    }

    // MARK: - 2. The hardware case is separate and calm

    @Test("Fehlende EKG-Hardware ist ein eigener, ruhiger Satz — kein Fehler")
    func hardwareNoteIsCalmAndSeparate() throws {
        let de = try value("insights.ecg.empty.hardwareNote", "de")
        let en = try value("insights.ecg.empty.hardwareNote", "en")
        // Explicitly de-escalated.
        #expect(de.contains("kein Fehler"))
        #expect(en.lowercased().contains("not an error"))
        // The distinction is only honest if the two facts live in two strings —
        // the body must not absorb the hardware case.
        let body = try value("insights.ecg.empty.body", "de")
        #expect(!body.contains("Apple Watch"), "Hardware-Fall gehört nicht in den Ursachen-Satz")
    }

    @Test("Kein Kaufaufruf für Hardware")
    func hardwareNoteDoesNotSell() throws {
        let forbidden = [
            "kauf", "erwerben", "anschaffen", "hol dir", "besorg", "upgrade",
            "buy", "purchase", "get an apple watch", "you need an"
        ]
        for language in ["de", "en"] {
            let text = try value("insights.ecg.empty.hardwareNote", language).lowercased()
            for needle in forbidden {
                #expect(!text.contains(needle), "Hardware-Hinweis (\(language)) verkauft: '\(needle)'")
            }
        }
    }

    // MARK: - 3. The path that works today

    @Test("Die drei Schritte benennen den heute funktionierenden Weg")
    func pathNamesTheWorkingRoute() throws {
        let step1De = try value("insights.ecg.empty.pathStep1", "de")
        let step2De = try value("insights.ecg.empty.pathStep2", "de")
        let step1En = try value("insights.ecg.empty.pathStep1", "en")
        let step2En = try value("insights.ecg.empty.pathStep2", "en")
        // Step 1 is the Health.app archive export…
        #expect(step1De.contains("export.zip"))
        #expect(step1En.contains("export.zip"))
        // …step 2 is the destination inside this app, named as it is labelled.
        #expect(step2De.contains("Apple-Health-Import"))
        #expect(step2De.contains("Einstellungen"))
        #expect(step2En.lowercased().contains("apple health import"))
        #expect(step2En.contains("Settings"))
    }

    // MARK: - GH #74 — die zweite Ursache, und ihr Absprung

    @MainActor
    @Test("Der Schalter-Absprung landet auf Mehr → Einstellungen → Integrationen → Apple Health")
    func uploadOffCtaRoutesToTheSwitch() {
        // UI-Standard R4: „das schaltest du woanders ein" ist als Satz
        // verboten; an seiner Stelle steht der Weg dorthin. Und zwar auf DIE
        // Seite, die den Schalter trägt — nicht auf die Integrationsliste, wo
        // der Nutzer noch einmal raten müsste.
        let router = AppRouter()
        router.requestAppleHealthSettings()
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 3)
    }

    @Test("Der Schalter-Satz benennt den Zustand, ohne über EKGs zu urteilen")
    func uploadOffCopyNamesTheCondition() throws {
        let de = try value("insights.ecg.empty.uploadOff", "de")
        let en = try value("insights.ecg.empty.uploadOff", "en")
        // Er sagt, was AUS ist — nicht, dass etwas fehlt oder kaputt ist.
        #expect(de.lowercased().contains("ausgeschaltet"))
        #expect(en.lowercased().contains("switched off"))
        // Und er bleibt bei Apple Health als Quelle, wie der Rumpf.
        #expect(de.contains("Apple Health"))
        #expect(en.contains("Apple Health"))
        // Der Absprung ist ein Ziel, kein Satz über einen Ort.
        let cta = try value("insights.ecg.empty.uploadOffCta", "de")
        #expect(cta.count <= 40, "eine Beschriftung, kein Wegweiser-Satz")
    }

    @MainActor
    @Test("requestAppleHealthImport landet auf Mehr → Einstellungen → Integrationen → Apple-Health-Import")
    func ctaRoutesToTheArchiveImport() {
        let router = AppRouter()
        router.requestAppleHealthImport()
        #expect(router.selectedTab == .more)
        // .root THEN .integrations THEN .appleHealthImport — the back stack
        // retraces the real IA instead of dropping the operator into a screen
        // with no context.
        #expect(router.morePath.count == 3)
    }

    // MARK: - 4. Non-diagnostic framing (unchanged, and not weakened here)

    @Test("Der Leerzustand deutet, misst und bewertet nichts")
    func emptyStateMakesNoAssessment() throws {
        let forbidden: [(language: String, needles: [String])] = [
            ("de", [
                "diagnose",
                "diagnostiz",
                "risiko",
                "befund",
                "auswert",
                "interpretier",
                "vorhofflimmern",
                "intervall",
                "auffällig",
                "unauffällig"
            ]),
            ("en", ["diagnos", "risk", "interpret", "atrial", "interval", "abnormal", "normal rhythm"])
        ]
        for key in Self.emptyStateKeys {
            for group in forbidden {
                let text = try value(key, group.language).lowercased()
                for needle in group.needles {
                    #expect(
                        !text.contains(needle),
                        "\(key)/\(group.language) urteilt über EKGs: '\(needle)'"
                    )
                }
            }
        }
    }

    @Test("Die Zuschreibung der bestückten Fläche bleibt — wer das Urteil erzeugt hat")
    func populatedSurfaceKeepsItsDisclaimer() throws {
        // CU-37 rewrote only the empty branch. Der Block wird von
        // `EcgDisclaimerBlock` auf jeder bestückten EKG-Fläche nicht-abweisbar
        // gerendert.
        //
        // UI-Standard R17 (U1): was der Satz trägt, ist die URHEBERSCHAFT des
        // Urteils — es stammt vom Aufzeichnungsgerät, und HealthLog liest die
        // Kurve nicht. Genau das wird hier festgenagelt. Der angehängte
        // Pauschalteil („und stellt keine Diagnose") ist gefallen; er lebt am
        // Ack-Sheet und in Einstellungen → Über diese App. Der Satz „nicht
        // interpretieren" ist die stärkere und konkretere Aussage — er sagt,
        // was HealthLog nicht tut, statt allgemein zu verneinen.
        let de = try value("insights.ecg.disclaimer", "de")
        #expect(de.contains("Aufzeichnungsgerät"))
        #expect(de.contains("interpretiert EKG-Aufzeichnungen nicht"))
        #expect(!de.contains("keine Diagnose"), "R15 — der Pauschal-Schwanz darf nicht zurückkehren")
        let en = try value("insights.ecg.disclaimer", "en")
        #expect(en.lowercased().contains("does not read or interpret"))
        #expect(!en.lowercased().contains("does not provide a diagnosis"))
        // …and the "discuss with a clinician" line still exists and still hangs
        // exclusively on a NON-NORMAL device verdict.
        #expect(try !value("insights.ecg.clinicianNote", "de").isEmpty)
        #expect(EcgPresentation.showsClinicianNote(for: .irregular))
        #expect(EcgPresentation.showsClinicianNote(for: .inconclusive))
        #expect(!EcgPresentation.showsClinicianNote(for: .notDetected))
    }

    // MARK: - The import status block speaks the same language

    @Test("Die EKG-Zähler im Import-Status sind lokalisiert und zählen nur")
    func importStatusEcgCopyIsLocalizedAndNeutral() throws {
        // Server v1.34.1 `result.ecg` — see `AppleHealthImportEcgResultTests`
        // for the wire contract. The screen reports what the IMPORTER did; it
        // must never start describing what a recording SAYS, because the
        // device's verdict belongs on the ECG surface and nowhere else.
        let keys = [
            "settings.applehealth_import.ecg_heading",
            "settings.applehealth_import.ecg_none",
            "settings.applehealth_import.ecg_discovered",
            "settings.applehealth_import.ecg_imported",
            "settings.applehealth_import.ecg_updated",
            "settings.applehealth_import.ecg_skipped",
            "settings.applehealth_import.ecg_failed"
        ]
        for key in keys {
            for language in ["de", "en"] {
                let text = try value(key, language)
                #expect(!text.isEmpty)
                for needle in ["diagnos", "risiko", "risk", "befund", "vorhofflimmern", "atrial", "rhythm"] {
                    #expect(
                        !text.lowercased().contains(needle),
                        "\(key)/\(language) urteilt statt zu zählen: '\(needle)'"
                    )
                }
            }
        }
    }
}
