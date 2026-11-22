#if DEBUG
    import Foundation

    /// **1.5 KONTO — a 1.46 server for the screenshot sweep.** Under
    /// `-uitest-konto` the fixture server reports version 1.46.6, a 14-day
    /// deletion grace window and a Fitbit connection Google turned off, so the
    /// sweep can photograph the deletion copy with a grace window and the
    /// Fitbit notice. `-uitest-konto-deletion-pending` makes the password
    /// sign-in answer `403 auth.account.deletion_pending` with a date. `nil`
    /// everywhere else: without the argument nothing changes.
    enum KontoFixtures {
        static let argument = "-uitest-konto"
        static let deletionPendingArgument = "-uitest-konto-deletion-pending"

        static func response(forPath path: String) -> (status: Int, body: Data)? {
            guard ProcessInfo.processInfo.arguments.contains(argument) else { return nil }
            let body: String? = switch path {
            case "/api/version": #"{"data":{"version":"1.46.6"},"error":null}"#
            case "/api/settings/privacy-summary":
                #"{"data":{"retention":{"coachMessagesDays":365,"auditLogDays":365,"deliveryLogDays":90,"accountDeletionGraceDays":\#(graceDays)}},"error":null}"#
            case "/api/integrations/status":
                #"{"data":{"threshold":3,"metricFreshnessDegraded":false,"integrations":[{"integration":"fitbit","connected":true,"#
                    + #""retirement":{"endsOn":"2026-10-30","ended":true,"successor":"google-health","offered":true}}]},"error":null}"#
            case "/api/fitbit/status": #"{"connected":true,"configured":true}"#
            default: nil
            }
            return body.map { (200, Data($0.utf8)) }
        }

        /// The grace window the privacy summary reports.
        static let graceDays = 14

        /// The password sign-in of an account locked for deletion. The purge
        /// date is the grace window from today, the same date the deletion and
        /// reset sheets of the same run compute.
        static func loginResponse() -> (status: Int, body: Data)? {
            guard ProcessInfo.processInfo.arguments.contains(deletionPendingArgument) else { return nil }
            let purge = Calendar.current.date(byAdding: .day, value: graceDays, to: .now) ?? .now
            let purgeAt = purge.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            let body = #"{"data":null,"error":"Account pending deletion","#
                + #""meta":{"errorCode":"auth.account.deletion_pending","purgeAt":"\#(purgeAt)"}}"#
            return (403, Data(body.utf8))
        }
    }
#endif
