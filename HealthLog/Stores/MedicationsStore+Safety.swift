import Foundation

extension MedicationsStore {
    /// Fail closed when a server-owned terminal ledger status reaches a write
    /// seam. The row remains visible, but no network or outbox mutation occurs.
    func rejectReadOnlyIntakeMutation() -> WriteOutcome {
        let err = HLError.server(
            status: 422,
            code: "medications.intake.status_read_only",
            message: "A missed intake is read-only."
        )
        error = err
        return .failed(err)
    }
}
