import AppKit
import SwiftUI

@main
struct SandboxProbeApp: App {
    @NSApplicationDelegateAdaptor(SandboxProbeDelegate.self)
    private var appDelegate
    @StateObject private var model = SandboxProbeModel()

    var body: some Scene {
        WindowGroup {
            SandboxProbeView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 560)
        }
        .defaultSize(width: 760, height: 640)
    }
}

private final class SandboxProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments

        guard arguments.contains("--diagnostic") || arguments.contains("--restore-only") else {
            return
        }

        Task { @MainActor in
            let model = SandboxProbeModel()
            model.runDiagnostic(restoreOnly: arguments.contains("--restore-only"))
        }
    }
}

@MainActor
private final class SandboxProbeModel: ObservableObject {
    struct PathResult: Identifiable {
        let id: String
        let path: String
        let state: String
        let detail: String
    }

    @Published private(set) var pathResults: [PathResult] = []
    @Published private(set) var bookmarkResult = "No saved folder"
    @Published private(set) var sshResult = "Not tested"

    private let bookmarkKey = "selected-folder-bookmark"

    init() {
        inspectCandidatePaths()
        restoreBookmark()
    }

    func inspectCandidatePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        pathResults = [".codex", ".agents", ".claude", ".ssh"].map { relativePath in
            let url = home.appendingPathComponent(relativePath)

            guard FileManager.default.fileExists(atPath: url.path) else {
                return PathResult(
                    id: relativePath,
                    path: "~/" + relativePath,
                    state: "Missing",
                    detail: "The directory does not exist."
                )
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                )
                return PathResult(
                    id: relativePath,
                    path: "~/" + relativePath,
                    state: "Readable",
                    detail: "\(contents.count) entries visible."
                )
            } catch {
                return PathResult(
                    id: relativePath,
                    path: "~/" + relativePath,
                    state: "Denied",
                    detail: error.localizedDescription
                )
            }
        }
    }

    func chooseFolder() {
        let panel = makeOpenPanel()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        saveBookmark(for: url)
    }

    func runDiagnostic(restoreOnly: Bool) {
        inspectCandidatePaths()

        if restoreOnly {
            restoreBookmark()
        } else {
            createContainerBookmarkFixture()
        }

        testSSHLaunch()
        UserDefaults.standard.synchronize()

        let pathReport = pathResults
            .map { "path:\($0.id):\($0.state)" }
            .joined(separator: "\n")
        let report = """
        \(pathReport)
        bookmark:\(bookmarkResult)
        ssh:\(sshResult)
        """

        FileHandle.standardOutput.write(Data((report + "\n").utf8))
        NSApplication.shared.terminate(nil)
    }

    private func createContainerBookmarkFixture() {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let fixture = applicationSupport
                .appendingPathComponent("KitroomSandboxProbe", isDirectory: true)
            try FileManager.default.createDirectory(
                at: fixture,
                withIntermediateDirectories: true
            )
            let marker = fixture.appendingPathComponent("marker.txt")
            try Data("bookmark fixture\n".utf8).write(to: marker, options: .atomic)
            saveBookmark(for: fixture)
        } catch {
            bookmarkResult = "Fixture failed: \(error.localizedDescription)"
        }
    }

    private func saveBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            bookmarkResult = inspectBookmarkedFolder(url, prefix: "Selected")
        } catch {
            bookmarkResult = "Bookmark failed: \(error.localizedDescription)"
        }
    }

    private func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose a sandbox test folder"
        panel.message = "Kitroom will save a security-scoped bookmark for this test folder."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel
    }

    func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            bookmarkResult = "No saved folder"
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let prefix = isStale ? "Restored stale bookmark" : "Restored bookmark"
            bookmarkResult = inspectBookmarkedFolder(url, prefix: prefix)
        } catch {
            bookmarkResult = "Restore failed: \(error.localizedDescription)"
        }
    }

    func testSSHLaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "localhost"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            sshResult = "Launched; exit code \(process.terminationStatus)"
        } catch {
            sshResult = "Launch denied: \(error.localizedDescription)"
        }
    }

    private func inspectBookmarkedFolder(_ url: URL, prefix: String) -> String {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )
            return "\(prefix): readable, \(contents.count) entries"
        } catch {
            return "\(prefix): denied, \(error.localizedDescription)"
        }
    }
}

private struct SandboxProbeView: View {
    @EnvironmentObject private var model: SandboxProbeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kitroom sandbox probe")
                        .font(.largeTitle.bold())
                    Text("Read-only feasibility checks for local agent paths, security-scoped bookmarks, and OpenSSH.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Direct home-directory access") {
                    VStack(spacing: 0) {
                        ForEach(model.pathResults) { result in
                            HStack {
                                Text(result.path)
                                    .monospaced()
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(result.state)
                                        .font(.callout.weight(.medium))
                                    Text(result.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 9)

                            if result.id != model.pathResults.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }

                GroupBox("Security-scoped bookmark") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.bookmarkResult)
                            .accessibilityLabel("Bookmark result: \(model.bookmarkResult)")

                        HStack {
                            Button("Choose test folder") {
                                model.chooseFolder()
                            }

                            Button("Restore saved folder") {
                                model.restoreBookmark()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("OpenSSH process") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("/usr/bin/ssh -G localhost")
                                .monospaced()
                            Text(model.sshResult)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("SSH result: \(model.sshResult)")
                        }

                        Spacer()

                        Button("Test SSH launch") {
                            model.testSSHLaunch()
                        }
                    }
                    .padding(.vertical, 4)
                }

                Text("This probe does not inspect file contents, connect to a remote host, or modify coding-agent configuration.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }
}
