import SwiftUI
import WatchKit

// MARK: - Watch quick-capture for manual measurements

/// Per-kind wrist entry metadata — title, unit, the Digital Crown range/step,
/// and a sensible default starting value. Kept thin + watch-local (the watch
/// target never imports the phone's `MetricKind` / `MetricKindDescriptor`). The
/// phone owns validation + the canonical write; these bounds just keep the
/// crown in a humane range so the user lands near the value fast.
struct WatchMeasureKindMeta: Identifiable {
    /// Crown bounds + default for one numeric field.
    struct Field {
        let range: ClosedRange<Double>
        let step: Double
        let defaultValue: Double
    }

    let kind: WatchMeasurementKind
    let title: LocalizedStringKey
    let unit: LocalizedStringKey
    let systemImage: String
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    /// For blood pressure: the diastolic field metadata. `nil` for scalar kinds.
    var diastolic: Field?

    var id: String {
        kind.id
    }

    /// The fixed, ordered set the wrist offers — the four numeric, manual
    /// kinds the Digital Crown enters in seconds. `@MainActor` because
    /// `LocalizedStringKey` isn't `Sendable`; the only readers are SwiftUI
    /// view bodies (already MainActor-isolated).
    @MainActor static let all: [WatchMeasureKindMeta] = [
        WatchMeasureKindMeta(
            kind: .weight,
            title: "Weight",
            unit: "kg",
            systemImage: "scalemass",
            range: 20 ... 300,
            step: 0.1,
            defaultValue: 70,
            diastolic: nil
        ),
        WatchMeasureKindMeta(
            kind: .bloodPressure,
            title: "Blood pressure",
            unit: "mmHg",
            systemImage: "heart.text.square",
            range: 60 ... 260,
            step: 1,
            defaultValue: 120,
            diastolic: Field(range: 40 ... 160, step: 1, defaultValue: 80)
        ),
        WatchMeasureKindMeta(
            kind: .glucose,
            title: "Glucose",
            unit: "mg/dL",
            systemImage: "drop",
            range: 20 ... 600,
            step: 1,
            defaultValue: 100,
            diastolic: nil
        ),
        WatchMeasureKindMeta(
            kind: .pulse,
            title: "Pulse",
            unit: "bpm",
            systemImage: "waveform.path.ecg",
            range: 30 ... 220,
            step: 1,
            defaultValue: 70,
            diastolic: nil
        )
    ]
}

/// Wrist quick-capture: pick one of the four manual kinds, dial the value with
/// the Digital Crown, log it. The phone records it through the SAME server-first
/// `MeasurementsStore` path the app's `MeasureSheet` uses, so it syncs to the
/// server + Apple Health identically. Offline-safe: an unreachable phone queues
/// the action durably (same `transferUserInfo` channel as med-intake), and the
/// wrist shows an honest "will sync" / "not saved — retry" state.
struct WatchMeasureView: View {
    @Environment(WatchConnectivityClient.self) private var client

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Log")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !client.hasReceived {
            WatchMessageState(title: "Syncing…", systemImage: "arrow.triangle.2.circlepath")
        } else if !client.signedIn {
            WatchMessageState(title: "Sign in on your iPhone", systemImage: "iphone")
        } else {
            List(WatchMeasureKindMeta.all) { meta in
                NavigationLink {
                    WatchMeasureEntryView(meta: meta)
                } label: {
                    Label {
                        Text(meta.title)
                            .font(.hlBody)
                            .foregroundStyle(LAColor.text)
                    } icon: {
                        Image(systemName: meta.systemImage)
                            .foregroundStyle(LAColor.text)
                    }
                }
            }
        }
    }
}

/// Digital-Crown value entry for a single kind. Scalar kinds dial one number;
/// blood pressure dials systolic then diastolic. Logging mints a durable action
/// and pops back to the kind list; the quiet footer reflects the last result.
struct WatchMeasureEntryView: View {
    @Environment(WatchConnectivityClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    let meta: WatchMeasureKindMeta

    @State private var value: Double
    @State private var diastolic: Double
    /// `true` once the systolic is set and the BP entry has advanced to the
    /// diastolic field (BP only).
    @State private var bpStage: BPStage = .systolic

    enum BPStage { case systolic, diastolic }

    init(meta: WatchMeasureKindMeta) {
        self.meta = meta
        _value = State(initialValue: meta.defaultValue)
        _diastolic = State(initialValue: meta.diastolic?.defaultValue ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: HLSpace.sm) {
                Text(fieldTitle)
                    .font(.hlCaption)
                    .foregroundStyle(LAColor.textSecondary)

                Text(displayValue)
                    .font(.hlLargeTitle)
                    .foregroundStyle(LAColor.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: activeValue)
                    .focusable()
                    .digitalCrownRotation(
                        activeBinding,
                        from: activeRange.lowerBound,
                        through: activeRange.upperBound,
                        by: activeStep,
                        sensitivity: .medium,
                        isContinuous: false
                    )

                Text(meta.unit)
                    .font(.hlCaption)
                    .foregroundStyle(LAColor.textSecondary)

                primaryButton
                    .padding(.top, HLSpace.xs)
                footer
            }
            .padding(.vertical, HLSpace.sm)
        }
        .navigationTitle(meta.title)
    }

    // MARK: - Active field (BP has two stages; scalars one)

    private var isBloodPressure: Bool {
        meta.diastolic != nil
    }

    private var activeValue: Double {
        isBloodPressure && bpStage == .diastolic ? diastolic : value
    }

    private var activeBinding: Binding<Double> {
        isBloodPressure && bpStage == .diastolic ? $diastolic : $value
    }

    private var activeRange: ClosedRange<Double> {
        if isBloodPressure, bpStage == .diastolic, let dia = meta.diastolic {
            return dia.range
        }
        return meta.range
    }

    private var activeStep: Double {
        if isBloodPressure, bpStage == .diastolic, let dia = meta.diastolic {
            return dia.step
        }
        return meta.step
    }

    private var fieldTitle: LocalizedStringKey {
        guard isBloodPressure else { return meta.title }
        return bpStage == .systolic ? "Systolic" : "Diastolic"
    }

    private var displayValue: String {
        // Weight keeps one decimal; the integer kinds round to whole numbers.
        meta.step < 1
            ? String(format: "%.1f", activeValue)
            : String(Int(activeValue.rounded()))
    }

    // MARK: - Actions

    @ViewBuilder
    private var primaryButton: some View {
        if isBloodPressure, bpStage == .systolic {
            Button {
                bpStage = .diastolic
                WKInterfaceDevice.current().play(.click)
            } label: {
                Label("Next", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(LAColor.text)
        } else {
            Button {
                log()
            } label: {
                Label("Log", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(LAColor.text)
        }
    }

    private func log() {
        if isBloodPressure {
            client.logMeasurement(kind: meta.kind, value: value, secondary: diastolic)
        } else {
            client.logMeasurement(kind: meta.kind, value: value)
        }
        WKInterfaceDevice.current().play(.success)
        dismiss()
    }

    /// Quiet, non-blocking last-action footer — only surfaces when the most
    /// recent capture is queued ("will sync") or failed ("not saved — retry").
    @ViewBuilder
    private var footer: some View {
        switch client.lastMeasurementActionState {
        case .queued:
            Label("Last: will sync", systemImage: "clock.badge.checkmark")
                .font(.hlCaption)
                .foregroundStyle(LAColor.warn)
                .labelStyle(.titleAndIcon)
        case .failed:
            Button {
                client.retryMeasurement()
                WKInterfaceDevice.current().play(.retry)
            } label: {
                Label("Last: not saved — retry", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.hlCaption)
            }
            .buttonStyle(.borderless)
            .tint(LAColor.warn)
        default:
            EmptyView()
        }
    }
}
