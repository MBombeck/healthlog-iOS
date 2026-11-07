import Foundation
import Observation

/// SUPP-EDIT (1.5.0, #131 P3) — the state and the writes of the
/// composition form.
///
/// The rows are built from the server's nutrient catalogue: a row names a
/// catalogue code, an amount and one of the code's input units. Nothing is
/// converted here; the server stores the canonical amount and keeps the
/// entered one beside it. A label photo fills the same rows as a proposal;
/// nothing is stored until the person taps Save (`source: LABEL_AI`).
///
/// The writes live in this model under Screens, not in a store: the frozen
/// effect census admits no new store file (MED-PLUS, same reason).
@MainActor
@Observable
final class MedicationCompositionEditorModel {
    enum CatalogState: Equatable {
        case loading
        case loaded(NutrientServerCatalog)
        case disabled(String?)
        case failed
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        var nutrient: String
        var amountText: String
        var unit: String
        /// From a label proposal the reader was unsure of, or one whose unit
        /// the catalogue does not offer.
        var needsCheck: Bool
        /// The units the server allows, after it refused this row's unit.
        var allowedUnits: [String]?

        init(nutrient: String = "", amountText: String = "", unit: String = "", needsCheck: Bool = false) {
            id = UUID()
            self.nutrient = nutrient
            self.amountText = amountText
            self.unit = unit
            self.needsCheck = needsCheck
            allowedUnits = nil
        }
    }

    let medicationID: String
    private(set) var catalogState: CatalogState = .loading
    var rows: [Row]
    private(set) var source: MedicationIngredientsRepository.Source = .manual
    private(set) var proposal: SupplementLabelProposal?
    private(set) var isSaving = false
    private(set) var isReading = false
    private(set) var saveError: String?
    private(set) var labelError: String?

    @ObservationIgnored private let repository: MedicationIngredientsRepository?
    @ObservationIgnored private let offReason: @MainActor () -> String?
    @ObservationIgnored private let initialBody: [MedicationIngredientsRepository.Line]
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var lastBody: MedicationIngredientsRepository.PutBody?
    @ObservationIgnored private var lastKey = IdempotencyKey()
    @ObservationIgnored private let locale: Locale

    init(
        medicationID: String,
        lines: [MedicationIngredient],
        repository: MedicationIngredientsRepository?,
        offReason: @escaping @MainActor () -> String? = { nil },
        locale: Locale = .current
    ) {
        self.medicationID = medicationID
        self.repository = repository
        self.offReason = offReason
        self.locale = locale
        let rows = lines.map { line in
            Row(
                nutrient: line.nutrient,
                amountText: Self.amountText(line.enteredAmount ?? line.amountPerUnit, locale: locale),
                unit: line.enteredUnit ?? line.unit
            )
        }
        self.rows = rows
        initialBody = rows.compactMap { Self.line(for: $0, locale: locale) }
    }

    // MARK: - Catalogue

    var catalog: NutrientServerCatalog? {
        if case let .loaded(catalog) = catalogState { return catalog }
        return nil
    }

    /// Reads the catalogue once; coming back from the camera page keeps it.
    func loadCatalog() async {
        guard catalog == nil else { return }
        guard let repository else {
            catalogState = .failed
            return
        }
        do {
            catalogState = try await .loaded(repository.catalog())
        } catch {
            if let next = Self.catalogState(after: error, offReason: offReason()) { catalogState = next }
        }
    }

    func retryCatalog() async {
        catalogState = .loading
        await loadCatalog()
    }

    /// `nil` keeps the state (a cancelled read changes nothing). A server
    /// without the route (404) cannot edit: it reads as a failed catalogue.
    nonisolated static func catalogState(after error: Error, offReason: String?) -> CatalogState? {
        if error is CancellationError { return nil }
        switch error as? HLError {
        case .canceled: return nil
        case .moduleDisabled: return .disabled(offReason)
        case let .server(status, _, _) where status == 403: return .disabled(offReason)
        default: return .failed
        }
    }

    // MARK: - Rows

    var canAddRow: Bool {
        rows.count < MedicationIngredientsRepository.maxLines && !isBusy
    }

    func addRow() {
        guard canAddRow else { return }
        rows.append(Row())
    }

    func remove(_ id: Row.ID) {
        rows.removeAll { $0.id == id }
    }

    /// Choosing a nutrient sets its canonical unit, as on the web.
    func choose(nutrient code: String, for id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].nutrient = code
        rows[index].unit = catalog?.entry(for: code)?.unit ?? ""
        rows[index].needsCheck = false
        rows[index].allowedUnits = nil
    }

    func setUnit(_ unit: String, for id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].unit = unit
        rows[index].allowedUnits = nil
    }

    func setAmount(_ text: String, for id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].amountText = text
        rows[index].needsCheck = false
    }

    /// The codes other rows already use; one nutrient appears once.
    func takenCodes(except id: Row.ID) -> Set<String> {
        Set(rows.filter { $0.id != id }.map(\.nutrient).filter { !$0.isEmpty })
    }

    // MARK: - Save

    var isBusy: Bool {
        isSaving || isReading
    }

    /// Every row names a nutrient, a unit and an amount above zero.
    var rowsAreValid: Bool {
        rows.allSatisfy { Self.line(for: $0, locale: locale) != nil }
    }

    var hasChanges: Bool {
        source == .labelAI || rows.compactMap { Self.line(for: $0, locale: locale) } != initialBody
            || rows.count != initialBody.count
    }

    var canSave: Bool {
        catalog != nil && !isBusy && rowsAreValid && hasChanges
    }

    /// Writes the composition. `true` when it was stored. The key stays the
    /// same while the body does, so a retry after a lost answer is answered
    /// from the first write.
    func save() async -> Bool {
        guard let repository, catalog != nil, !isBusy else { return false }
        guard rowsAreValid else {
            saveError = String(localized: "medications.composition.edit.invalidRow")
            return false
        }
        let body = MedicationIngredientsRepository.PutBody(
            ingredients: rows.compactMap { Self.line(for: $0, locale: locale) },
            source: source
        )
        if body != lastBody {
            lastBody = body
            lastKey = IdempotencyKey()
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            _ = try await repository.save(medicationID: medicationID, body: body, idempotencyKey: lastKey)
            return true
        } catch {
            saveError = message(afterSaveError: error)
            return false
        }
    }

    private func message(afterSaveError error: Error) -> String? {
        if error is CancellationError { return nil }
        switch error as? HLError {
        case .canceled: return nil
        case let .server(422, code, _) where code == "medications.ingredients.unitMismatch":
            markUnitMismatches()
            return String(localized: "medications.composition.edit.error.unitMismatch")
        case let .server(422, code, _) where code == "medications.ingredients.invalid":
            return String(localized: "medications.composition.edit.error.invalid")
        case .moduleDisabled: return String(localized: "medications.composition.edit.error.notAllowed")
        case let .server(status, _, _) where status == 403: return String(localized: "medications.composition.edit.error.notAllowed")
        case let .server(status, _, _) where status == 404: return String(localized: "medications.composition.edit.error.gone")
        case .offline, .network: return String(localized: "medications.composition.edit.error.offline")
        default: return String(localized: "medications.composition.edit.error.generic")
        }
    }

    /// 422 `unitMismatch`: the transport does not hand the body's
    /// `meta.index` / `meta.allowedUnits` on, so the rows are checked against
    /// the catalogue, which is where the server takes the allowed units from.
    func markUnitMismatches() {
        guard let catalog else { return }
        for index in rows.indices {
            guard let entry = catalog.entry(for: rows[index].nutrient) else { continue }
            if !entry.offeredUnits.contains(rows[index].unit) {
                rows[index].allowedUnits = entry.offeredUnits
            }
        }
    }

    // MARK: - Label photo

    /// Reads one JPEG into a proposal. A proposal replaces the rows in the
    /// form and is stored only by Save.
    func readLabel(jpeg: Data) {
        guard let repository, !isBusy else { return }
        isReading = true
        labelError = nil
        let id = medicationID
        readTask = Task { [weak self] in
            do {
                let proposal = try await repository.readLabel(medicationID: id, jpeg: jpeg)
                self?.apply(proposal)
            } catch {
                self?.labelError = SupplementLabelReadFailure(error)?.message
            }
            self?.isReading = false
            self?.readTask = nil
        }
    }

    /// Reports a photo that could not be made into a JPEG on the phone.
    func reportLocal(_ failure: SupplementLabelReadFailure) {
        labelError = failure.message
    }

    func cancelRead() {
        readTask?.cancel()
        readTask = nil
        isReading = false
    }

    func apply(_ proposal: SupplementLabelProposal) {
        var unmatched = proposal.unmatched
        var next: [Row] = []
        var seen: Set<String> = []
        for line in proposal.lines {
            guard let entry = catalog?.entry(for: line.nutrient), entry.code != NutrientServerCatalog.notAnIngredient,
                  !seen.contains(line.nutrient), next.count < MedicationIngredientsRepository.maxLines else
            {
                if !line.printedText.isEmpty { unmatched.append(line.printedText) }
                continue
            }
            seen.insert(line.nutrient)
            let offered = entry.offeredUnits.contains(line.unit)
            next.append(Row(
                nutrient: line.nutrient,
                amountText: Self.amountText(line.amount, locale: locale),
                unit: offered ? line.unit : entry.unit,
                needsCheck: line.isLowConfidence || !offered
            ))
        }
        rows = next
        source = .labelAI
        self.proposal = SupplementLabelProposal(lines: proposal.lines, unmatched: unmatched, servingNote: proposal.servingNote)
    }

    // MARK: - Pure helpers

    /// The wire line for a row, or `nil` while it is incomplete.
    nonisolated static func line(for row: Row, locale: Locale) -> MedicationIngredientsRepository.Line? {
        guard !row.nutrient.isEmpty, !row.unit.isEmpty,
              let amount = parseAmount(row.amountText, locale: locale), amount > 0, amount.isFinite else { return nil }
        return MedicationIngredientsRepository.Line(nutrient: row.nutrient, amount: amount, unit: row.unit)
    }

    /// A typed amount: the locale's decimal separator or a dot, no grouping.
    nonisolated static func parseAmount(_ text: String, locale: Locale) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let separator = locale.decimalSeparator ?? "."
        let normalized = trimmed.replacingOccurrences(of: separator, with: ".").replacingOccurrences(of: ",", with: ".")
        guard normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              normalized.filter({ $0 == "." }).count <= 1 else { return nil }
        return Double(normalized)
    }

    /// An amount as the field shows it: up to three decimals, no grouping.
    nonisolated static func amountText(_ amount: Double, locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 3
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }
}

/// Who may edit and who may read a label (#131 and the server notes of
/// 15.10.): editing at MANAGE on medications (always on the own record),
/// reading a label only on the own record, only when the server says the
/// `supplementLabel` capability is available, never on the `frugal` level.
enum MedicationCompositionAccess {
    static func canEdit(_ access: AccountAccess) -> Bool {
        guard let active = access.active else { return true }
        return active.level == .manage && active.allows(section: .medications, write: true)
    }

    static func isOwnRecord(_ access: AccountAccess) -> Bool {
        access.active == nil && access.recordKind == .self
    }

    static func offersLabelPhoto(
        access: AccountAccess,
        reportsCapabilities: Bool,
        capability: AICapabilityState,
        usage: AIUsageLevel?
    ) -> Bool {
        isOwnRecord(access) && reportsCapabilities && capability.available && capability.isAvailable
            && usage != .frugal
    }

    /// The categories the composition is offered for without being stored
    /// yet (as on the web).
    static func offersEmptyComposition(category: String?) -> Bool {
        guard let category else { return false }
        return ["VITAMIN", "SUPPLEMENT"].contains(category.uppercased())
    }
}
