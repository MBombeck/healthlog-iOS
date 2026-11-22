import SwiftUI

/// What the board shows, chosen like on the web: the values under the lanes
/// (measurements, lab markers, the person's own symptoms) and which lanes
/// stand on top. Remembered on this device. The items of the page's settings
/// menu (`hlPageActions`).
struct TimelineChoicesMenu: View {
    let store: TimelineStore
    let wording: TimelineWording

    @Environment(\.appContainer) private var appContainer

    var body: some View {
        Section(String(localized: "timeline.choices.values")) {
            ForEach(Self.measurementOptions(available: read.availableSeries, isOn: moduleOn), id: \.self) { key in
                toggle(key)
            }
        }
        if moduleOn(.labs), !read.availableLabs.isEmpty {
            Menu(String(localized: "timeline.choices.labs")) {
                ForEach(read.availableLabs.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }) { marker in
                    choice(marker.name, key: marker.key)
                }
            }
        }
        if moduleOn(.illness), !read.availableSymptoms.isEmpty {
            Menu(String(localized: "timeline.choices.symptoms")) {
                ForEach(Self.symptomOptions(read.availableSymptoms), id: \.key) { option in
                    choice(Self.symptomTitle(option), key: option.key)
                }
            }
        }
        let lanes = TimelineLaneTrack.order.filter { !read.items(of: $0).isEmpty }
        if !lanes.isEmpty {
            Section(String(localized: "timeline.choices.lanes")) {
                ForEach(lanes, id: \.self) { lane in
                    let shown = !store.hiddenLanes.contains(lane)
                    Button(
                        wording.title(forLane: lane),
                        systemImage: shown ? "checkmark" : TimelineWording.symbol(forLane: lane)
                    ) {
                        store.setLane(lane, shown: !shown)
                    }
                    .accessibilityAddTraits(shown ? .isSelected : [])
                }
            }
        }
    }

    private var read: TimelineRead {
        store.read ?? TimelineRead(
            zoom: .quarter, range: TimelineRange(from: "", to: "", dataFrom: nil), lanes: [], bucket: .week, series: []
        )
    }

    private func toggle(_ key: String) -> some View {
        choice(wording.title(forValue: key), key: key)
    }

    /// One line on or off, the way a menu marks its chosen items: a checkmark.
    @ViewBuilder
    private func choice(_ title: String, key: String) -> some View {
        let shown = store.isShown(key)
        Button {
            store.setValue(key, shown: !shown)
        } label: {
            if shown {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityAddTraits(shown ? .isSelected : [])
    }

    private func moduleOn(_ key: ModuleKey) -> Bool {
        appContainer?.moduleGate.isEnabled(key) != false
    }

    /// The module that owns a value line on the web (`VALUE_OPTION_MODULE`);
    /// a line of a module that is off is not offered.
    nonisolated static let owningModule: [String: ModuleKey] = [
        "RESTING_HEART_RATE": .recovery,
        "HEART_RATE_VARIABILITY": .recovery,
        "SLEEP_DURATION": .sleep,
        "BLOOD_GLUCOSE": .glucose,
        "MOOD": .mood
    ]

    /// A symptom the person hid (`isActive: false`) stays choosable for the
    /// past it has, marked as hidden so it is not mistaken for a current one.
    nonisolated static func symptomTitle(_ option: TimelineSymptomOption) -> String {
        let name = option.label ?? String(localized: "timeline.symptoms.unnamed")
        return option.isActive ? name : String(localized: "timeline.symptoms.hidden \(name)")
    }

    /// The symptoms on offer: the current ones in the server's order, the
    /// hidden ones after them.
    nonisolated static func symptomOptions(_ options: [TimelineSymptomOption]) -> [TimelineSymptomOption] {
        options.filter(\.isActive) + options.filter { !$0.isActive }
    }

    /// The web's order first, then every other series the record has.
    nonisolated static let preferredOrder = [
        "BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA", "WEIGHT", "RESTING_HEART_RATE", "PULSE", "SLEEP_DURATION",
        "BLOOD_GLUCOSE", "BODY_FAT", "HEART_RATE_VARIABILITY", "ACTIVITY_STEPS", "MOOD"
    ]

    /// The measurement lines on offer, in order, without those of a module that is off.
    static func measurementOptions(available: [String], isOn: (ModuleKey) -> Bool) -> [String] {
        let rank = { (key: String) in preferredOrder.firstIndex(of: key) ?? preferredOrder.count }
        return available.enumerated()
            .filter { owningModule[$0.element].map(isOn) ?? true }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}
