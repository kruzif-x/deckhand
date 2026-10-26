// InspectorView.swift — the right-hand inspector, standard .grouped Form.
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct InspectorView: View {
    @Binding var slot: Int?
    var onChooseImage: ((Int) -> Void)? = nil
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var deck: DeckModel
    @State private var recording = false
    @State private var choosing = false

    var body: some View {
        Form {
            if let index = slot, let profile = currentProfile, let current = profile.slot(index) {
                Section(t("Key")) {
                    LabeledContent(t("Number")) {
                        Text("\(index)").monospacedDigit()
                    }
                    if !current.isWindow {
                        TextField(t("Label"), text: slotBinding(index, \.label), prompt: Text(t("Optional")))
                    }
                    LabeledContent(t("Kind")) {
                        Text(current.isWindow ? "Window pane" : "Button")
                    }
                }

                if !current.isWindow {
                Section(t("Graphic")) {
                    HStack(spacing: 12) {
                        KeyTile(slot: current, image: imageURL(current, profile: profile),
                                widgetPage: (profile.activePage + 1, profile.pages.count),
                                selected: false, pressed: false, size: 72)
                        VStack(alignment: .leading, spacing: 6) {
                            Button(t("Choose Image…")) {
                                if let onChooseImage { onChooseImage(index) } else { choosing = true }
                            }
                            Button(t("Clear Image")) {
                                mutate(index) { $0.imageFile = nil }
                            }
                            .disabled(current.imageFile == nil)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Images are resized to \(ImagePrep.size(for: index))×\(ImagePrep.size(for: index)) and written to the key immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }

                if !current.isWindow {
                    Section(t("Action")) {
                        if current.action.kind != .none {
                            LabeledContent(t("Bound to")) {
                                HStack(spacing: 8) {
                                    Text(current.action.summary.isEmpty ? current.action.kind.title
                                                                        : current.action.summary)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Button(t("Clear Action")) { clearAction(index) }
                                }
                            }
                        }

                        Picker(t("Type"), selection: kindBinding(index)) {
                            ForEach(ActionKind.selectableCases) { kind in
                                Label(kind.title, systemImage: kind.symbol).tag(kind)
                            }
                        }

                        switch current.action.kind {
                        case .none:
                            Text(t("This key does nothing."))
                                .foregroundStyle(.secondary)
                        case .hotkey:
                            LabeledContent(t("Shortcut")) {
                                HStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(recording ? Color.accentColor.opacity(0.15) : Color(nsColor: .textBackgroundColor))
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.15))
                                        HotkeyRecorder(keyCode: hotkeyCode(index),
                                                       flags: hotkeyFlags(index),
                                                       recording: $recording)
                                        Text(recording ? "Press a key…" :
                                                HotkeyFormatter.describe(keyCode: current.action.keyCode,
                                                                         flags: NSEvent.ModifierFlags(rawValue: current.action.modifierFlags)))
                                            .font(.system(.body, design: .rounded))
                                            .allowsHitTesting(false)
                                    }
                                    .frame(width: 132, height: 26)
                                    .onTapGesture { recording = true }
                                    Button(t("Record")) { recording = true }
                                        .buttonStyle(.bordered)
                                }
                            }

                        case .text:
                            EmptyView()      // retired: "Type text" is no longer offered
                        case .openApp:
                            LabeledContent(t("Application")) {
                                Button("Choose…") { chooseApp(index) }
                                Text(appName(current.action.target))
                                    .foregroundStyle(.secondary)
                            }
                        case .openURL:
                            TextField("URL", text: slotBinding(index, \.action.target),
                                      prompt: Text("https://example.com"))
                        case .mute, .volumeUp, .volumeDown, .pageNext, .pagePrevious, .pageHome:
                            Text(current.action.kind.kindExplanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        case .page:
                            Picker("Go", selection: slotBinding(index, \.action.target)) {
                                Text("Next page").tag("next")
                                Text("Previous page").tag("previous")
                                Text("First page").tag("home")
                            }
                        case .shell:
                            LabeledContent(t("Script")) {
                                Button("Choose Script…") { chooseScript(index) }
                                Text(scriptName(current.action.target))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if !current.action.target.isEmpty {
                                Text(current.action.target)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Section("Panes") {
                            // one row per physical pane, so the whole window is configured in one place
                            ForEach(Array(windowSlots.enumerated()), id: \.element.id) { position, slot in
                                Picker(paneName(position), selection: slotWidgetKindBinding(slot.id)) {
                                    ForEach(WidgetKind.allCases) { kind in
                                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        Text("Each pane is an independent display. The panel sends no input for them, so they are read-outs, not buttons.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if current.widget?.kind == .text {
                            Section("This Pane") {
                                TextField("Text", text: widgetTextBinding(index), prompt: Text(t("Label")))
                            }
                        }
                        if current.widget?.kind == .clock {
                            Section("This Pane") {
                                Toggle("Show seconds", isOn: widgetSecondsBinding(index))
                            }
                        }
                        Section("Preview") {
                            HStack {
                                Spacer()
                                widgetPreview(current.widget)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            } else {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "square.dashed")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No Key Selected")
                            .font(.headline)
                        Text("Select a key above to edit it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            guard let index = slot, case .success(let url) = result, let profile = currentProfile else { return }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            guard let name = store.importImage(from: url, for: Slot(id: index), profileID: profile.id,
                                               page: profile.activePage) else { return }
            mutate(index) { $0.imageFile = name }
            pushToDevice(index)
        }
    }

    // MARK: bindings

    private var currentProfile: Profile? {
        store.profiles.first { $0.id == store.selection }
    }

    private func mutate(_ index: Int, _ body: @escaping (inout Slot) -> Void) {
        guard let id = store.selection,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        store.profiles[idx].update(index) { body(&$0) }
        store.save()
    }

    private func slotBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<Slot, T>) -> Binding<T> {
        Binding(
            get: {
                currentProfile?.slot(index)?[keyPath: keyPath] ?? Slot(id: index)[keyPath: keyPath]
            },
            set: { newValue in mutate(index) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func kindBinding(_ index: Int) -> Binding<ActionKind> {
        Binding(
            get: { currentProfile?.slot(index)?.action.kind ?? .none },
            set: { newValue in mutate(index) { $0.action.kind = newValue } }
        )
    }

    private var spanMode: Bool { currentProfile?.window?.mode == .span }

    private var windowSlots: [Slot] {
        (currentProfile?.slots ?? []).filter(\.isWindow)
    }

    private func paneName(_ position: Int) -> String {
        ["Top pane", "Middle pane", "Bottom pane"].indices.contains(position)
            ? ["Top pane", "Middle pane", "Bottom pane"][position]
            : "Pane \(position + 1)"
    }

    private func slotWidgetKindBinding(_ slotID: Int) -> Binding<WidgetKind> {
        Binding(
            get: { currentProfile?.slot(slotID)?.widget?.kind ?? .none },
            set: { newValue in
                mutate(slotID) { slot in
                    var widget = slot.widget ?? WidgetConfig()
                    widget.kind = newValue
                    slot.widget = newValue == .none ? nil : widget
                }
            }
        )
    }

    private var spanWidget: WidgetConfig? {
        guard let window = currentProfile?.window, window.mode == .span else { return nil }
        return window.widget
    }

    private var stripPreview: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let config = spanWidget, config.kind != .none,
               let strip = WidgetRenderer.stripImage(for: config,
                                                     page: ((currentProfile?.activePage ?? 0) + 1,
                                                            currentProfile?.pages.count ?? 1),
                                                     now: context.date,
                                                     bleed: currentProfile?.window?.bleed ?? true) {
                Image(decorative: strip, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("Choose a widget to see it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mutateWindow(_ body: @escaping (inout WindowConfig) -> Void) {
        guard let id = store.selection,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        var window = store.profiles[idx].window ?? WindowConfig()
        body(&window)
        store.profiles[idx].window = window
        store.save()
    }

    private func paneHeightBinding() -> Binding<Int> {
        Binding(get: { currentProfile?.window?.paneHeight ?? 80 },
                set: { newValue in mutateWindow { $0.paneHeight = newValue } })
    }

    private func seamBinding() -> Binding<SeamStyle> {
        Binding(get: { currentProfile?.window?.seam ?? .separate },
                set: { newValue in mutateWindow { $0.seam = newValue } })
    }

    private func windowModeBinding() -> Binding<WindowMode> {
        Binding(get: { currentProfile?.window?.mode ?? .perPane },
                set: { newValue in mutateWindow { $0.mode = newValue } })
    }

    private func windowWidgetKindBinding() -> Binding<WidgetKind> {
        Binding(get: { currentProfile?.window?.widget.kind ?? .none },
                set: { newValue in mutateWindow { $0.widget.kind = newValue } })
    }

    private func windowWidgetTextBinding() -> Binding<String> {
        Binding(get: { currentProfile?.window?.widget.text ?? "" },
                set: { newValue in mutateWindow { $0.widget.text = newValue } })
    }

    private func windowWidgetSecondsBinding() -> Binding<Bool> {
        Binding(get: { currentProfile?.window?.widget.showsSeconds ?? false },
                set: { newValue in mutateWindow { $0.widget.showsSeconds = newValue } })
    }

    private func widgetKindBinding(_ index: Int) -> Binding<WidgetKind> {
        Binding(
            get: { currentProfile?.slot(index)?.widget?.kind ?? .none },
            set: { newValue in
                mutate(index) { slot in
                    var widget = slot.widget ?? WidgetConfig()
                    widget.kind = newValue
                    slot.widget = newValue == .none ? nil : widget
                }
            }
        )
    }

    private func widgetTextBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { currentProfile?.slot(index)?.widget?.text ?? "" },
            set: { newValue in mutate(index) { slot in slot.widget?.text = newValue } }
        )
    }

    private func widgetSecondsBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { currentProfile?.slot(index)?.widget?.showsSeconds ?? false },
            set: { newValue in mutate(index) { slot in slot.widget?.showsSeconds = newValue } }
        )
    }

    @ViewBuilder
    private func widgetPreview(_ widget: WidgetConfig?) -> some View {
        if let widget, widget.kind != .none,
           let cg = WidgetRenderer.image(for: widget,
                                         page: ((currentProfile?.activePage ?? 0) + 1,
                                                currentProfile?.pages.count ?? 1)) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Text("Choose a widget to see it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func hotkeyCode(_ index: Int) -> Binding<UInt16> {
        Binding(
            get: { currentProfile?.slot(index)?.action.keyCode ?? 0 },
            set: { newValue in mutate(index) { $0.action.keyCode = newValue } }
        )
    }

    private func hotkeyFlags(_ index: Int) -> Binding<UInt> {
        Binding(
            get: { currentProfile?.slot(index)?.action.modifierFlags ?? 0 },
            set: { newValue in mutate(index) { $0.action.modifierFlags = newValue } }
        )
    }

    // MARK: helpers

    private func imageURL(_ slot: Slot, profile: Profile) -> URL? {
        guard let name = slot.imageFile else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deckhand/images/\(profile.id.uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func appName(_ path: String) -> String {
        path.isEmpty ? "None" : (path as NSString).lastPathComponent
    }

    private func clearAction(_ index: Int) {
        mutate(index) { $0.action = KeyAction() }
    }

    private func chooseScript(_ index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a shell script, AppleScript or executable to run when this key is pressed"
        if panel.runModal() == .OK, let url = panel.url {
            mutate(index) { $0.action.target = url.path }
        }
    }

    private func scriptName(_ path: String) -> String {
        path.isEmpty ? "None" : (path as NSString).lastPathComponent
    }

    private func chooseApp(_ index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            mutate(index) { $0.action.target = url.path }
        }
    }

    private func pushToDevice(_ index: Int) {
        guard let profile = currentProfile, let slot = profile.slot(index),
              let url = store.imageURL(profileID: profile.id, slot: slot, page: profile.activePage),
              let data = ImagePrep.prepare(url: url, side: ImagePrep.size(for: index)) else { return }
        deck.sendSingle(slot: index, data: data)
    }
}

struct PermissionRow: View {
    @State private var granted = HotkeyEngine.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Keystrokes need Accessibility permission", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text("Grant it once in System Settings › Privacy & Security › Accessibility. Without it, key combinations are ignored by macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check Again") { granted = HotkeyEngine.isTrusted }
            }
            .buttonStyle(.link)
        }
    }
}
