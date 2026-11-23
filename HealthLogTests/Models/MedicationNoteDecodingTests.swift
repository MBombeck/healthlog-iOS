import Foundation
@testable import HealthLog
import Testing

/// The medication note (server 1.47.6, `note: string | null`) reaches the
/// domain trimmed, and an older server without the key decodes as before.
@Suite("Medication note: read from the server")
struct MedicationNoteDecodingTests {
    private static func medication(noteJSON: String?) throws -> Medication {
        let note = noteJSON.map { #","note":\#($0)"# } ?? ""
        let json = #"{"id":"med-1","name":"Lisinopril","dose":"5 mg"\#(note)}"#
        return try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: Data(json.utf8)).toDomain()
    }

    @Test("a note is shown as written, without surrounding blanks")
    func noteIsTrimmed() throws {
        #expect(try Self.medication(noteJSON: #""  30 minutes before food \n""#).note == "30 minutes before food")
    }

    @Test("null, empty and absent all mean no note", arguments: [#"null"#, #""""#, #""   ""#, nil])
    func noNote(noteJSON: String?) throws {
        #expect(try Self.medication(noteJSON: noteJSON).note == nil)
    }

    @Test("a list from server 1.47.6 decodes with the note on each row")
    func listDecodes() throws {
        let json = #"""
        [{"id":"a","name":"A","dose":"1","note":"with water"},{"id":"b","name":"B","dose":"1","note":null}]
        """#
        let rows = try JSONDecoder.hlDefault.decode([MedicationWireDTO].self, from: Data(json.utf8)).map { $0.toDomain() }
        #expect(rows.map(\.note) == ["with water", nil])
    }
}
