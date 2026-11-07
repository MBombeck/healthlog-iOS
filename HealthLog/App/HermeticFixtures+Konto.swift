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
                #"{"data":{"retention":{"coachMessagesDays":365,"auditLogDays":365,"deliveryLogDays":90,"accountDeletionGraceDays":14}},"error":null}"#
            case "/api/integrations/status":
                #"{"data":{"threshold":3,"metricFreshnessDegraded":false,"integrations":[{"integration":"fitbit","connected":true,"#
                    + #""retirement":{"endsOn":"2026-10-30","ended":true,"successor":"google-health","offered":true}}]},"error":null}"#
            case "/api/fitbit/status": #"{"connected":true,"configured":true}"#
            default: nil
            }
            return body.map { (200, Data($0.utf8)) }
        }

        /// The password sign-in of an account locked for deletion.
        static func loginResponse() -> (status: Int, body: Data)? {
            guard ProcessInfo.processInfo.arguments.contains(deletionPendingArgument) else { return nil }
            let body = #"{"data":null,"error":"Account pending deletion","#
                + #""meta":{"errorCode":"auth.account.deletion_pending","purgeAt":"2026-11-18T09:30:00.000Z"}}"#
            return (403, Data(body.utf8))
        }
    }
#endif
