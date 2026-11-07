#if DEBUG
    import Foundation
    import Synchronization

    /// **DOCS-TRASH (1.5.0, #151) — Recently deleted documents.**
    ///
    /// Under `-uitest-docs-trash` the fixture server is a v1.46 vault with two
    /// live documents and three deleted ones (`deletedCount` 3). Restore and
    /// purge change that state, so the sweep can photograph the list after a
    /// restore. `-uitest-docs-trash-cut` reports the deleted list as cut at
    /// its limit; `-uitest-docs-trash-old` answers like a server before 1.46.0
    /// (no `deletedCount`), the "before" picture. Everything is invented; no
    /// value of any real person appears here. `nil` for every other route.
    enum DocsTrashFixtures {
        static let argument = "-uitest-docs-trash"
        static let cutArgument = "-uitest-docs-trash-cut"
        static let olderServerArgument = "-uitest-docs-trash-old"

        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains(argument)
        }

        private struct Vault {
            var live = ["trash-live-befund", "trash-live-rezept"]
            var deleted = ["trash-del-mrt", "trash-del-labor", "trash-del-au"]
        }

        private static let vault = Mutex(Vault())

        private static let titles = [
            "trash-live-befund": ("Befund Hausarztpraxis", "DOCTOR_REPORT", "2026-10-28"),
            "trash-live-rezept": ("Rezept Naproxen", "PRESCRIPTION", "2026-10-12"),
            "trash-del-mrt": ("MRT Knie links", "IMAGING", "2026-11-03"),
            "trash-del-labor": ("Laborbefund Oktober", "LAB_RESULT", "2026-10-30"),
            "trash-del-au": ("Arbeitsunfähigkeit", "SICK_NOTE", "2026-10-06")
        ]

        static func response(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard isActive, path.hasPrefix("/api/documents/inbound") else { return nil }
            let args = ProcessInfo.processInfo.arguments
            switch (method, path) {
            case ("GET", "/api/documents/inbound/usage"):
                let count = vault.withLock { $0.deleted.count }
                let counter = args.contains(olderServerArgument) ? "" : #","deletedCount":\#(count)"#
                return envelope(#"{"usedBytes":2400000,"quotaBytes":104857600,"maxFileBytes":26214400,"#
                    + #""acceptedExtensions":[".pdf",".jpg",".png"],"linkedEpisodes":[],"linkedProcedures":[],"#
                    + #""assistAvailable":false\#(counter)}"#)
            case ("GET", "/api/documents/inbound"):
                let rows = vault.withLock { $0.live }.map(liveJSON).joined(separator: ",")
                return envelope(#"{"documents":[\#(rows)],"nextCursor":null}"#)
            case ("GET", "/api/documents/inbound/deleted"):
                let rows = vault.withLock { $0.deleted }.map(deletedJSON).joined(separator: ",")
                let cut = args.contains(cutArgument)
                return (200, Data((#"{"data":{"documents":[\#(rows)],"graceDays":30},"error":null,"#
                        + #""meta":{"truncated":\#(cut),"limit":200}}"#).utf8))
            default:
                return write(method: method, path: path)
            }
        }

        private static func write(method: String, path: String) -> (status: Int, body: Data)? {
            let parts = path.split(separator: "/").map(String.init)
            guard method == "POST", parts.count == 5 else { return nil }
            let id = parts[3]
            switch parts[4] {
            case "restore":
                vault.withLock { state in
                    state.deleted.removeAll { $0 == id }
                    if !state.live.contains(id) { state.live.insert(id, at: 0) }
                }
                return envelope(String(liveJSON(id).dropLast()) + #","facts":[]}"#)
            case "purge":
                vault.withLock { $0.deleted.removeAll { $0 == id } }
                return envelope(#"{"id":"\#(id)","purged":true}"#)
            default:
                return nil
            }
        }

        private static func envelope(_ data: String) -> (Int, Data) {
            (200, Data(#"{"data":\#(data),"error":null}"#.utf8))
        }

        private static func liveJSON(_ id: String) -> String {
            let (title, kind, day) = titles[id] ?? (id, "OTHER", "2026-10-01")
            return #"{"id":"\#(id)","kind":"\#(kind)","title":"\#(title)","filename":"\#(id).pdf","#
                + #""mimeType":"application/pdf","byteSize":240000,"status":"STORED","providerType":null,"#
                + #""reportDate":null,"documentDate":"\#(day)","errorReason":null,"factCount":0,"pendingCount":0,"#
                + #""conditionLinks":[],"servingClass":"inline","createdAt":"\#(day)T09:00:00.000Z","#
                + #""updatedAt":"\#(day)T09:00:00.000Z"}"#
        }

        private static func deletedJSON(_ id: String) -> String {
            let (title, kind, day) = titles[id] ?? (id, "OTHER", "2026-10-01")
            return #"{"id":"\#(id)","kind":"\#(kind)","title":"\#(title)","filename":"\#(id).pdf","#
                + #""mimeType":"application/pdf","byteSize":240000,"documentDate":"\#(day)","sourceSystem":null,"#
                + #""deletedAt":"2026-11-04T08:30:00.000Z","purgeAt":"2026-12-04T08:30:00.000Z"}"#
        }
    }
#endif
