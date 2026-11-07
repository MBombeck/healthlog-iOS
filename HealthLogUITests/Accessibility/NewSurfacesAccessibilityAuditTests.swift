import XCTest

/// **A11Y (1.5.0, Welle 6b) — the native accessibility audit on every new
/// surface of 1.5.**
///
/// Each case opens one surface from the waves 4b to 4e in the hermetic world
/// the picture sweep uses (`-uitest-marketing`, `-uitest-sweep` and the
/// surface's own fixture argument), brings the new part on screen and runs
/// `performAccessibilityAudit()` for every audit type. A finding fails the
/// case unless one of the exceptions in ``AuditException`` names it, each
/// with its reason. No language-independent label is asserted, so the case
/// runs under whatever `-testLanguage` the gate passes.
///
/// `A11Y_AUDIT_OUT` (forwarded as `TEST_RUNNER_A11Y_AUDIT_OUT`) names a host
/// directory for a screenshot and the system's long description of every
/// finding per surface. Without it nothing is written: the gate log carries
/// only identifiers and element types, never a label with a figure in it.
@MainActor
final class NewSurfacesAccessibilityAuditTests: XCTestCase {
    var app = XCUIApplication()
    /// The size pass of the walk under way (``eachSize(_:)``).
    var size = AuditSize.standard

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Wave 4b

    /// BP-TOD — "Nach Tageszeit" on the blood pressure page.
    func test_bpTimeOfDay() {
        eachSize {
            boot(["-uitest-bp-tod", "-hl.healthkit.serverVersion", "1.47.0"])
            openDeepLink("healthlog://insights/blood-pressure")
            guard reach("insights.bpTimeOfDay", column: 0.96, bottomMargin: 100) else { return }
            audit("bp-time-of-day", owned: "insights.bpTimeOfDay", bottomChrome: 100)
        }
    }

    /// COACH-R — the thinking depth in Settings › Assistant › Erweitert.
    func test_coachReasoningSettings() {
        eachSize {
            boot(["-uitest-coach-r", "-uitest-citations"])
            acceptAIConsent()
            guard openSettingsRow("settings.hub.ai") else { return }
            guard let advanced = probe("settings.ai.advanced") else { return missing("settings.ai.advanced") }
            advanced.tap()
            settle(1.5)
            guard reach("settings.ai.reasoning.option.high") else { return }
            audit("coach-reasoning-settings", owned: "settings.ai.reasoning")
        }
    }

    /// COACH-R — an answer with its plan proposal and the trail link.
    func test_coachAnswerWithProposal() {
        eachSize {
            boot(["-uitest-coach-r", "-uitest-citations"])
            acceptAIConsent()
            openDeepLink("healthlog://coach")
            for id in ["InsightsScreen.askCoachCollapsedCoin.header", "InsightsScreen.enableCoachCoin.header"] {
                let coin = app.buttons[id]
                if coin.waitForExistence(timeout: 6), coin.isHittable {
                    coin.tap()
                    break
                }
            }
            acceptAIConsent()
            let field = app.textFields.firstMatch
            guard field.waitForExistence(timeout: 15) else { return missing("coach input") }
            field.tap()
            field.typeText("Wie habe ich diese Woche geschlafen?")
            let send = app.buttons["Frage senden"]
            guard send.waitForExistence(timeout: 5) else { return missing("send button") }
            send.tap()
            let accept = app.buttons["coach.proposal.accept"]
            guard accept.waitForExistence(timeout: 40) else { return missing("coach.proposal.accept") }
            settle(3)
            // The composer stands fixed above the keyboard; what scrolled
            // under it is not on screen.
            audit("coach-answer-proposal", owned: "coach.", bottomLimit: field.frame.minY - 8)
        }
    }

    /// COACH-R and A11Y — at the largest accessibility size the "AI-generated,
    /// not medical advice" line stands whole in the transcript, above the
    /// composer, instead of cut under it (POLISH-B, "bleibt").
    func test_coachNoteAtLargestText() {
        size = .xxxl
        boot(["-uitest-coach-r", "-uitest-citations"])
        acceptAIConsent()
        openDeepLink("healthlog://coach")
        for id in ["InsightsScreen.askCoachCollapsedCoin.header", "InsightsScreen.enableCoachCoin.header"] {
            let coin = app.buttons[id]
            if coin.waitForExistence(timeout: 6), coin.isHittable {
                coin.tap()
                break
            }
        }
        acceptAIConsent()
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 15) else { return missing("coach input") }
        // The note opens the transcript; an earlier conversation of the
        // hermetic world may stand below it, so the walk goes up.
        let note = element("coach.aiGeneratedNote")
        for _ in 0 ..< 12 where !inTheOpen(note) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
            settle(0.8)
        }
        guard inTheOpen(note) else { return missing("coach.aiGeneratedNote") }
        XCTAssertLessThanOrEqual(note.frame.maxY, field.frame.minY, "The note must stand above the composer")
        audit("coach-note", owned: "coach.aiGeneratedNote")
    }

    /// LIFE — the life circumstances page, then the alcohol section with
    /// AUDIT-C (AUDITC, 4e) and its form.
    func test_lifeCircumstancesAndAuditC() {
        eachSize {
            boot(["-uitest-life"])
            tab("ellipsis")
            guard let aboutMe = probe("more.row.about_me") else { return missing("more.row.about_me") }
            aboutMe.tap()
            settle(2)
            guard let row = probe("aboutMe.row.lifeCircumstances", drags: 25) else { return missing("aboutMe.row.lifeCircumstances") }
            row.tap()
            guard element("life.section.alcohol.header").waitForExistence(timeout: 15) else {
                return missing("life.section.alcohol.header")
            }
            settle(1.5)
            audit("life-circumstances")
            guard let header = probe("life.section.alcohol.header") else { return }
            header.tap()
            guard reach("life.auditC.result") else { return }
            audit("life-auditc-result", owned: "life.auditC")
            guard let start = probe("life.auditC.start") else { return missing("life.auditC.start") }
            start.tap()
            guard reach("life.auditC.item.0") else { return }
            audit("life-auditc-form", owned: "life.auditC")
        }
    }

    /// SUPP — the composition on a supplement's page.
    func test_supplementComposition() {
        eachSize {
            boot(["-uitest-area-meds", "-uitest-supp"])
            tab("pills.fill")
            guard let card = probe("medications.card.supp-med-d3") else { return missing("supp-med-d3") }
            card.tap()
            settle(3)
            let section = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'medications.composition'")).firstMatch
            guard scroll(to: section) else { return missing("medications.composition") }
            audit("supp-composition", owned: "medications.composition")
        }
    }

    // MARK: - Wave 4c

    /// MOVE — "Unterwegs" on the environment page.
    func test_movement() {
        eachSize {
            boot(["-uitest-move"])
            guard openMoreRow("more.row.environment") else { return }
            guard reach("environment.movement.day") else { return }
            audit("movement", owned: "environment.movement")
        }
    }

    /// SYMPTOM — the symptoms of an active episode and the symptom form.
    func test_symptoms() {
        eachSize {
            boot(["-uitest-area-meds", "-uitest-symptom", "-hl.healthkit.serverVersion", "1.47.0"])
            guard openMoreRow("more.row.illness") else { return }
            let episode = app.staticTexts["Bronchitis"].firstMatch
            guard episode.waitForExistence(timeout: 10) else { return missing("Bronchitis episode") }
            episode.tap()
            settle(3)
            guard reach("symptoms.section") else { return }
            audit("symptoms-section", owned: "symptoms")
            guard let add = probe("symptoms.add") else { return missing("symptoms.add") }
            add.tap()
            settle(2)
            audit("symptom-form")
        }
    }

    /// VISIT — the next visit on Vorsorge.
    func test_nextVisit() {
        eachSize {
            boot(["-uitest-visit"])
            guard openMoreRow("more.row.vorsorge") else { return }
            guard reach("visit.next") else { return }
            audit("next-visit", owned: "visit.next")
        }
    }

    /// LAB-OCR — the review list of a read that ran into limits.
    func test_labScanReview() {
        eachSize {
            boot(["-uitest-lab-ocr", "-uitest-lab-ocr-review"])
            guard openMoreRow("more.row.labs") else { return }
            guard let add = probe("labs.toolbar.add") else { return missing("labs.toolbar.add") }
            add.tap()
            settle(1)
            // A menu item: no drag, a drag closes the menu.
            let scan = element("labs.menu.scan")
            guard scan.waitForExistence(timeout: 5) else { return missing("labs.menu.scan") }
            scan.tap()
            settle(3)
            guard reach("labs.scan.review.batchDate") else { return }
            audit("lab-scan-review")
        }
    }

    // MARK: - Wave 4d

    /// DOCS-TRASH — recently deleted documents.
    func test_recentlyDeletedDocuments() {
        eachSize {
            boot(["-uitest-docs-trash"])
            guard openMoreRow("more.row.documents") else { return }
            guard let link = probe("documents.trash.link") else { return missing("documents.trash.link") }
            link.tap()
            settle(3)
            guard reach("documents.trash.restore.trash-del-labor") else { return }
            audit("documents-trash")
        }
    }

    /// SEC — the proof sheet before an MCP key is created.
    func test_stepUpBeforeMCPKey() {
        eachSize {
            boot(["-uitest-sec"])
            guard openSettingsRow("settings.hub.mcp") else { return }
            guard let create = probe("settings.mcp.tokens.create") else { return missing("settings.mcp.tokens.create") }
            create.tap()
            settle(3)
            let field = element("settings.mcp.mint.name")
            guard field.waitForExistence(timeout: 8) else { return missing("settings.mcp.mint.name") }
            field.tap()
            field.typeText("Claude")
            element("settings.mcp.mint.submit").tap()
            guard element("stepUp.record.sheet").waitForExistence(timeout: 8) else { return missing("stepUp.record.sheet") }
            settle(1.5)
            audit("step-up-sheet")
        }
    }

    /// MED-PLUS — treatment courses on the medication page.
    func test_treatmentCourses() {
        eachSize {
            boot(["-uitest-area-meds", "-uitest-med-plus"])
            tab("pills.fill")
            guard let card = probe("medications.card.mkshot-med-lisinopril") else { return missing("lisinopril card") }
            card.tap()
            settle(3)
            guard let advanced = probe("med.courses.advanced") else { return missing("med.courses.advanced") }
            advanced.tap()
            settle(2)
            guard reach("med.courses.row.medplus-course-1") else { return }
            audit("treatment-courses", owned: "med.courses")
        }
    }

    /// MED-PLUS — "automatisch als genommen" in the edit sheet.
    func test_autoMarkTakenSwitch() {
        eachSize {
            boot(["-uitest-area-meds", "-uitest-med-plus"])
            tab("pills.fill")
            guard let card = probe("medications.card.mkshot-med-lisinopril") else { return missing("lisinopril card") }
            card.tap()
            settle(3)
            let edit = app.navigationBars.buttons.matching(
                NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "Edit", "Bearbeiten", "Bewerken")
            ).firstMatch
            guard edit.waitForExistence(timeout: 8) else { return missing("edit button") }
            edit.tap()
            settle(2)
            // The name field opens with the keyboard up; each return moves on
            // to the next field until none is left.
            for _ in 0 ..< 3 where app.keyboards.firstMatch.exists {
                app.typeText("\n")
                settle(0.8)
            }
            let toggle = element("med.edit.autoMarkTaken")
            // "Erweitert" folds the switch away unless it is on.
            if let row = probe("med.edit.advanced"), !(toggle.exists && toggle.isHittable) {
                row.tap()
                settle(1.5)
            }
            guard scroll(to: toggle) else { return missing("med.edit.autoMarkTaken") }
            audit("auto-mark-taken", owned: "med.edit.autoMarkTaken")
        }
    }

    /// LAB-LINES — a lab marker as a line on the weight chart.
    func test_labLine() {
        eachSize {
            boot([
                "-uitest-lab-lines", "-hl.healthkit.serverVersion", "1.47.0",
                "-insights.labOverlay.weight", "lab:bm_hba1c"
            ])
            openDeepLink("healthlog://insights/weight")
            guard reach("insights.labOverlay.chart", column: 0.96, bottomMargin: 100) else { return }
            audit("lab-line", owned: "insights.labOverlay", bottomChrome: 100)
        }
    }

    // MARK: - Wave 4e

    /// SUPP-EDIT — the composition editor.
    func test_compositionEditor() {
        eachSize {
            boot(["-uitest-area-meds", "-uitest-supp", "-uitest-supp-edit"])
            tab("pills.fill")
            guard let card = probe("medications.card.supp-med-d3") else { return missing("supp-med-d3") }
            card.tap()
            settle(3)
            guard let link = probe("medications.composition.edit", drags: 12) else {
                return missing("medications.composition.edit")
            }
            link.tap()
            settle(3)
            audit("composition-editor")
        }
    }

    /// ROUTES — the route switch on the Apple Health page.
    func test_workoutRoutesSwitch() {
        eachSize {
            boot(["-hl.healthkit.serverVersion", "1.47.1"])
            guard openSettingsRow("settings.hub.integrations") else { return }
            guard let health = probe("settings.integrations.appleHealthRow") else { return missing("appleHealthRow") }
            health.tap()
            settle(3)
            guard let advanced = probe("settings.applehealth.advanced", drags: 12) else {
                return missing("settings.applehealth.advanced")
            }
            advanced.tap()
            settle(1.5)
            // The route card in whatever state the hermetic world gives it;
            // its states are rendered in `WorkoutRoutesSettingTests`.
            settle(2)
            audit("workout-routes", owned: "settings.applehealth.advanced,settings.applehealth.routes")
        }
    }

    /// SYNC-TRIG — the sync diagnostics with the server freshness rows.
    func test_syncDiagnostics() {
        eachSize {
            boot(["-hl.healthkit.serverVersion", "1.47.1"])
            guard openSettingsRow("settings.hub.integrations") else { return }
            guard let health = probe("settings.integrations.appleHealthRow") else { return missing("appleHealthRow") }
            health.tap()
            settle(3)
            guard let diagnostics = probe("settings.integrations.hkDiagnosticsRow", drags: 12) else {
                return missing("hkDiagnosticsRow")
            }
            diagnostics.tap()
            settle(3)
            audit("sync-diagnostics")
        }
    }
}
