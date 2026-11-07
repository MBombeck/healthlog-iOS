#if DEBUG
    import Foundation

    /// **MED-PLUS (1.5.0, #126 3.4 and 3.11) — courses and automatic
    /// recording, for the sweep.**
    ///
    /// Under `-uitest-med-plus` (with `-uitest-area-meds`) Lisinopril reads
    /// like a v1.47 row: doses recorded automatically since 1 November (so the
    /// server sends no reminders), two courses (one ended at an instant in
    /// October, one running) and a start the server offers. Course writes
    /// answer as the server would. Everything is invented; no value of any
    /// real person appears here. Without the argument every row stays as it was.
    enum MedPlusFixtures {
        static let argument = "-uitest-med-plus"
        static let medicationID = AreaMedsDetailFixtures.lisinoprilID

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        /// The list row of Lisinopril with the v1.40 / v1.42.2 fields.
        static func decorate(_ row: [String: Any]) -> [String: Any] {
            guard isActive, row["id"] as? String == medicationID else { return row }
            return row.merging([
                "autoMarkTaken": true,
                "autoMarkTakenSince": "2026-11-01T08:00:00.000Z",
                "remindersActive": false,
                "courseStatus": "CURRENT",
                "intakeActionable": true,
                "courseCount": 2,
                "previousCourseEndedOn": "2026-10-25",
                "canEndCourse": true,
                "canStartCourse": false
            ]) { _, new in new }
        }

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard isActive, path.hasPrefix("/api/medications/\(medicationID)/courses") else { return nil }
            switch method {
            case "GET": return (200, Data(coursesJSON.utf8))
            case "DELETE": return (200, Data(deletedJSON.utf8))
            default: return (200, Data(editedJSON.utf8))
            }
        }

        private static let deletedJSON = #"{"data":{"id":"medplus-course-1","deleted":true},"error":null}"#
        private static let editedJSON =
            #"{"data":{"id":"medplus-course-1","startsOn":"2026-09-01","endsOn":"2026-10-25"},"error":null}"#

        private static let coursesJSON = """
        {"data":{"courses":[
          {"id":"medplus-course-1","startsOn":"2026-09-01","endsOn":"2026-10-25",
           "endedAt":"2026-10-25T14:30:00.000Z","status":"ENDED","takenDoses":54,"note":null},
          {"id":"medplus-course-2","startsOn":"2026-11-01","endsOn":null,"endedAt":null,
           "status":"CURRENT","takenDoses":5,"note":null}
        ],"courseCount":2,"previousCourseEndedOn":"2026-10-25","canStartCourse":false},"error":null}
        """
    }
#endif
