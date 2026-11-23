#if DEBUG
    import Foundation

    /// **#191 QoL — the capture sheet's save receipt, photographed.**
    ///
    /// Under `-uitest-capture-receipt` (with `-uitest-sweep`) the fixture
    /// server takes the capture sheet's `POST /api/measurements` and answers
    /// with a saved weight row, and takes the Undo's
    /// `DELETE /api/measurements/{id}`. The receipt words come from what the
    /// sheet sent, so the one fixed row serves every kind. Invented values
    /// only. `nil` for every other route and without the argument.
    enum CaptureReceiptFixtures {
        static let argument = "-uitest-capture-receipt"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard isActive else { return nil }
            switch method {
            case "POST" where path == "/api/measurements":
                let at = ISO8601DateFormatter().string(from: .now)
                let row = """
                {"id":"receipt-weight-1","userId":"hermetic-user","type":"WEIGHT","value":72.0,"unit":"kg",\
                "measuredAt":"\(at)","notes":null,"source":"MANUAL","glucoseContext":null,\
                "externalId":null,"createdAt":"\(at)","updatedAt":"\(at)"}
                """
                return (201, Data(#"{"data":\#(row),"error":null}"#.utf8))
            case "DELETE" where path.hasPrefix("/api/measurements/"):
                return (200, Data(#"{"data":{"deleted":true},"error":null}"#.utf8))
            default:
                return nil
            }
        }
    }
#endif
