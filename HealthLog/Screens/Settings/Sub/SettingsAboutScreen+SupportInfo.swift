import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

// #134 (server v1.43) — "Support-Info kopieren" on About: app, iOS, device
// class, language, server version, time zone, modules, AI states, the Apple
// Health block and the recent request ids as plain text on the clipboard
// (``SupportInfoReport``). Copying is the whole effect: nothing is sent
// anywhere. The two reads it makes (`GET /api/version` and
// `GET /api/integrations/healthkit`) run side by side and are bounded, so an
// offline phone still copies at once; the rest is what the app already holds.

extension SettingsAboutScreen {
    enum SupportInfoCopyState: Equatable {
        case idle
        case copying
        case copied
    }

    /// 1.4 B4 — one row, one heading: "Support-Info kopieren" names it, the
    /// footer says what goes on the clipboard.
    var supportCard: some View {
        HLSettingsCard(footer: "settings.about.support.footer") {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSettingsActionRow(
                    icon: "doc.on.doc",
                    title: "settings.about.support.copy",
                    presents: .confirm
                ) {
                    Task { await copySupportInfo() }
                }
                .disabled(supportInfoState == .copying)
                .accessibilityIdentifier("settings.about.copySupportInfo")
                if supportInfoState == .copied {
                    Text("settings.about.support.copied")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.about.supportInfoCopied")
                }
            }
        }
    }

    @MainActor
    private func copySupportInfo() async {
        supportInfoState = .copying
        async let appleHealth = Self.appleHealthSummary(repo: container?.settingsRepo)
        let server = await Self.serverVersion(api: container?.api)
        let health = await appleHealth
        let text = SupportInfoReport(SupportInfoReport.Input(
            generatedAt: Date(),
            build: Self.buildMetadata(),
            osVersion: Self.osVersion,
            deviceClass: Self.deviceClass,
            appLanguage: Bundle.main.preferredLocalizations.first,
            server: server,
            lastKnownServerVersion: UserDefaults.standard.string(forKey: KnownServerVersion.defaultsKey),
            failures: RecentFailureLog.shared.snapshot(),
            timeZone: container?.settingsStore.accountTimeZoneIdentifier ?? container?.settingsStore.profile?.timezone,
            modules: container?.moduleGate.modules,
            ai: container?.aiCapabilityGate.account,
            appleHealth: health.summary,
            appleHealthLoadFailed: health.failed
        )).text
        #if canImport(UIKit)
            UIPasteboard.general.string = text
        #endif
        supportInfoState = .copied
    }

    /// `GET /api/version`, given at most ``serverVersionBudget``. The patient
    /// session waits for connectivity, which is right for the outbox and
    /// wrong for a button: past the budget the report says "last known".
    private static func serverVersion(api: APIClientProtocol?) async -> ServerVersionInfo? {
        guard let api else { return nil }
        return await withTaskGroup(of: ServerVersionInfo?.self) { group in
            group.addTask { try? await api.fetchServerVersion() }
            group.addTask {
                try? await Task.sleep(for: serverVersionBudget)
                return nil
            }
            let first = await group.next().flatMap(\.self)
            group.cancelAll()
            return first
        }
    }

    private static let serverVersionBudget: Duration = .seconds(4)

    /// #134 — `GET /api/integrations/healthkit` for the Apple Health block,
    /// fresh and within the same budget. `failed` when it did not answer.
    private static func appleHealthSummary(repo: SettingsRepository?) async -> (summary: HKServerSyncHealthSummary?, failed: Bool) {
        guard let repo else { return (nil, true) }
        let config = await withTaskGroup(of: HealthKitSyncConfig?.self) { group in
            group.addTask { try? await repo.healthKitConfig() }
            group.addTask {
                try? await Task.sleep(for: serverVersionBudget)
                return nil
            }
            let first = await group.next().flatMap(\.self)
            group.cancelAll()
            return first
        }
        return (config.map(HKServerSyncHealthSummary.init(config:)), config == nil)
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// `iPhone` or `iPad`: the model class, never the name the owner gave
    /// the device.
    private static var deviceClass: String {
        #if canImport(UIKit)
            UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
            "unknown"
        #endif
    }
}
