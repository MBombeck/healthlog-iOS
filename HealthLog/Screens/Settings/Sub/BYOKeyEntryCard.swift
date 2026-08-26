import SwiftUI

/// v0.13 W4 — the inline "Own key" (BYO) entry card revealed in
/// Settings → Assistant when the user picks the `.byoKey` source. Collects a
/// provider + secret key (+ optional model override + an https base URL when the
/// provider needs one), runs **Validate & save** against the provider, and on
/// success presents the BYO informed-consent sheet (Apple 5.1.2(i)) before the
/// grant lands. A configured provider shows its last-4 + model with a Remove
/// action.
///
/// All non-View logic lives in ``BYOKeyEntryModel`` (validate → save → grant) so
/// the flow is unit-pinned. Monochrome doctrine: zero glass, single `.tint`
/// accent, every string localized (EN source + DE).
struct BYOKeyEntryCard: View {
    @State private var model: BYOKeyEntryModel
    @State private var presentConsent = false
    @State private var confirmRemove = false

    init(model: BYOKeyEntryModel) {
        _model = State(initialValue: model)
    }

    /// R12 — die Karte war das einzige `HLCard` in den Einstellungen: anderes
    /// Karten-Primitive, anderer Innenabstand (16 statt 14), 1-pt- statt
    /// 0,5-pt-Kontur, Glass- statt flacher Fläche, und ein selbstgebauter
    /// 17-pt-Kartenkopf, weil `HLCard` keinen Titel mitbringt. Jetzt
    /// `HLSettingsCard`: Titel und Ränder kommen vom Primitive, und die
    /// Datenschutz-Zusage sitzt im Footer-Slot, der nach R5 für Rechtliches
    /// vorgesehen ist (Wortlaut unverändert).
    var body: some View {
        HLSettingsCard(
            icon: "key.horizontal.fill",
            title: "Your own AI key",
            footer: "Requests go straight from this iPhone to your provider — never through HealthLog's servers."
        ) {
            if model.isConfigured, model.phase != .editing {
                configuredState
            } else {
                providerMenu
                entryFields
                inlineStatus
                validateButton
            }
        }
        .accessibilityIdentifier("BYOKeyEntryCard")
        .sheet(isPresented: $presentConsent) {
            BYOConsentSheet(
                provider: model.provider,
                onAccept: {
                    model.confirmConsent()
                    presentConsent = false
                },
                onDecline: {
                    model.cancelConsent()
                    presentConsent = false
                }
            )
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .awaitingConsent { presentConsent = true }
        }
    }

    // MARK: - Provider picker

    private var providerMenu: some View {
        Menu {
            ForEach(BYOProviderID.allCases) { provider in
                Button {
                    model.provider = provider
                } label: {
                    if provider == model.provider {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: HLSpace.xs) {
                Text(model.provider.displayName)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.hlIcon(HLIconSize.xs))
                    .foregroundStyle(HLText.tertiary)
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.sm))
        }
        .accessibilityIdentifier("BYOKeyEntryCard.providerMenu")
    }

    // MARK: - Entry fields

    @ViewBuilder
    private var entryFields: some View {
        SecureField(String(localized: "API key"), text: $model.keyDraft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("BYOKeyEntryCard.keyField")

        TextField(
            String(localized: "Model (optional, default \(model.provider.defaultModel))"),
            text: $model.modelDraft
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("BYOKeyEntryCard.modelField")

        if model.provider.requiresBaseURL {
            TextField(String(localized: "Base URL (https)"), text: $model.baseURLDraft)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("BYOKeyEntryCard.baseURLField")
        }
    }

    // MARK: - Inline status

    @ViewBuilder
    private var inlineStatus: some View {
        switch model.phase {
        case .validating:
            statusRow(
                symbol: "arrow.triangle.2.circlepath",
                tint: HLText.secondary,
                text: String(localized: "Checking your key…")
            )
        case let .invalid(message):
            statusRow(symbol: "exclamationmark.triangle.fill", tint: HLColor.statusBad, text: message)
        case .saved:
            statusRow(
                symbol: "checkmark.seal.fill",
                tint: HLColor.statusOK,
                text: String(localized: "Saved. Your key is ready.")
            )
        case .editing, .awaitingConsent:
            EmptyView()
        }
    }

    private func statusRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: HLSpace.xs) {
            Image(systemName: symbol)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(tint)
            Text(text)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// R9 — `.restrained` ist gefallen. Die Assistent-Seite hat genau **eine**
    /// `.primary`-Fläche, und das ist „Speichern" am Ende der Provider-Sektion
    /// (die abschließende Commit-Aktion der Seite). „Prüfen & speichern" ist der
    /// Commit eines Unter-Flusses, der als Folge der Quellen-Auswahl darüber
    /// erscheint — also die nachgeordnete Vollbreiten-Aktion, `.secondary`.
    /// Beide Karten können gleichzeitig sichtbar sein (gekoppelter Server +
    /// „Eigener Schlüssel" gewählt), deshalb ist die Rangfolge hier nicht
    /// akademisch.
    private var validateButton: some View {
        HLButton(
            String(localized: "Validate & save"),
            variant: .secondary,
            isLoading: model.phase == .validating
        ) {
            Task { await model.validateAndSave() }
        }
        .disabled(!model.canSubmit || model.phase == .validating)
        .accessibilityIdentifier("BYOKeyEntryCard.validateButton")
    }

    // MARK: - Configured state

    private var configuredState: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.hlIcon(HLIconSize.rowAction))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(model.provider.displayName)
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    if let last4 = model.savedKeyLast4 {
                        Text(String(localized: "Key ····\(last4) · \(model.resolvedModel)"))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    } else {
                        Text(model.resolvedModel)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            // R8 — der 12-pt-Rot-Text als destruktive Affordanz ist gefallen;
            // in einer Karte ist eine Aktion eine Zeile. R13 — das Entfernen
            // eines gespeicherten Schlüssels ist ein Einzelobjekt-Widerruf und
            // bekommt damit einen `confirmationDialog` (vorher feuerte es
            // direkt).
            HLSettingsActionRow(
                icon: "trash",
                title: "Remove key",
                role: .destructive,
                presents: .confirm
            ) {
                confirmRemove = true
            }
            .accessibilityIdentifier("BYOKeyEntryCard.removeButton")
        }
        .hlConfirmDestructive(
            Text("Remove this key?"),
            isPresented: $confirmRemove,
            message: Text("The assistant stops answering until you enter a key again."),
            confirm: Text("Remove key"),
            confirmIdentifier: "BYOKeyEntryCard.confirmRemove",
            cancel: Text("Cancel"),
            onCancel: { confirmRemove = false },
            action: {
                model.removeKey()
            }
        )
    }
}
