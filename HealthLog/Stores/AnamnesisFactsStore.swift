import Foundation
import Observation

/// **CU-32 — Zustand der Anamnese-Fläche.**
///
/// Hält den Server-Stand (`payload`) und leitet daraus für jede Art genau eine
/// von drei Aussagen ab: nie erfasst / erfasst-aber-unlesbar / erfasst. Der
/// Store rechnet **nichts** vor: er wählt lediglich den richtigen Verb (POST für
/// die Erstangabe, PATCH für die Korrektur) und lädt nach jedem Schreibvorgang
/// neu, weil eine Korrektur eine **neue** Revisions-ID erzeugt und die alte
/// als Nebenläufigkeits-Token damit tot ist.
///
/// **Kein optimistisches Update.** Auf dieser Fläche wäre es eine Lüge: der
/// Server bestimmt `validFrom` (strikt grösser als der Vorgänger, notfalls
/// +1 ms) und die Provenienz, und beides steht sichtbar in der Oberfläche. Ein
/// vorweggenommener Zustand müsste beide erfinden.
///
/// **Kein PHI im Prozess über die Fläche hinaus.** Der Store wird pro
/// Bildschirm im `.task` gebaut und stirbt mit ihm — er hängt bewusst nicht am
/// `AppContainer`, damit kein Anamnese-Zustand einen Nutzerwechsel überlebt.
@MainActor
@Observable
public final class AnamnesisFactsStore {
    /// Der zuletzt geladene Server-Stand. Vor dem ersten Laden leer — und
    /// „leer" heisst hier ausdrücklich „wir wissen es noch nicht", nicht
    /// „nichts erfasst"; dafür gibt es ``didLoad``.
    public private(set) var payload: AnamnesisFactsPayload = .empty
    public private(set) var isLoading: Bool = false
    /// `true` erst, nachdem eine Runde tatsächlich durchgelaufen ist. Der
    /// Leerzustand („nie erfasst") darf erst danach gerendert werden.
    public private(set) var didLoad: Bool = false
    public private(set) var loadFailed: Bool = false
    /// Die Art, für die gerade geschrieben wird — treibt den Zeilen-Spinner.
    public private(set) var pendingKind: AnamnesisFactKind?
    /// Benannte Fehlermeldung des letzten Schreibvorgangs. Vier Fehlerbilder,
    /// vier Texte — nie ein generisches „Fehler".
    public private(set) var writeError: String?
    /// Meldung des letzten Ladefehlers.
    public private(set) var loadError: String?

    private let repo: AnamnesisRepository

    public init(repo: AnamnesisRepository) {
        self.repo = repo
    }

    // MARK: - Derived

    /// Der Zustand einer Art — die einzige Quelle für „nie erfasst" gegen
    /// „ausdrücklich keine".
    public func state(for kind: AnamnesisFactKind) -> AnamnesisFactState {
        payload.state(for: kind)
    }

    /// Verlauf einer Art, neueste Gültigkeit zuerst.
    public func history(for kind: AnamnesisFactKind) -> [AnamnesisFactRevision] {
        payload.history(for: kind)
    }

    /// `true`, wenn für keine der drei Arten je etwas erfasst wurde.
    public var isEmpty: Bool {
        payload.recordedKinds.isEmpty
    }

    /// Der gesamte Verlauf über alle Arten, neueste Gültigkeit zuerst — die
    /// Zeitleiste der Fläche.
    public var timeline: [AnamnesisFactRevision] {
        payload.history.sorted { $0.validFrom > $1.validFrom }
    }

    // MARK: - Load

    public func load() async {
        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            didLoad = true
        }
        do {
            payload = try await repo.facts()
            loadFailed = false
        } catch {
            loadFailed = true
            loadError = AnamnesisFactFailure.from(error).userFacingDescription
        }
    }

    // MARK: - Write

    /// Setzt den Wert einer Art. Wählt den Verb aus dem aktuellen Zustand:
    /// **POST**, solange nichts erfasst ist (dann gibt es keine Revisions-ID),
    /// **PATCH** auf die aktuelle Revision, sobald eine existiert.
    ///
    /// Eine unlesbare Revision hat trotzdem eine ID und wird deshalb korrigiert,
    /// nicht neu angelegt — sonst liefe der POST in `currentExists`.
    public func setValue(_ value: AnamnesisFactValue, for kind: AnamnesisFactKind) async {
        guard pendingKind == nil else { return }
        pendingKind = kind
        writeError = nil
        defer { pendingKind = nil }

        do {
            if let revision = state(for: kind).revision {
                _ = try await repo.correct(revisionId: revision.id, kind: kind, to: value)
            } else {
                _ = try await repo.create(kind: kind, value: value)
            }
            await reload()
        } catch {
            await handleWriteFailure(error)
        }
    }

    /// Schliesst den aktuellen Wert einer Art. Danach ist die Art wieder ohne
    /// aktuelle Angabe — der Verlauf bleibt.
    public func removeCurrent(for kind: AnamnesisFactKind) async {
        guard pendingKind == nil, let revision = state(for: kind).revision else { return }
        pendingKind = kind
        writeError = nil
        defer { pendingKind = nil }

        do {
            _ = try await repo.remove(revisionId: revision.id)
            await reload()
        } catch {
            await handleWriteFailure(error)
        }
    }

    public func clearWriteError() {
        writeError = nil
    }

    // MARK: - Private

    /// Benennt den Fehlschlag und zieht — wo der Ausweg „neu laden" heisst —
    /// selbst einen frischen Stand nach. Der Mensch davor soll nach einer
    /// Kollision keine tote Revisions-ID vor sich haben.
    private func handleWriteFailure(_ error: Error) async {
        let failure = AnamnesisFactFailure.from(error)
        writeError = failure.userFacingDescription
        if failure.requiresReload {
            await reload()
        }
    }

    /// Stiller Nachladevorgang: aktualisiert `payload`, überschreibt aber
    /// **nicht** die gerade gesetzte Schreibfehlermeldung.
    private func reload() async {
        do {
            payload = try await repo.facts()
            loadFailed = false
        } catch {
            // Der Schreibvorgang selbst ist bereits benannt; ein zusätzlich
            // fehlgeschlagenes Nachladen wird nicht doppelt gemeldet, sondern
            // nur als veralteter Stand markiert.
            loadFailed = true
        }
    }
}
