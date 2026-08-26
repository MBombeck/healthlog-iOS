import SwiftUI

/// **SAFETY — the PHQ-9 item-9 crisis-resource card.**
///
/// Rendered iff the item-9 self-harm flag is set (server-computed `item9Flagged`,
/// or the LOCAL flag on an offline submit) — NEVER gated on the total / band. The
/// card is driven by the structured ``CrisisResourceSet`` (server-supplied when
/// present, else the bundled ``CrisisResourceFallback``): the emergency number +
/// each resource's literal `contacts` are data; every human-readable string (the
/// title, intro, "if in danger call X" line, section header, and each resource's
/// display NAME) is CLIENT-owned i18n, mirrored verbatim from the server.
///
/// HARD invariants: showing this card triggers NO third-party alert, NO contact /
/// emergency-contact notification, NO email, NO analytics, NO logging. It is calm
/// and non-alarmist — a restrained amber accent, never a red alarm — and the copy
/// is mirrored verbatim, never softened or escalated. Contact lines render as
/// tappable `tel:` / `https:` links where the shape is unambiguous, plain text
/// otherwise (e.g. "Text HOME to 741741").
struct MentalHealthCrisisCard: View {
    let crisis: CrisisResourceSet
    @Environment(\.openURL) private var openURL

    /// Restrained amber accent (calm, not alarm). Mirrors the web `border-amber-400/50`.
    private static let accent = Color(red: 0.85, green: 0.6, blue: 0.13)

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text("mentalHealth.crisis.title")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("mentalHealth.crisis.intro")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ifDangerText)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HLSectionLabel("mentalHealth.crisis.resourcesTitle")

                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(crisis.resources) { resource in
                        resourceRow(resource)
                    }
                }
            }
        }
        .overlay(alignment: .leading) {
            // Restrained leading accent rail — calm signpost, not an alarm fill.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Self.accent)
                .frame(width: 3)
                .padding(.vertical, HLSpace.sm)
        }
        .accessibilityElement(children: .contain)
    }

    /// "If you are in immediate danger, call {emergency} now." — emergency number
    /// interpolated into the localized template.
    private var ifDangerText: String {
        String(format: String(localized: "mentalHealth.crisis.ifDanger"), crisis.emergencyNumber)
    }

    private func resourceRow(_ resource: CrisisResource) -> some View {
        // Resolve the dotted key as a plain String first, then wrap — inline
        // interpolation in `LocalizedStringKey("…\(id).name")` would derive a
        // `…%@.name` key that misses the catalogue and leak the raw resource id.
        let nameKey = "mentalHealth.crisisResource.\(resource.id).name"
        return VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(LocalizedStringKey(nameKey))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(resource.contacts.enumerated()), id: \.offset) { _, contact in
                contactView(contact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contactView(_ contact: String) -> some View {
        if let url = Self.link(for: contact) {
            Button {
                openURL(url)
            } label: {
                Text(contact)
                    .font(.hlSubhead)
                    .foregroundStyle(HLAccent.userBrandTint)
                    .underline()
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
        } else {
            Text(contact)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
        }
    }

    /// Resolve a tappable URL for a contact line, or `nil` for plain text.
    /// - digits + spaces (e.g. "0800 111 0 111", "988", "116 123") → `tel:`
    /// - a bare domain (e.g. "telefonseelsorge.de", "findahelpline.com") → `https:`
    /// - anything else (e.g. "Text HOME to 741741") → `nil` (plain text)
    nonisolated static func link(for contact: String) -> URL? {
        let trimmed = contact.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let phoneChars = CharacterSet(charactersIn: "0123456789 ")
        if trimmed.unicodeScalars.allSatisfy({ phoneChars.contains($0) }) {
            let digits = trimmed.replacingOccurrences(of: " ", with: "")
            return URL(string: "tel:\(digits)")
        }

        // Bare domain: no spaces, contains a dot, only domain-legal characters.
        if !trimmed.contains(" "), trimmed.contains(".") {
            let domainChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
            if trimmed.unicodeScalars.allSatisfy({ domainChars.contains($0) }) {
                return URL(string: "https://\(trimmed.lowercased())")
            }
        }
        return nil
    }
}
