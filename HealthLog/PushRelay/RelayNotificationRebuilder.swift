import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif

// **#190 5.3 — every remote notification is rebuilt from the envelope.**
//
// With envelope mode on, nothing outside `e` is trusted: not the title, the
// body, the category, the thread, the interruption level, nor any key in
// `userInfo`. The extension starts from an empty content with a neutral
// placeholder and no category, opens the envelope, and only then sets fields,
// each from the plaintext. A push that does not open stays the placeholder.

public enum RelayNotificationRebuilder {
    /// The key APNs payloads carry the envelope under.
    public static let envelopeKey = "e"
    /// Set on every rebuilt `userInfo`, so the app can tell it from a legacy one.
    public static let verifiedKey = "relayEnvelopeId"

    /// Opens the envelope in `userInfo` for `pushClass`, recording the id in
    /// the replay store.
    public static func open(
        userInfo: [AnyHashable: Any],
        pushClass: RelayPushClass,
        keyring: RelayKeyring,
        replayStore: RelayReplayStoring,
        now: Date = .now
    ) -> Result<RelayPlaintext, RelayEnvelopeError> {
        guard let text = userInfo[envelopeKey] as? String,
              let envelope = Data(relayBase64URL: text) else { return .failure(.malformed) }
        // Before first unlock the keychain does not answer: nothing opens.
        // D1 (12): one read, so token and keys come from the same state.
        guard let state = keyring.state(), let token = state.apnsToken else { return .failure(.authFailure) }
        do {
            let plaintext = try RelayEnvelope.open(
                envelope,
                recipientKeys: state.openingRecipients(now: now),
                trustedSenders: state.openingSenders,
                apnsToken: token,
                expectedClass: pushClass,
                now: Int64(now.timeIntervalSince1970),
                replayStore: replayStore
            )
            return .success(plaintext)
        } catch {
            return .failure(error)
        }
    }

    /// The route a plaintext names. Targets come from `t` and the ids inside
    /// the plaintext, never from a URL the push carries.
    public static func target(of plaintext: RelayPlaintext) -> String? {
        guard let medicationId = plaintext.data?["medicationId"]?.stringValue,
              medicationId.count <= 64,
              medicationId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return "medication:\(medicationId)"
    }

    /// `userInfo` built only from the plaintext: the template as `eventType`,
    /// the envelope id, and the scalar fields of `d`. `deepLink` and `url` are
    /// never copied; a slot's `scheduledAt` becomes `scheduledFor`.
    public static func userInfo(from plaintext: RelayPlaintext) -> [String: Any] {
        var info: [String: Any] = ["eventType": plaintext.type, verifiedKey: plaintext.id]
        if case let .object(fields)? = plaintext.data {
            for (key, value) in fields where !["deepLink", "url", "eventType", verifiedKey].contains(key) {
                switch value {
                case .string, .number, .bool: info[key] = value.propertyListValue
                default: break
                }
            }
            // §7: the slot of a dose reminder is `d.scheduledAt`; the action
            // handler reads it as `scheduledFor`.
            if let scheduledAt = fields["scheduledAt"]?.stringValue ?? fields["slot"]?["scheduledAt"]?.stringValue,
               info["scheduledFor"] == nil
            {
                info["scheduledFor"] = scheduledAt
            }
        }
        // §7: a discreet `REMINDER` with a medication and a slot is a dose
        // reminder; the app's actions and routes know it by that name.
        if RelayTemplate.isDoseReminder(plaintext) {
            info["eventType"] = RelayTemplate.medicationReminder
        }
        // #191: a security alert (also as discreet `REMINDER` with
        // `securityKind`) opens the security settings. The route comes from
        // the template, never from a URL in the push.
        if RelayTemplate.isSecurityAlert(plaintext) {
            info["eventType"] = RelayTemplate.securityAlert
            info["url"] = RelayTemplate.securitySettingsPath
        }
        return info
    }

    #if canImport(UserNotifications)
        /// A fresh content with only the placeholder: no category, no thread,
        /// no `userInfo`, quiet.
        public static func placeholder(title: String, body: String) -> UNMutableNotificationContent {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.interruptionLevel = .passive
            return content
        }

        /// The opened content. Time Sensitive is only ever set here, after the
        /// envelope opened (#190: never from plaintext, never by default).
        public static func content(
            for plaintext: RelayPlaintext,
            placeholderTitle: String,
            placeholderBody: String,
            secretCategory: (String) -> String?
        ) -> UNMutableNotificationContent {
            let content = placeholder(title: placeholderTitle, body: placeholderBody)
            // D1 (13): a template v1 does not know stays the placeholder.
            guard RelayTemplate.isKnownAlert(plaintext.type) else { return content }
            if let title = plaintext.title, !title.isEmpty { content.title = title }
            if let body = plaintext.body, !body.isEmpty { content.body = body }
            if let thread = plaintext.thread { content.threadIdentifier = thread }
            content.interruptionLevel = interruptionLevel(plaintext.level, type: plaintext.type)
            if content.interruptionLevel != .passive || plaintext.json["ui"]?["sound"]?.stringValue == "default" {
                content.sound = .default
            }
            // The actions of a dose reminder live under the random per-install
            // id; a plaintext push naming `MEDICATION_REMINDER` gets none.
            if plaintext.category != nil, RelayTemplate.isDoseReminder(plaintext),
               let secret = secretCategory(RelayTemplate.medicationReminder)
            {
                content.categoryIdentifier = secret
            }
            content.userInfo = userInfo(from: plaintext)
            return content
        }

        /// §8: `passive`, `active`, `time-sensitive` (the latter only for
        /// the four templates that may carry it); anything else is `active`.
        static func interruptionLevel(_ raw: String?, type: String) -> UNNotificationInterruptionLevel {
            switch RelayTemplate.level(raw, type: type) {
            case .passive: .passive
            case .timeSensitive: .timeSensitive
            case .active, nil: .active
            }
        }
    #endif

    /// The ledger entry for an opened notification.
    public static func ledgerEntry(
        for plaintext: RelayPlaintext,
        requestId: String?,
        pushClass: RelayPushClass,
        now: Date = .now
    ) -> RelayOpenedLedger.Entry {
        RelayOpenedLedger.Entry(
            requestId: requestId,
            envelopeId: plaintext.id,
            type: plaintext.type,
            pushClass: pushClass,
            target: target(of: plaintext),
            openedAt: now
        )
    }
}

/// **#189 over the relay: the one place an opened
/// `MEDICATION_INTAKE_RECORDED` becomes the payload the intake handler
/// reads** (`IntakeRecordedHandling.handle(payload:content:deliver:)`, field
/// names of #191: `medicationId`, `intakeId`, `slotInstant`, `outcome`,
/// `takenAt`, `takenVia`). The relay's golden vector still spells the slot
/// `slot.scheduledAt` and the source `source` and has no `outcome`; those are
/// mapped too, and a take with a time but no outcome counts as `taken`.
public enum RelayIntakeBridge {
    public static let template = "MEDICATION_INTAKE_RECORDED"

    public static func payload(from plaintext: RelayPlaintext) -> [AnyHashable: Any]? {
        guard plaintext.type == template, let data = plaintext.data,
              let medicationId = data["medicationId"]?.stringValue else { return nil }
        var info: [AnyHashable: Any] = [
            "eventType": template,
            "medicationId": medicationId,
            RelayNotificationRebuilder.verifiedKey: plaintext.id
        ]
        if let instant = data["slotInstant"]?.stringValue ?? data["slot"]?["scheduledAt"]?.stringValue
            ?? data["slot"]?["instant"]?.stringValue
        {
            info["slotInstant"] = instant
        }
        let takenAt = data["takenAt"]?.stringValue
        if let takenAt { info["takenAt"] = takenAt }
        if let via = data["takenVia"]?.stringValue ?? data["source"]?.stringValue { info["takenVia"] = via }
        if let outcome = data["outcome"]?.stringValue ?? (takenAt == nil ? nil : "taken") { info["outcome"] = outcome }
        if let intakeId = data["intakeId"]?.stringValue { info["intakeId"] = intakeId }
        return info
    }
}
