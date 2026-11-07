import Foundation

/// KONTO (#151, server 1.46.0) — what the server said when it accepted an
/// account deletion or a data wipe, and the one place that turns the deletion
/// grace window into sentences.
///
/// **The contract.** From 1.46.0 the server can keep a grace window
/// (`ACCOUNT_DELETION_GRACE_DAYS`, 14 by default):
/// - `DELETE /api/settings/account` locks the account at once and answers
///   `scheduledPurgeAt`, the day the purge erases it. Until then an admin can
///   undo the deletion. With the window at 0 the account is erased in the
///   request and `scheduledPurgeAt` is `null`.
/// - `DELETE /api/settings/data` keeps a copy of the record first and answers
///   `restorableUntil`; `null` means the wipe was final. A copy that cannot be
///   written refuses with 503 `data_wipe.copy_failed`, and nothing was deleted.
/// - Sign-in to a locked account answers 403 `auth.account.deletion_pending`
///   with `meta.purgeAt`; native SSO redirects with
///   `error=account_deletion_pending`.
///
/// Older servers erase at once and send none of these fields, so every field is
/// optional and a missing one reads as "deleted now" (rule 10).
public struct AccountDeletionReceipt: Sendable, Equatable {
    /// When the purge erases the locked account. `nil`: erased already.
    public let scheduledPurgeAt: Date?

    public init(scheduledPurgeAt: Date?) {
        self.scheduledPurgeAt = scheduledPurgeAt
    }

    /// Reads the success body of `DELETE /api/settings/account`. Tolerant on
    /// purpose: the server already deleted the account when it answered 2xx, so
    /// an empty body (204), a pre-1.46 `{ deleted: true }` or an unreadable
    /// date must never turn the success into an error.
    static func parse(_ body: Data) -> Self {
        Self(scheduledPurgeAt: AccountDeletionWire.dataDate(named: "scheduledPurgeAt", in: body))
    }
}

/// The answer to `DELETE /api/settings/data` (server 1.46.0: `restorableUntil`).
public struct DataWipeReceipt: Sendable, Equatable {
    /// Until when an admin can restore the wiped record. `nil`: final.
    public let restorableUntil: Date?

    public init(restorableUntil: Date?) {
        self.restorableUntil = restorableUntil
    }

    static func parse(_ body: Data) -> Self {
        Self(restorableUntil: AccountDeletionWire.dataDate(named: "restorableUntil", in: body))
    }
}

/// Wire helpers shared by the receipts, the sign-in refusal and the SSO
/// callback.
enum AccountDeletionWire {
    /// `meta.errorCode` of a sign-in to an account pending deletion.
    static let deletionPendingCode = "auth.account.deletion_pending"
    /// `meta.errorCode` of a data wipe whose safety copy could not be written.
    static let copyFailedCode = "data_wipe.copy_failed"
    /// The server version that introduced the grace window.
    static let graceWindowMinimumServerVersion = "1.46.0"

    /// An ISO 8601 instant, with or without fractional seconds. `nil` for
    /// anything else, never a guess.
    static func date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// `data.<name>` of an envelope (or of a bare object, for a proxy that
    /// strips the envelope) as a date, or `nil`.
    static func dataDate(named name: String, in body: Data) -> Date? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let payload = (object["data"] as? [String: Any]) ?? object
        return date(payload[name] as? String)
    }

    /// Whether the connected server keeps a deletion grace window at all.
    /// Unknown counts as no: an older server erases at once, so the
    /// "irreversible" copy stays true for it.
    static func serverHasGraceWindow(defaults: UserDefaults = .standard) -> Bool {
        KnownServerVersion.isAtLeast(graceWindowMinimumServerVersion, defaults: defaults)
    }
}

/// What the confirmation screens may promise before the request: an older
/// server (or a window of 0 days) erases at once, a 1.46 server with a window
/// locks first and erases later.
enum AccountDeletionPolicy: Equatable, Sendable {
    /// Erased in the request: the "cannot be undone" copy is true.
    case immediate
    /// Locked first, erased after `days` (`nil`: the server did not say how long).
    case graceWindow(days: Int?)

    static func resolve(serverHasGraceWindow: Bool, graceDays: Int?) -> Self {
        guard serverHasGraceWindow, graceDays != 0 else { return .immediate }
        return .graceWindow(days: graceDays)
    }

    /// The policy before the window length is known: by server version only.
    static func initial(defaults: UserDefaults = .standard) -> Self {
        resolve(serverHasGraceWindow: AccountDeletionWire.serverHasGraceWindow(defaults: defaults), graceDays: nil)
    }

    var isImmediate: Bool {
        self == .immediate
    }

    /// The day a deletion asked for `now` becomes final, when the window is known.
    func finalDate(from now: Date, calendar: Calendar = .current) -> Date? {
        guard case let .graceWindow(days?) = self else { return nil }
        return calendar.date(byAdding: .day, value: days, to: now)
    }
}

/// The sentences about a deletion with a grace window. Dates are long dates in
/// the interface language.
enum AccountDeletionCopy {
    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(AppLanguage.current.formattingLocale))
    }

    /// Sign-in refused because the account is locked for deletion.
    static func signInRefusal(purgeAt: Date?) -> String {
        guard let purgeAt else { return String(localized: "account.deletionPending.signIn.noDate") }
        return String(localized: "account.deletionPending.signIn \(dateText(purgeAt))")
    }

    /// Shown once after the app deleted the account.
    static func receiptMessage(_ receipt: AccountDeletionReceipt) -> String {
        guard let purgeAt = receipt.scheduledPurgeAt else {
            return String(localized: "account.deleted.receipt.now")
        }
        return String(localized: "account.deleted.receipt.scheduled \(dateText(purgeAt))")
    }

    /// The line under the account deletion's bullets that says whether and
    /// when the deletion becomes final.
    static func deleteFinalLine(_ policy: AccountDeletionPolicy, now: Date = .now) -> String {
        switch policy {
        case .immediate:
            String(localized: "This action cannot be undone.")
        case .graceWindow:
            if let date = policy.finalDate(from: now) {
                String(localized: "deleteAccount.grace.date \(dateText(date))")
            } else {
                String(localized: "deleteAccount.grace.unknown")
            }
        }
    }

    /// The same line for "delete all data", where a copy is kept.
    static func resetFinalLine(_ policy: AccountDeletionPolicy, now: Date = .now) -> String {
        switch policy {
        case .immediate:
            String(localized: "resetData.explain.bullet.irreversible")
        case .graceWindow:
            if let date = policy.finalDate(from: now) {
                String(localized: "resetData.grace.date \(dateText(date))")
            } else {
                String(localized: "resetData.grace.unknown")
            }
        }
    }

    /// The success line of a data wipe.
    static func wipeSuccessMessage(_ receipt: DataWipeReceipt) -> String {
        guard let until = receipt.restorableUntil else { return String(localized: "resetData.success.body") }
        return String(localized: "resetData.success.restorable \(dateText(until))")
    }
}
