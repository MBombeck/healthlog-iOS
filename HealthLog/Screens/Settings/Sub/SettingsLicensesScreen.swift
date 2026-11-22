import SwiftUI

/// Settings > About > Licenses: the app's own license with the way to its
/// source code, then every Swift package the app resolves with its license.
/// MIT, BSD and Apache-2.0 ask that their notices travel with the binary;
/// this page is where they do.
struct SettingsLicensesScreen: View {
    @Environment(\.openURL) private var openURL
    var packages: [ThirdPartyLicense] = ThirdPartyLicenseCatalog.all

    var body: some View {
        HLPage {
            appCard
            packagesCard
        }
        .navigationTitle("settings.about.licenses")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.licenses")
    }

    private var appCard: some View {
        HLCard("HealthLog", layout: .rows) {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("settings.licenses.appLicense")
                    .hlText(.prose)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: HealthLogAppLicense.requiredNotice)
                    .hlText(.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let url = HealthLogAppLicense.licenseURL {
                HLSettingsActionRow(title: "settings.licenses.licenseTerms", presents: .external) {
                    openURL(url)
                }
                .accessibilityIdentifier("settings.licenses.appLicenseLink")
            }
            if let url = HealthLogAppLicense.sourceCodeURL {
                HLSettingsActionRow(title: "settings.licenses.sourceCode", presents: .external) {
                    openURL(url)
                }
                .accessibilityIdentifier("settings.licenses.sourceCodeLink")
            }
        }
    }

    private var packagesCard: some View {
        HLCard("settings.licenses.packages", layout: .rows) {
            ForEach(packages) { package in
                HLRow(
                    title: Text(verbatim: package.name),
                    detail: HLRowDetail.text([package.license, package.version]),
                    accessory: .chevron
                )
                .hlRowLink { SettingsLicenseDetailScreen(package: package) }
                .accessibilityIdentifier("settings.licenses.package.\(package.identity)")
            }
        }
        .accessibilityIdentifier("settings.licenses.packages")
    }
}

/// One package: version, license and source, then the full license text and,
/// where the package ships one, its NOTICE file. The text runs as paragraphs
/// at the page's reading width (``ThirdPartyLicense/reflowed(_:)``) and is
/// selectable, so it can be copied.
struct SettingsLicenseDetailScreen: View {
    @Environment(\.openURL) private var openURL
    let package: ThirdPartyLicense

    var body: some View {
        HLPage {
            HLCard(object: Text(verbatim: package.name), layout: .rows) {
                HLSettingsStatRow(label: Text("Version"), value: package.version)
                HLSettingsStatRow(label: Text("settings.licenses.licenseType"), value: package.license)
                if let url = package.sourceURL {
                    HLSettingsActionRow(title: "settings.licenses.sourceCode", presents: .external) {
                        openURL(url)
                    }
                    .accessibilityIdentifier("settings.licenses.detail.sourceLink")
                }
            }
            textCard("settings.licenses.text", text: package.text, identifier: "settings.licenses.detail.text")
            if let notice = package.notice {
                textCard("settings.licenses.notice", text: notice, identifier: "settings.licenses.detail.notice")
            }
        }
        .navigationTitle(Text(verbatim: package.name))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.licenses.detail")
    }

    private func textCard(_ title: LocalizedStringKey, text: String, identifier: String) -> some View {
        HLCard(title) {
            Text(verbatim: ThirdPartyLicense.reflowed(text))
                .hlText(.prose)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier(identifier)
    }
}
