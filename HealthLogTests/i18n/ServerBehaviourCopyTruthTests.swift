import Foundation
import Testing

/// **CU-26 (Catch-up v1.34) — the copy must not out-live the server behaviour
/// it describes.**
///
/// Three server changes landed between v1.33.0 and v1.34.1 that alter what is
/// *true* about surfaces the app talks about. This suite pins the catalog to
/// the post-change truth so a later copy edit cannot quietly reinstate a claim
/// the server stopped honouring.
///
/// - **B1 — `notificationPrefs.<category>.clientManaged`.** Until v1.33.1 the
///   flag suppressed the *entire* dispatch; a user who flipped it also lost
///   Telegram, ntfy, webhook, email and Web Push. Since v1.33.1 the gate sits
///   next to the channel loop (`lib/notifications/client-managed-apns.ts`) and
///   suppresses the **APNs leg only**. iOS surfaces the flag on exactly one
///   card — Settings → Benachrichtigungen → Vorsorge-Erinnerung — so that card
///   is where the truth has to be stated.
/// - **B5 — `DELETE /api/dashboard/widgets`.** Since v1.34.0 the reset keeps
///   the comparison baseline, chart overlays, selected score rings and hero-ring
///   order. Copy may promise the tile order + visibility it still restores, and
///   nothing wider.
/// - **B3 / B4 / B6 — cron dedupe, profile-timezone rendering, per-slot
///   `apns-collapse-id`.** These are server-internal and iOS carries no copy
///   about them. The sweeps below keep it that way; in particular GH #50 records
///   that iOS renders instants in the **device** zone while the web uses the
///   **profile** zone, and that this divergence is deliberate — so no iOS copy
///   may promise the two agree.
///
/// Reads the checked-in catalog JSON directly (same rationale as the sibling
/// guards — see ``ParityCatalog``): a missing translation resolves to its key
/// through `Bundle.localizedString`, which would hide exactly this drift.
@Suite("CU-26 — Copy entspricht dem Server-Verhalten v1.34.x")
struct ServerBehaviourCopyTruthTests {
    // MARK: - B1 — client-managed suppresses APNs only

    /// The relay channels the v1.33.1 gate stopped suppressing. The footer has
    /// to name them, because a user who used the switch as a blanket mute is
    /// exactly the user who is now getting them again.
    static let relayChannels: [(de: String, en: String)] = [
        ("Telegram", "Telegram"),
        ("ntfy", "ntfy"),
        ("Webhook", "webhook"),
        ("E-Mail", "email"),
        ("Web Push", "Web Push")
    ]

    @Test("Vorsorge-Footer nennt die Kanäle, die der APNs-Gate nicht mehr stummschaltet")
    func measurementReminderFooterNamesRelayChannels() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(
            catalog.strings["measurement.reminder.footer"],
            "measurement.reminder.footer fehlt im Katalog"
        )
        let de = try #require(ParityCatalog.value(entry, language: "de"))
        let en = try #require(ParityCatalog.value(entry, language: "en"))
        for channel in Self.relayChannels {
            #expect(
                de.contains(channel.de),
                "DE-Footer nennt \(channel.de) nicht — seit v1.33.1 liefert der Kanal wieder"
            )
            #expect(
                en.localizedCaseInsensitiveContains(channel.en),
                "EN footer omits \(channel.en) — the channel delivers again since v1.33.1"
            )
        }
    }

    @Test("Vorsorge-Footer beschränkt die Unterdrückung ausdrücklich auf Apple-Push")
    func measurementReminderFooterScopesSuppressionToApplePush() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings["measurement.reminder.footer"])
        let de = try #require(ParityCatalog.value(entry, language: "de"))
        let en = try #require(ParityCatalog.value(entry, language: "en"))
        #expect(de.contains("Apple-Geräten"), "DE-Footer grenzt die Unterdrückung nicht auf Apple-Push ein")
        #expect(
            en.localizedCaseInsensitiveContains("Apple devices"),
            "EN footer does not scope the suppression to the Apple push"
        )
    }

    @Test("Vorsorge-Footer verschweigt nicht, dass die App keine eigene Erinnerung plant")
    func measurementReminderFooterAdmitsNoLocalFallback() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings["measurement.reminder.footer"])
        let de = try #require(ParityCatalog.value(entry, language: "de"))
        let en = try #require(ParityCatalog.value(entry, language: "en"))
        // There is no `UNCalendarNotificationTrigger` for MEASUREMENT_REMINDER
        // anywhere in the app (unlike mood + low-supply), so the switch trades
        // the Apple push for nothing. Copy that hides this would send a user
        // into silence believing the app took over.
        #expect(de.contains("keine eigene Erinnerung"), "DE-Footer verschweigt den fehlenden lokalen Ersatz")
        #expect(
            en.localizedCaseInsensitiveContains("no reminder of its own"),
            "EN footer hides that the app schedules no local replacement"
        )
    }

    @Test("Vorsorge-Schalter verspricht nicht länger schlicht „Erinnerungen“")
    func measurementReminderToggleLabelIsNotAPlainOptIn() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings["measurement.reminder.toggle.label"])
        let de = try #require(ParityCatalog.value(entry, language: "de"))
        let en = try #require(ParityCatalog.value(entry, language: "en"))
        // `clientManaged = true` is a suppression, not an opt-in: a label that
        // reads as "reminders: on" states the inverse of what the flag does.
        #expect(de != "Erinnerungen", "DE-Label liest sich als Opt-in, der Schalter unterdrückt aber")
        #expect(en != "Reminders", "EN label reads as an opt-in while the switch suppresses")
    }

    // MARK: - B5 — dashboard reset keeps more than it used to

    @Test("Dashboard-Reset-Copy verspricht nur Reihenfolge + Sichtbarkeit")
    func dashboardResetCopyPromisesOnlyOrderAndVisibility() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(
            catalog.strings["Restores the default order and visibility."],
            "Dashboard-Reset-Footer fehlt im Katalog"
        )
        let de = try #require(ParityCatalog.value(entry, language: "de"))
        let en = try #require(ParityCatalog.value(entry, language: "en"))
        // Since v1.34.0 the DELETE keeps comparison baseline, chart overlays,
        // selected score rings and hero-ring order — so an "everything" claim
        // would be false.
        for forbidden in ["alles", "alle Einstellungen"] {
            #expect(
                !de.localizedCaseInsensitiveContains(forbidden),
                "DE-Reset-Copy behauptet „\(forbidden)“ — seit v1.34.0 bleibt vieles erhalten"
            )
        }
        for forbidden in ["everything", "all settings"] {
            #expect(
                !en.localizedCaseInsensitiveContains(forbidden),
                "EN reset copy claims \"\(forbidden)\" — v1.34.0 preserves much of it"
            )
        }
    }

    // MARK: - B4 / B6 — catalog-wide sweeps for claims iOS must not make

    /// Phrases that would contradict a server behaviour iOS deliberately does
    /// not mirror. Each is absent today; the sweep keeps re-introduction from
    /// passing silently.
    static let forbiddenClaims: [(needle: String, rationale: String)] = [
        (
            "Profil-Zeitzone",
            "GH #50 — iOS rendert in der Geräte-Zeitzone, das Web in der Profil-Zeitzone; die Divergenz ist gewollt"
        ),
        (
            "profile time zone",
            "GH #50 — iOS renders in the device zone by design"
        ),
        (
            "profile timezone",
            "GH #50 — iOS renders in the device zone by design"
        ),
        (
            "wie im Web",
            "GH #50 — iOS und Web zeigen für denselben Instant bewusst unterschiedliche Wanduhrzeiten"
        ),
        (
            "same as the web",
            "GH #50 — the two clients deliberately differ in wall-clock rendering"
        ),
        (
            "als eine Nachricht",
            "v1.34.1 — die APNs-Sammel-ID wird pro Slot gebildet; mehrere Medikamente kommen einzeln an"
        ),
        (
            "as a single notification",
            "v1.34.1 — apns-collapse-id is keyed per slot, so several meds arrive separately"
        )
    ]

    @Test("Kein Katalog-Wert behauptet ein Server-Verhalten, das es nicht gibt")
    func catalogMakesNoContradictedClaims() throws {
        let catalog = try ParityCatalog.load()
        var offenders: [String] = []
        for (key, entry) in catalog.strings {
            for language in ["de", "en"] {
                guard let value = ParityCatalog.value(entry, language: language) else { continue }
                for claim in Self.forbiddenClaims where value.localizedCaseInsensitiveContains(claim.needle) {
                    offenders.append("\(key) [\(language)] → „\(claim.needle)“ — \(claim.rationale)")
                }
            }
        }
        #expect(offenders.isEmpty, "Widersprüchliche Copy gefunden:\n\(offenders.joined(separator: "\n"))")
    }
}
