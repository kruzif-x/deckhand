// HelpView.swift — the in-app help book (Help ▸ Deckhand Help, ⌘?).
//
// Plain text on purpose: this is the page someone reads when something is wrong, so it says what to do
// rather than what the feature is called.
import SwiftUI

struct HelpTopic: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let body: [HelpBlock]
}

enum HelpBlock {
    case heading(String)
    case text(String)
    case steps([String])
    case note(String)
    case keys([(String, String)])
}

struct HelpView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var selection: HelpTopic.ID?

    private var topics: [HelpTopic] { HelpContent.topics }

    var body: some View {
        NavigationSplitView {
            List(HelpContent.topics, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .navigationTitle("Deckhand Help")
        } detail: {
            ScrollView {
                if let topic = topics.first(where: { $0.id == selection }) ?? topics.first {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(topic.title).font(.title2.weight(.semibold))
                        ForEach(Array(topic.body.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(28)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            if selection == nil { selection = topics.first?.id }
        }
    }

    @ViewBuilder
    private func blockView(_ block: HelpBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text).font(.headline).padding(.top, 6)
        case .text(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .steps(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .note(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        Text(row.0).monospaced().frame(width: 110, alignment: .leading)
                        Text(row.1).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        HelpTopic(title: "Getting started", symbol: "play.circle", body: [
            .text("Deckhand drives the Stream Dock 293S directly. There is no vendor app to install."),
            .steps([
                "Plug the panel in. The sidebar shows Connected and the firmware version.",
                "Pick a profile on the left. The one marked On device is what the panel is showing.",
                "Click a key in the grid, then use the inspector to give it a graphic and an action.",
                "Press Send to Device (⇧⌘R) to push the profile to the panel.",
            ]),
            .note("Deckhand owns the USB device while it runs. Other tools should use its control socket rather than opening the panel themselves."),
        ]),

        HelpTopic(title: "Keys and actions", symbol: "keyboard", body: [
            .text("Every key can carry one action. Choose the type in the inspector:"),
            .steps([
                "Key combination — record a shortcut, e.g. ⌘⇧M. Needs the Accessibility permission.",
                "Open app — pick an application; pressing the key launches or focuses it.",
                "Open URL — any https:// or file:// address.",
                "Run script — a .sh, .zsh, .command, .scpt or executable. Output and errors go to the log.",
                "Mute / Volume up / Volume down — the system media keys, applied to whatever is playing.",
                "Next page / Previous page / First page — page navigation, wrapping at the ends.",
            ]),
            .text("Clear Action removes the binding but keeps the graphic. Labels are optional and show as a caption on the key."),
            .note("Hotkey actions need System Settings ▸ Privacy & Security ▸ Accessibility for Deckhand. Open app, URL, script and volume actions do not."),
        ]),

        HelpTopic(title: "Profiles and pages", symbol: "square.stack.3d.up", body: [
            .text("A profile is a full set of 18 slots. Up to 4 pages per profile, each page with its own graphics and bindings."),
            .steps([
                "＋ / － next to Profiles create and remove profiles; right-click for Rename, Duplicate, Remove.",
                "Selecting a profile only edits it — the panel keeps showing the one marked On device until you Send to Device.",
                "The page bar above the grid switches, adds and removes pages.",
                "File ▸ Save (⌘S) writes the profile's own .sdprofile file; Save As (⇧⌘S) picks a new one.",
            ]),
            .note("Removing a profile from the sidebar never deletes its files. A profile that was never saved asks first."),
        ]),

        HelpTopic(title: "Graphics and the library", symbol: "photo.on.rectangle", body: [
            .text("Choose Image… opens the library: a built-in set plus anything you imported."),
            .steps([
                "Click a tile to use it, then choose Edit Graphic… to crop, rotate or zoom, or Use Original.",
                "Import Images… adds files to ~/Library/Application Support/Deckhand/Library.",
                "Drag an image file straight onto a key to use it there.",
                "Load Images… fills keys 1–18 in filename order.",
            ]),
            .note("Images are stored upright and rotated once when sent, so the editor, the grid and the panel always agree."),
        ]),

        HelpTopic(title: "The 1×3 window", symbol: "rectangle.split.3x1", body: [
            .text("The strip beside keys 5 / 10 / 15 is display-only — it has no input. Each pane can show a widget:"),
            .steps([
                "Clock, Date, CPU, Memory, Page number or custom Text.",
                "Span the whole window draws one widget across all three panes.",
                "Widgets redraw once a second and only changed frames are sent to the panel.",
            ]),
        ]),

        HelpTopic(title: "MCP and automation", symbol: "terminal", body: [
            .text("Deckhand can be driven by other software — the bundled deckhand-mcp server, or your own scripts — over a local control socket."),
            .steps([
                "Settings ▸ General ▸ Allow MCP control turns that socket on or off.",
                "While it is off the socket does not exist at all, so nothing can connect; the MCP server reports that control is turned off.",
                "While it is on, the socket is ~/Library/Application Support/Deckhand/control.sock and speaks newline-delimited JSON, e.g. {\"cmd\":\"status\"}.",
            ]),
            .note("The socket is local to this Mac and reachable only by your user account. It is never opened to the network."),
        ]),

        HelpTopic(title: "Menu bar and login", symbol: "menubar.rectangle", body: [
            .text("Closing the window keeps Deckhand running in the menu bar, so the panel keeps working."),
            .keys([
                ("Open Deckhand", "bring the window back"),
                ("Send to Device", "re-push the on-device profile"),
                ("Next / Previous page", "turn the panel's page"),
                ("Quit Deckhand", "a real quit (asks about unsaved profiles)"),
            ]),
            .note("Settings ▸ General can turn the menu bar off (quit on close) and enable Open at login."),
        ]),

        HelpTopic(title: "Shortcuts", symbol: "command", body: [
            .keys([
                ("⌘N", "New profile"),
                ("⌘O", "Load profile"),
                ("⌘S / ⇧⌘S", "Save / Save As"),
                ("⇧⌘R", "Send to Device"),
                ("⌘⌫", "Remove profile from sidebar"),
                ("⌘D", "Duplicate profile"),
                ("⌘I", "Choose image for the selected key"),
                ("⇧⌘P", "Add page"),
                ("⌘,", "Settings"),
                ("⌘?", "This help"),
            ]),
        ]),

        HelpTopic(title: "Troubleshooting", symbol: "exclamationmark.triangle", body: [
            .heading("The panel stopped changing"),
            .text("If writes stop having any effect — even for keys that worked a minute ago — the panel's firmware has wedged. Unplug the USB-C cable, wait two seconds, plug it back in. Deckhand reconnects on its own."),
            .heading("Key presses do nothing"),
            .text("Check the sidebar says Connected. Presses are ignored while the panel is disconnected. Hotkey actions additionally need the Accessibility permission; open, URL and script actions do not."),
            .heading("A key does nothing but has an action"),
            .text("The action belongs to the on-device profile. If the sidebar shows “not on device” in the title bar, press Send to Device."),
            .heading("Nothing is logged"),
            .text("Logs live in ~/Library/Logs/Deckhand.log. Every push is recorded as “synced N images, blanked M, skipped K unchanged”."),
            .note("Deckhand 0.1b is a beta. If something looks wrong, the log line right before it usually names the cause."),
        ]),
    ]
}
