import SwiftUI

struct SettingsProductView: View {
    var body: some View {
        Form {
            Section("Safety") {
                LabeledContent("Mutation policy") {
                    Text("Preview, approve, apply, verify")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Mutation policy")
                .accessibilityValue("Preview, approve, apply, verify")
                LabeledContent("Remote access") {
                    Text("Existing OpenSSH aliases and trust")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Remote access")
                .accessibilityValue("Existing OpenSSH aliases and trust")
                LabeledContent("Administrator access") {
                    Text("Never requested")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Administrator access")
                .accessibilityValue("Never requested")
            }

            Section("Backups") {
                Text(
                    "Kitroom retains local operation backups until you delete an eligible backup from Activity. Deletion requires confirmation and leaves the activity record intact."
                )
                Text(
                    "Remote backups are not deleted by Kitroom. Manage their retention directly on the SSH host after confirming that recovery is no longer needed."
                )
                .foregroundStyle(.secondary)
            }

            Section("Privacy and diagnostics") {
                LabeledContent("Telemetry") {
                    Text("None")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Telemetry")
                .accessibilityValue("None")
                LabeledContent("Update checks") {
                    Text("Manual")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Update checks")
                .accessibilityValue("Manual")
                Text(
                    "Host inventory and operation history stay in Kitroom's local application-support store. Diagnostic exports redact aliases, paths, credentials, tokens, private keys, and configuration contents."
                )
                .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: version)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Version")
                    .accessibilityValue(version)
                LabeledContent("Distribution") {
                    Text("Early development build")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Distribution")
                .accessibilityValue("Early development build")
                Link(
                    "Project documentation",
                    destination: URL(
                        string: "https://github.com/l0cka/kitroom"
                    )!
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var version: String {
        let short = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        return switch (short, build) {
        case let (.some(short), .some(build)):
            "\(short) (\(build))"
        case let (.some(short), .none):
            short
        default:
            "Development"
        }
    }
}
