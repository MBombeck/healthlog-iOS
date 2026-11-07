import SwiftUI

/// KONTO (#151, server 1.46.0) — the one line after the app deleted the
/// account: when a server with a grace window erases the locked account and
/// that an admin can undo it until then, or that it is gone now.
///
/// The deletion screen disappears with the session, so the receipt waits on
/// ``AuthStore/deletionReceipt`` and the sign-in flow that replaces the shell
/// shows it as an inline line in its existing bottom inset. It is content of
/// the pre-sign-in flow, not a presenter: no alert, no overlay, and nothing of
/// the deleted account is on screen. "OK" clears it; so does the next sign-in,
/// because the receipt belongs to the account that left.
struct AccountDeletionReceiptNote: View {
    @Environment(AuthStore.self) private var authStore

    var body: some View {
        if let receipt = authStore.deletionReceipt {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Text(verbatim: AccountDeletionCopy.receiptMessage(receipt))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.deleted.receipt")
                Spacer(minLength: 0)
                Button(String(localized: "OK")) { authStore.deletionReceipt = nil }
                    .font(.hlCaption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("account.deleted.receipt.ok")
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.vertical, HLSpace.sm)
            .frame(maxWidth: .infinity)
            .background(HLMaterialBackground(.thinMaterial))
        }
    }
}
