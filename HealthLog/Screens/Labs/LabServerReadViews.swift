import SwiftUI

/// LAB-OCR — the switch on the scan chooser that sends this scan to the
/// server. Off on every scan; the line under it says what goes out.
struct LabServerReadToggle: View {
    @Bindable var flow: LabServerScanFlow

    var body: some View {
        HLSettingsToggleRow(
            title: "labs.ocr.choose.toggle",
            description: flow.sendsTextOnly ? "labs.ocr.choose.toggleTextHint" : "labs.ocr.choose.toggleHint",
            isOn: $flow.isChosen,
            accessibilityID: "labs.ocr.choose.toggle"
        )
    }
}

/// Step 2 of the scan: the report is being read. On the device this takes
/// seconds; a server read can take a minute, so it has a cancel button and,
/// after a while, says that it is taking longer. Never a bare spinner.
struct LabScanProcessingView: View {
    let isServerRead: Bool
    let onCancel: () -> Void

    /// After this long a server read says that it is taking longer.
    static let slowAfter: Duration = .seconds(60)

    @State private var isSlow = false

    var body: some View {
        VStack(spacing: HLSpace.md) {
            ProgressView()
            Text(isServerRead ? "labs.ocr.processing" : "labs.scan.processing")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
            if isServerRead {
                if isSlow {
                    Text("labs.ocr.processing.slow")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                }
                HLButton("labs.ocr.cancel", variant: .secondary, action: onCancel)
                    .accessibilityIdentifier("labs.ocr.cancel")
            }
        }
        .padding(HLSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: isServerRead) {
            isSlow = false
            guard isServerRead else { return }
            try? await Task.sleep(for: Self.slowAfter)
            if !Task.isCancelled { isSlow = true }
        }
    }
}
