// Settings.swift — where the app keeps things on disk, and the preferences window that controls it.
import SwiftUI
import AppKit
import ServiceManagement

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Folder name under ~/Documents. Change this one constant when the project is renamed.
    static let appName = "Deckhand"

    /// Keeps the process (and therefore the panel) alive when the window is closed, with a status item.
    @Published var menuBarEnabled: Bool { didSet { defaults.set(menuBarEnabled, forKey: "menuBarEnabled") } }

    @Published var profilesFolder: String { didSet { defaults.set(profilesFolder, forKey: "profilesFolder") } }
    @Published var graphicsFolder: String { didSet { defaults.set(graphicsFolder, forKey: "graphicsFolder") } }

    private let defaults = UserDefaults.standard

    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }
    static var defaultProfilesPath: String { defaultRoot.appendingPathComponent("Profiles").path }
    static var defaultGraphicsPath: String { defaultRoot.appendingPathComponent("Graphics").path }

    init() {
        menuBarEnabled = defaults.object(forKey: "menuBarEnabled") as? Bool ?? true
        profilesFolder = defaults.string(forKey: "profilesFolder") ?? Self.defaultProfilesPath
        graphicsFolder = defaults.string(forKey: "graphicsFolder") ?? Self.defaultGraphicsPath
        createFolders()
    }

    var profilesURL: URL { Self.url(from: profilesFolder) }
    var graphicsURL: URL { Self.url(from: graphicsFolder) }

    static func url(from path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    func createFolders() {
        for url in [profilesURL, graphicsURL] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func resetToDefaults() {
        profilesFolder = Self.defaultProfilesPath
        graphicsFolder = Self.defaultGraphicsPath
        createFolders()
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var error: String?
    @State private var loginTick = 0        // re-reads SMAppService after a change

    var body: some View {
        Form {
            Section("General") {
                Toggle("Keep running in the menu bar when the window is closed",
                       isOn: $settings.menuBarEnabled)
                Text("The panel keeps working with no window open; the menu-bar icon brings Deckhand back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { wanted in
                        do {
                            if wanted { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            Log.write("launch at login \(wanted ? "enabled" : "disabled")")
                        } catch {
                            Log.write("launch at login failed: \(error.localizedDescription)")
                        }
                        loginTick += 1
                    })) {
                    Text("Open Deckhand at login")
                }
                .id(loginTick)
            }

            Section(t("Storage")) {
                folderRow(title: "Profiles",
                          caption: "Where Save and Save As put .sdprofile files.",
                          path: $settings.profilesFolder,
                          fallback: AppSettings.defaultProfilesPath)

                folderRow(title: "Graphics",
                          caption: "Starting folder when you pick an image for a key.",
                          path: $settings.graphicsFolder,
                          fallback: AppSettings.defaultGraphicsPath)
            }

            Section {
                HStack {
                    Spacer()
                    Button(t("Restore Defaults")) {
                        settings.resetToDefaults()
                    }
                }
            } footer: {
                Text("Defaults live in \(AppSettings.defaultRoot.path). Profiles already open stay where they are — this only changes where new files go.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 470)
        .alert("Folder problem", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func folderRow(title: String, caption: String, path: Binding<String>, fallback: String) -> some View {
        LabeledContent(t(title)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(path.wrappedValue)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(t("Choose…")) { choose(path) }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.url(from: path.wrappedValue)])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help(t("Show in Finder"))
                    .disabled(!FileManager.default.fileExists(atPath: path.wrappedValue))

                    Button {
                        path.wrappedValue = fallback
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help(t("Reset to the default folder"))
                    .disabled(path.wrappedValue == fallback)
                }
                Text(t(caption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choose(_ path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = AppSettings.url(from: path.wrappedValue)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path.wrappedValue = url.path
        settings.createFolders()
        if !FileManager.default.fileExists(atPath: url.path) {
            error = "That folder could not be created."
        }
    }
}
