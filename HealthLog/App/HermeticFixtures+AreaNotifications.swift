#if DEBUG
    import Foundation

    /// **iOS 1.4 B4-c — the notification settings a fresh account has.**
    ///
    /// The notifications screen reads its channels, their delivery state and the
    /// three relay configurations. All of them fell through to the shared default
    /// `{}`, which none of their DTOs decode, so the B2-b pictures carried an
    /// error dialog over the screen and a red line under ntfy and Telegram. These
    /// are the answers a server gives an account that has push on this iPhone
    /// and has not set up any relay: one APNs channel, every event on, ntfy,
    /// Telegram and webhook switched off, all services available. `nil` for
    /// every other route.
    enum AreaNotificationsFixtures {
        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard method == "GET" else { return nil }
            return switch path {
            case "/api/notifications/preferences": ok(preferencesJSON)
            case "/api/notifications/status": ok(statusJSON)
            case "/api/settings/ntfy": ok(#"{"enabled":false,"serverUrl":"https://ntfy.sh","topic":"","hasAuthToken":false}"#)
            case "/api/settings/telegram": ok(#"{"enabled":false,"hasBotToken":false,"chatId":null}"#)
            case "/api/settings/webhook":
                ok(#"{"enabled":false,"url":"","headerName":"","hasHeaderValue":false,"format":"generic"}"#)
            case "/api/settings/global-services": ok(#"{"telegramGlobal":true,"ntfyGlobal":true,"webPushGlobal":true}"#)
            default: nil
            }
        }

        private static func ok(_ json: String) -> (Int, Data) {
            (200, Data(json.utf8))
        }

        static let channelID = "area-channel-apns"

        static let eventTypes = ["DAILY_BRIEFING", "MEDICATION_REMINDER", "PERSONAL_RECORD", "SYSTEM_ALERT"]

        static var preferencesJSON: String {
            let preferences = eventTypes.map {
                #"{"channelId":"\#(channelID)","eventType":"\#($0)","enabled":true}"#
            }
            return """
            {
              "channels": [
                { "id": "\(channelID)", "type": "APNS", "label": "iPhone", "enabled": true, "globallyEnabled": true }
              ],
              "preferences": [\(preferences.joined(separator: ","))],
              "eventTypes": [\(eventTypes.map { "\"\($0)\"" }.joined(separator: ","))],
              "mood": { "reminderHour": 20 }
            }
            """
        }

        static let statusJSON = """
        {
          "channels": [
            { "id": "\(channelID)", "type": "APNS", "label": "iPhone", "enabled": true, "state": "active",
              "disabledReason": null, "consecutiveFailures": 0, "lastSuccessAt": null,
              "lastFailureAt": null, "lastFailureReason": null, "nextRetryAt": null }
          ]
        }
        """
    }
#endif
