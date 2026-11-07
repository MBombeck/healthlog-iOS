import XCTest

/// **DOCS-TRASH (1.5.0, #151) — Recently deleted documents, photographed.**
///
/// Opens Documents from More with `DocsTrashFixtures` (`-uitest-docs-trash`):
/// the list with the centred link under it, Recently deleted with three rows,
/// the in-place question before "Delete now", a restore, and the list again
/// with the restored document in it. Runs at the accessibility size too
/// (`HL_SWEEP_XXL=1`). Navigation is soft like the rest of the sweep. Only
/// runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_22d_docsTrash() {
        boot(extra: [DocsTrashSweep.argument])
        let size = isXXL ? "-xxl" : ""
        guard openDocuments() else { return }
        guard let link = probe("documents.trash.link") else {
            note("Recently deleted link not found")
            shotToEnd("22d-trash-list\(size)")
            return
        }
        shot("22d-trash-list\(size)")
        link.tap()
        settle(3)
        shot("22d-trash-page\(size)")
        if let purge = probe("documents.trash.purge.trash-del-mrt") {
            purge.tap()
            settle(1)
            shot("22d-trash-confirm\(size)")
            _ = tap(element("documents.trash.purge.cancel.trash-del-mrt"), "purge cancel")
            settle(1)
        } else {
            note("purge button not found")
        }
        if let restore = probe("documents.trash.restore.trash-del-labor") {
            restore.tap()
            settle(3)
            shot("22d-trash-restored\(size)")
        } else {
            note("restore button not found")
        }
        goBack()
        settle(2)
        scrollUpToTop()
        shotToEnd("22d-trash-list-after\(size)")
    }

    /// A server before 1.46.0 sends no `deletedCount`: no link, the list as in
    /// 1.4 (also the "before" picture). The cut list shows its footer note.
    func test_22d_docsTrashOlderServerAndCut() {
        boot(extra: [DocsTrashSweep.argument, DocsTrashSweep.olderServer])
        let size = isXXL ? "-xxl" : ""
        guard openDocuments() else { return }
        if probe("documents.trash.link") != nil { note("older server shows the Recently deleted link") }
        shot("22d-trash-olderServer\(size)")
        app.terminate()
        boot(extra: [DocsTrashSweep.argument, DocsTrashSweep.cut])
        guard openDocuments(), let link = probe("documents.trash.link") else { return }
        link.tap()
        settle(3)
        _ = probe("documents.trash.truncated")
        shot("22d-trash-cut\(size)")
    }

    private func openDocuments() -> Bool {
        tab("ellipsis")
        guard let row = probe("more.row.documents") else {
            note("More row not present: documents")
            return false
        }
        row.tap()
        settle(3)
        return true
    }
}

private enum DocsTrashSweep {
    static let argument = "-uitest-docs-trash"
    static let olderServer = "-uitest-docs-trash-old"
    static let cut = "-uitest-docs-trash-cut"
}
