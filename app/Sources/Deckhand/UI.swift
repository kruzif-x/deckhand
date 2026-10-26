// UI.swift — the whole interface. Native SwiftUI, standard macOS controls, HIG spacing.
import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor
final class DeckModel: ObservableObject {
    @Published var connected = false
    @Published var firmware: String?
    @Published var info: DeviceSummary = DeviceSummary()
    @Published var lastPressed: Int?
    @Published var sendState: SendState = .idle
    @Published var needsAccessibility = !HotkeyEngine.isTrusted

    enum SendState: Equatable { case idle, sending, sent(Int), failed(String) }

    private let device = DeckDevice()
    weak var store: ProfileStore?
    var onWidgetTick: (() -> Void)?
    private var widgetTimer: Timer?

    init() {
        device.onConnectionChange = { [weak self] ok in
            guard let self else { return }
            self.connectionEpoch += 1        // panel content is unknown after a re-plug
            self.sentDigests.removeAll()
            self.connected = ok
            if ok {
                self.firmware = self.device.firmware
                self.info = self.device.deviceSummary
            }
            Log.write(ok ? "panel connected (firmware \(self.device.firmware ?? "unknown"))"
                          : "panel disconnected")
        }
        device.onKeyPress = { [weak self] key in
            guard let self else { return }
            self.lastPressed = key
            if let live = self.store?.liveProfileID,
               let profile = self.store?.profiles.first(where: { $0.id == live }),
               let slot = profile.slot(key) {
                Log.write("key \(key) pressed → \(slot.action.kind.rawValue): \(slot.action.summary)")
                if let target = slot.action.kind.pageTarget ?? (slot.action.kind == .page ? slot.action.target : nil) {
                    NotificationCenter.default.post(name: .init("deck.pageRequest"), object: nil,
                                                    userInfo: ["target": target])
                } else {
                    HotkeyEngine.run(slot.action)
                }
            } else {
                Log.write("key \(key) pressed → no profile selected")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if self.lastPressed == key { self.lastPressed = nil }
            }
        }
        widgetTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.onWidgetTick?() }
        }
        device.connectIfPossible()
        info = device.deviceSummary
        Log.write("accessibility trusted=\(HotkeyEngine.isTrusted)")
    }

    func reconnect() { device.connectIfPossible() }

    // MARK: pushing to the panel
    //
    // Two things matter here: only slots whose rendered bytes changed are written (a full 18-slot
    // resend is ~0.6 s of USB traffic for nothing), and the whole loop runs off the main thread so a
    // slow transfer can never stall the window.
    private let sendQueue = DispatchQueue(label: "deckhand.send", qos: .userInitiated)
    private var sentDigests: [Int: UInt64] = [:]
    private var sentContext = ""
    /// Bumped on every connect/disconnect: the panel's content is unknown after a re-plug.
    private var connectionEpoch = 0

    private static func digest(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325        // FNV-1a, 64-bit
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Push the profile to the panel. Unchanged slots are skipped unless `force` is set; the cache is
    /// invalidated whenever the profile, the page or the device connection changes.
    func send(_ profile: Profile, images: [(Int, URL)], force requestedForce: Bool = false) {
        guard connected else { sendState = .failed("No device"); return }

        var force = requestedForce
        let context = "\(profile.id.uuidString)|\(profile.activePage)|\(connectionEpoch)"
        if context != sentContext {
            sentDigests.removeAll()
            sentContext = context
            force = true          // new page/profile/connection: the panel must be repainted
        }

        sendState = .sending
        let snapshot = profile
        let list = images
        let known = sentDigests

        sendQueue.async { [weak self] in
            guard let self else { return }
            self.device.prepareForWrite()

            var digests = known
            var written = 0, blanked = 0, skipped = 0, failed = 0

            for slot in snapshot.slots {
                let isPicture = list.contains { $0.0 == slot.id }
                let payload: Data?
                if let entry = list.first(where: { $0.0 == slot.id }) {
                    payload = ImagePrep.prepare(url: entry.1, side: ImagePrep.size(for: slot.id))
                } else if !slot.isWindow || slot.widget == nil {
                    // empty slot on this page: paint it black, or the panel keeps showing whatever
                    // the previous page left there
                    payload = self.blankKeyImage(slot: slot.id)
                } else {
                    payload = nil
                }
                guard let payload else { continue }

                let sum = Self.digest(payload)
                if !force, digests[slot.id] == sum { skipped += 1; continue }

                if self.device.setImage(slot: slot.id, jpeg: payload) {
                    digests[slot.id] = sum
                    if isPicture { written += 1 } else { blanked += 1 }
                } else {
                    failed += 1
                }
            }

            self.device.refresh()

            DispatchQueue.main.async {
                self.sentDigests = digests
                self.sendState = failed > 0 ? .failed("\(failed) key(s) rejected") : .sent(written)
                Log.write("synced \(written) images, blanked \(blanked), skipped \(skipped) unchanged"
                          + (failed > 0 ? ", \(failed) failed" : "")
                          + " · profile \(snapshot.name) page \(snapshot.activePage + 1)")
            }
        }
    }

    func sendSingle(slot: Int, data: Data, quiet: Bool = false) {
        guard connected else { sendState = .failed("No device"); return }
        if device.setImage(slot: slot, jpeg: data) {
            device.refresh()
            sendState = .sent(1)
            if !quiet { Log.write("wrote slot \(slot) (\(data.count) bytes)") }
        } else {
            sendState = .failed("Write rejected")
        }
    }

    private var blankCache: [Int: Data] = [:]

    /// Solid-black image at a slot's own size, used to blank keys that have no picture on the
    /// page being pushed.
    private func blankKeyImage(slot: Int) -> Data? {
        if let cached = blankCache[slot] { return cached }
        let side = ImagePrep.size(for: slot)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let img = ctx.makeImage(),
              let data = ImagePrep.prepareTall(img, side: side, height: side) else { return nil }
        blankCache[slot] = data
        return data
    }

    func setPage(_ index: Int) {
        device.setPage(index)
        Log.write("firmware page → \(index)")
    }

    func setBrightness(_ value: UInt8) {
        device.setBrightness(value)
        Log.write("brightness → \(value)%")
    }

    func clearDevice() {
        guard connected else { return }
        device.clearAll()
        sendState = .sent(0)
    }
}

// MARK: - root

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var deck: DeckModel

    @State private var showInspector = true
    @State private var selectedSlot: Int? = 1     // first key selected on launch
    @State private var pendingSlot: Int?
    @State private var editing: EditTarget?
    @State private var picking: PickTarget?
    @State private var libraryTarget: LibraryTarget?
    @State private var widgetCache: [Int: Data] = [:]

    struct LibraryTarget: Identifiable {
        let id = UUID()
        let slot: Int
    }

    struct PickTarget: Identifiable {
        let id = UUID()
        let image: CGImage
        let slot: Int
        let name: String
    }

    struct EditTarget: Identifiable { let id = UUID(); let image: CGImage; let slot: Int }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let p = currentProfile, !HotkeyEngine.isTrusted,
                   p.slots.contains(where: { $0.action.kind == .hotkey || $0.action.kind == .text }) {
                    PermissionBanner()
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                }
                detail
            }
                .navigationTitle(profileName)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                .inspector(isPresented: $showInspector) {
                    InspectorView(slot: $selectedSlot,
                              onChooseImage: { slot in chooseImage(for: slot) })
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                }
        }
        .confirmationDialog(
            picking.map { "Use “\($0.name)” on key \($0.slot)?" } ?? "Add image",
            isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
            titleVisibility: .visible,
            presenting: picking
        ) { pick in
            Button("Edit Graphic…") {
                let target = pick
                picking = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    editing = EditTarget(image: target.image, slot: target.slot)
                }
            }
            Button("Use Original") {
                let target = pick
                picking = nil
                useOriginal(target)
            }
            Button("Cancel", role: .cancel) { picking = nil }
        } message: { pick in
            Text("Fitted to \(ImagePrep.size(for: pick.slot))×\(ImagePrep.size(for: pick.slot)) on the key. Adjust it first, or use it unchanged.")
        }
        .sheet(item: $libraryTarget) { target in
            LibraryPickerView(title: "Choose a graphic for key \(target.slot)",
                              onPick: { url in
                                  libraryTarget = nil
                                  // the confirmation dialog must not race the sheet's dismissal
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                      importImageAt(url, slot: target.slot)
                                  }
                              },
                              onCancel: { libraryTarget = nil })
        }
        .sheet(item: $editing) { target in
            ImageEditorSheet(source: target.image, slot: target.slot,
                             onCancel: { editing = nil },
                             onApply: { composed in
                                 applyEdited(composed, slot: target.slot)
                                 editing = nil
                             })
        }
        .onAppear {
            deck.store = store
            ControlServer.shared.start(store: store, deck: deck)
            MenuBarController.shared.start(deck: deck, store: store)
            deck.onWidgetTick = { [self] in tickWidgets() }
            // headless UI review hook: open the editor on launch with a sample image
            if let demo = ProcessInfo.processInfo.environment["STREAMDOCK_EDITOR_DEMO"],
               let image = ImagePrep.load(URL(fileURLWithPath: demo)) {
                let slot = Int(ProcessInfo.processInfo.environment["STREAMDOCK_EDITOR_SLOT"] ?? "1") ?? 1
                editing = EditTarget(image: image, slot: slot)
                // self-test hook: exercise the same apply path the "Use Image" button uses
                if ProcessInfo.processInfo.environment["STREAMDOCK_EDITOR_AUTO"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let edit = ImageEdit(quarterTurns: 1, zoom: 1.4,
                                             offset: CGSize(width: 12, height: -8))
                        if let composed = ImageRenderer.compose(image, edit: edit,
                                                                side: ImagePrep.size(for: slot)) {
                            applyEdited(composed, slot: slot)
                        }
                        editing = nil
                    }
                }
            }
            // the device may already be connected before this view exists
            if deck.connected { sendAll() }
        }
        .onChange(of: deck.connected) { _, connected in
            // sync the open profile as soon as the panel appears
            if connected { sendAll() }
        }
        .modifier(NotificationRouter(handlers: [
            "deck.sendAll": { _ in sendAll() },
            "deck.newProfile": { _ in store.addProfile() },
            "deck.loadProfile": { _ in loadProfileFile() },
            "deck.save": { _ in saveProfile() },
            "deck.saveAs": { _ in saveProfileAs() },
            "deck.pageRequest": { note in
                guard let target = note.userInfo?["target"] as? String else { return }
                changePage(target)
            },
            "deck.duplicateProfile": { _ in
                guard let id = store.selection ?? store.profiles.first?.id else { return }
                if let copy = store.duplicate(id) { Log.write("duplicated profile \(id) → \(copy.name)") }
            },
            "deck.removeProfile": { _ in
                guard let id = store.selection ?? store.profiles.last?.id else { return }
                store.removeFromSidebar(id)
            },
        ]))
    }

    private var currentProfile: Profile? {
        store.profiles.first { $0.id == store.selection }
    }

    private var profileName: String { currentProfile?.name ?? "Deckhand" }
    private var subtitle: String {
        guard let p = currentProfile else { return "No profile" }
        let bound = p.slots.filter { !$0.isWindow && $0.action.kind != .none }.count
        let base = "\(bound) of 15 keys bound"
        return p.id == store.liveProfileID ? base : base + " · not on device"
    }

    private var detail: some View {
        Group {
            if let profile = currentProfile {
                DeckView(profile: profile,
                         selected: $selectedSlot,
                         onImport: { slot in chooseImage(for: slot) },
                         onDropImage: { url, slot in importImageAt(url, slot: slot) },
                         onClearImage: { slot in clearImageAt(slot) },
                         onSelectPage: { index in selectPage(index) },
                         onClearAction: { slot in clearAction(slot) },
                         onAddPage: { addPage() },
                         onRemovePage: { index in removePage(index) })
            } else {
                ContentUnavailableView("No Profile", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("Create a profile to start mapping keys."))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DeviceStatus(connected: deck.connected, firmware: deck.firmware) { deck.reconnect() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                sendAll()
            } label: {
                Label(t("Send to Device"), systemImage: "arrow.up.rectangle.portrait")
            }
            .help("Write every key image to the panel")
            .disabled(!deck.connected || currentProfile == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Load Images…") { pickMany() }
                Button("Clear All Keys") { clearAllKeys() }
                    .disabled(currentProfile == nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Bulk actions")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the key inspector")
        }
    }

    private func sendAll() {
        guard let profile = currentProfile else { return }
        guard profile.id == store.liveProfileID else {
            Log.write("skipped send: \(profile.name) is not the profile on the device")
            return
        }
        let images: [(Int, URL)] = profile.slots.compactMap { slot in
            guard !slot.isWindow else { return nil }        // panes draw widgets, not files
            guard let url = store.imageURL(profileID: profile.id, slot: slot, page: profile.activePage) else { return nil }
            return (slot.id, url)
        }
        deck.send(profile, images: images)
    }

    /// "next" / "previous" wrap around; a number jumps straight there.
    private func changePage(_ target: String) {
        guard let id = store.liveProfileID ?? store.selection,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        let count = store.profiles[idx].pages.count
        let current = store.profiles[idx].activePage
        var next = current
        switch target {
        case "next":     next = (current + 1) % count
        case "previous": next = (current - 1 + count) % count
        case "home":     next = 0
        default:         next = max(0, min(count - 1, (Int(target) ?? 1) - 1))
        }
        selectPage(next)
    }

    private func selectPage(_ index: Int) {
        guard let id = store.selection,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        store.profiles[idx].selectPage(index)
        store.save()
        if store.profiles[idx].id == store.liveProfileID { deck.setPage(index) }
        widgetCache.removeAll()
        sendAll()
        Log.write("page \(index + 1) selected")
    }

    /// Unbind a key: the graphic and label stay, only the action goes away.
    private func clearAction(_ slot: Int) {
        guard let id = store.selection,
              let pidx = store.profiles.firstIndex(where: { $0.id == id }),
              let sidx = store.profiles[pidx].slots.firstIndex(where: { $0.id == slot }) else { return }
        store.profiles[pidx].slots[sidx].action = KeyAction()
        store.save()
        Log.write("cleared action on key \(slot)")
        if store.profiles[pidx].id == store.liveProfileID { sendAll() }
    }

    private func addPage() {
        guard let id = store.selection,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        guard store.profiles[idx].addPage() else {
            Log.write("page limit reached (\(Profile.maxPages))")
            return
        }
        store.save()
        deck.setPage(store.profiles[idx].activePage)
        sendAll()
        Log.write("page added — now \(store.profiles[idx].pages.count) pages")
    }

    private func removePage(_ index: Int) {
        guard let id = store.selection,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        guard store.profiles[idx].removePage(at: index) else { return }
        store.save()
        deck.setPage(store.profiles[idx].activePage)
        sendAll()
        Log.write("page removed — now \(store.profiles[idx].pages.count) pages")
    }

    // MARK: File menu

    static let profileType = UTType(exportedAs: "com.rolandchia.streamdocklite.profile",
                                    conformingTo: .json)

    /// ⌘S: writes back to the profile's own file, asking for a name the first time.
    private func saveProfile() {
        guard let profile = currentProfile else { return }
        guard let path = profile.fileURLPath else {
            saveProfileAs()          // never named yet — same panel as Save As
            return
        }
        guard let data = store.exportPackage(for: profile) else {
            Log.write("Save failed: could not package profile")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            store.save()
            Log.write("saved profile to \(path) (\(data.count) bytes)")
        } catch {
            Log.write("Save failed: \(error.localizedDescription)")
        }
    }

    func saveProfileAs() {
        guard let profile = currentProfile else { return }
        let panel = NSSavePanel()
        panel.directoryURL = AppSettings.shared.profilesURL
        panel.nameFieldStringValue = "\(profile.name).sdprofile"
        panel.allowedContentTypes = [Self.profileType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = store.exportPackage(for: profile) else {
            Log.write("Save As failed: could not package profile")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            store.setFilePath(url.path, for: profile.id)     // ⌘S now targets this file
            Log.write("saved profile to \(url.path) (\(data.count) bytes)")
        } catch {
            Log.write("Save As failed: \(error.localizedDescription)")
        }
    }

    private func loadProfileFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = AppSettings.shared.profilesURL
        panel.allowedContentTypes = [Self.profileType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            Log.write("Load failed: cannot read \(url.path)")
            return
        }
        guard let profile = store.importPackage(data) else {
            Log.write("Load failed: \(url.lastPathComponent) is not a profile file")
            return
        }
        Log.write("loaded profile \(profile.name) with \(profile.pages.count) page(s)")
        deck.setPage(profile.activePage)
        sendAll()
    }

    /// The window panes are host-rendered: recompute their image and push only when it changed.
    private func tickWidgets() {
        guard deck.connected, let profile = currentProfile else { return }

        for slot in profile.slots where slot.isWindow {
            guard let widget = slot.widget, widget.kind != .none else { continue }
            guard let data = WidgetRenderer.jpeg(for: widget,
                                                 page: (profile.activePage + 1, profile.pages.count)) else { continue }
            if widgetCache[slot.id] != data {
                let first = widgetCache[slot.id] == nil
                widgetCache[slot.id] = data
                deck.sendSingle(slot: slot.id, data: data, quiet: true)
                if first { Log.write("widget \(widget.kind.rawValue) → pane \(slot.id) (\(data.count) bytes)") }
            }
        }
    }

    /// "Choose Image" shows the library (built-in graphics + whatever the user imported).
    private func chooseImage(for slot: Int) {
        libraryTarget = LibraryTarget(slot: slot)
    }

    /// Single image for one key, starting in the configured graphics folder.
    private func pickImages(slot: Int) {
        let panel = NSOpenPanel()
        panel.directoryURL = AppSettings.shared.graphicsURL
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a graphic for key \(slot)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImageAt(url, slot: slot)
        return
    }


    /// Bulk import: pick several files from the configured graphics folder.
    /// File ▸ Import Images to Library… — copies files into the library, then opens the picker if a
    /// key was waiting for a graphic.
    private func importToLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = AppSettings.shared.graphicsURL
        panel.message = "Choose images to add to the Deckhand library"
        guard panel.runModal() == .OK else { return }
        let added = ImageLibrary.shared.importImages(panel.urls)
        Log.write("library: \(added) image(s) imported")
    }

    private func pickMany() {
        let panel = NSOpenPanel()
        panel.directoryURL = AppSettings.shared.graphicsURL
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose graphics to fill the keys in order"
        guard panel.runModal() == .OK else { return }
        loadImages(panel.urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func importImageAt(_ url: URL, slot: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = ImagePrep.load(url) else {
            Log.write("cannot read image at \(url.path)")
            return
        }
        // ask first: edit it, or use it as-is
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            picking = PickTarget(image: image, slot: slot, name: url.lastPathComponent)
        }
    }

    /// Take the picture whole, aspect-filled into the key square, no editor.
    private func useOriginal(_ pick: PickTarget) {
        guard let profile = currentProfile,
              let idx = store.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard let name = store.saveImage(pick.image, for: Slot(id: pick.slot),
                                         profileID: profile.id, page: profile.activePage) else { return }
        store.profiles[idx].update(pick.slot) { $0.imageFile = name }
        store.save()
        sendSlot(pick.slot)
        selectedSlot = pick.slot
        Log.write("image used as-is: \(pick.name) → page \(profile.activePage) slot \(pick.slot)")
    }

    private func applyEdited(_ image: CGImage, slot: Int) {
        guard let profile = currentProfile,
              let idx = store.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard let name = store.saveImage(image, for: Slot(id: slot),
                                         profileID: profile.id, page: profile.activePage) else { return }
        store.profiles[idx].update(slot) { $0.imageFile = name }
        store.save()
        sendSlot(slot)
        selectedSlot = slot
        Log.write("image edited and applied: page \(profile.activePage) slot \(slot)")
    }

    private func clearImageAt(_ slot: Int) {
        guard let id = store.selection,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        store.profiles[idx].update(slot) { $0.imageFile = nil }
        store.save()
    }

    /// Fill slots 1...18 in order from the chosen files, then push them to the panel.
    private func loadImages(_ urls: [URL]) {
        guard let profile = currentProfile,
              let idx = store.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        for (offset, url) in urls.prefix(18).enumerated() {
            let slot = offset + 1
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let name = store.importImage(from: url, for: Slot(id: slot), profileID: profile.id,
                                               page: profile.activePage) else { continue }
            store.profiles[idx].update(slot) { $0.imageFile = name }
        }
        store.save()
        sendAll()
    }

    private func clearAllKeys() {
        guard let id = store.selection,
              let idx = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        for slot in 1...18 { store.profiles[idx].update(slot) { $0.imageFile = nil } }
        store.save()
        deck.clearDevice()
    }

    private func sendSlot(_ index: Int) {
        guard let profile = currentProfile,
              let slot = profile.slot(index),
              let url = store.imageURL(profileID: profile.id, slot: slot, page: profile.activePage),
              let data = ImagePrep.prepare(url: url, side: ImagePrep.size(for: index)) else { return }
        deck.sendSingle(slot: index, data: data)
    }
}

struct PermissionBanner: View {
    @State private var trusted = HotkeyEngine.isTrusted
    @State private var dismissed = false

    var body: some View {
        if !trusted && !dismissed {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Key combinations need Accessibility permission")
                        .font(.callout.weight(.medium))
                    Text("Images work without it. macOS blocks synthetic keystrokes until you allow this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Request Access") { HotkeyEngine.requestTrust() }
                    .buttonStyle(.borderedProminent)
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check") { trusted = HotkeyEngine.isTrusted }
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide until next launch")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

// MARK: - sidebar

struct SidebarView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var deck: DeckModel

    private var currentProfile: Profile? {
        store.profiles.first { $0.id == store.selection }
    }

    private func sendAll() {
        NotificationCenter.default.post(name: .init("deck.sendAll"), object: nil)
    }

    var body: some View {
        List(selection: $store.selection) {
            // Plain header row instead of a Section: a Section header is collapsible on macOS and
            // swallows clicks inside it, which is why add worked and delete didn't.
            HStack(spacing: 4) {
                Text(t("Profiles"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New profile")

                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(store.profiles.count < 2)
                .help("Remove the selected profile from the sidebar (its files are kept)")
            }
            .padding(.vertical, 2)
            .listRowSeparator(.hidden)
            .selectionDisabled()

            ForEach(store.profiles) { profile in
                HStack(spacing: 6) {
                    Label(profile.name, systemImage: "square.grid.3x3")
                    Spacer(minLength: 4)
                    if profile.id == store.liveProfileID {
                        Text(t("On device"))
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                    .tag(profile.id)
                    .contextMenu {
                        Button("Duplicate") { store.duplicate(profile.id) }
                        Button("Rename…") { rename(profile) }
                        Divider()
                        Button("Remove from Sidebar") { remove(profile) }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { deviceFooter }
    }

    // device information and the push action live at the bottom of the sidebar
    private var deviceFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(deck.connected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(deck.connected ? "Connected" : "Not connected")
                    .font(.callout.weight(.medium))
                Spacer()
                if !deck.connected {
                    Button("Scan") { deck.reconnect() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }

            if deck.connected {
                VStack(alignment: .leading, spacing: 2) {
                    labelled(t("Model"), deck.info.modelShort)
                    labelled("USB", deck.info.idText)
                    if let fw = deck.info.firmware ?? deck.firmware {
                        labelled(t("Firmware"), fw)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                store.makeLive(store.selection)
                Log.write("activated profile \(currentProfile?.name ?? "?") on the device")
                sendAll()
            } label: {
                Label(t("Send to Device"), systemImage: "arrow.up.rectangle.portrait")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!deck.connected || currentProfile == nil)
            .help("Push every image of the active page to the panel")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .alert("Remove “\(confirmingRemoval?.name ?? "")” from the sidebar?",
               isPresented: Binding(get: { confirmingRemoval != nil },
                                    set: { if !$0 { confirmingRemoval = nil } }),
               presenting: confirmingRemoval) { profile in
            Button("Remove", role: .destructive) {
                store.removeFromSidebar(profile.id)
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: { _ in
            Text("This profile has never been saved to a file, so it cannot be loaded again. Save it first to keep a copy.")
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(value).foregroundStyle(.primary.opacity(0.85)).lineLimit(1).truncationMode(.middle)
        }
    }

    /// Remove from the sidebar only. A profile that was never written to a file cannot be
    /// restored afterwards, so that case asks first.
    @State private var confirmingRemoval: Profile?

    private func remove(_ profile: Profile) {
        if profile.fileURLPath == nil && profile.id != store.liveProfileID {
            confirmingRemoval = profile
        } else {
            store.removeFromSidebar(profile.id)
            Log.write("removed \(profile.name) from the sidebar (files kept)")
        }
    }

    private func deleteSelected() {
        if let id = store.selection {
            store.removeFromSidebar(id)
        } else if let last = store.profiles.last {
            remove(last)
        }
    }

    private func rename(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Rename Profile"
        alert.informativeText = "Enter a new name for \(profile.name)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = profile.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            store.rename(profile.id, to: field.stringValue)
        }
    }
}

struct DeviceStatus: View {
    let connected: Bool
    let firmware: String?
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(connected ? "Panel connected" : "No panel")
                    .font(.callout)
                    .foregroundStyle(connected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(connected ? "Firmware \(firmware ?? "unknown") — click to re-scan" : "Click to scan for the panel")
    }
}

// MARK: - deck

struct DeckView: View {
    let profile: Profile
    @Binding var selected: Int?
    let onImport: (Int) -> Void
    var onDropImage: (URL, Int) -> Void = { _, _ in }
    var onClearImage: (Int) -> Void = { _ in }
    var onSelectPage: (Int) -> Void = { _ in }
    var onClearAction: (Int) -> Void = { _ in }
    var onAddPage: () -> Void = {}
    var onRemovePage: (Int) -> Void = { _ in }

    private let columns = Array(repeating: GridItem(.flexible(minimum: 84, maximum: 96), spacing: 14), count: 5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 8) {
                    Picker("Page", selection: Binding(
                        get: { profile.activePage },
                        set: { onSelectPage($0) })) {
                        ForEach(Array(profile.pages.enumerated()), id: \.offset) { index, page in
                            Text(page.name).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)

                    Button {
                        onAddPage()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(profile.pages.count >= Profile.maxPages)
                    .help("Add a page (up to \(Profile.maxPages))")

                    Button {
                        onRemovePage(profile.activePage)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(profile.pages.count < 2)
                    .help("Delete this page")

                    Spacer()

                    Text("\(profile.pages.count) \(t("pages · limit")) \(Profile.maxPages)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(t("Keys"), caption: t("Click to bind · drop an image to set its graphic"))
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(profile.slots.filter { !$0.isWindow }) { slot in
                                KeyTile(slot: slot,
                                        image: imageURL(slot),
                                        selected: selected == slot.id,
                                        pressed: false)
                                    .onTapGesture { selected = slot.id }
                                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                        drop(providers, slot: slot.id)
                                    }
                                    .contextMenu {
                                        Button("Choose Image…") { onImport(slot.id) }
                                        Button("Clear Image") { clearImage(slot.id) }
                                            .disabled(slot.imageFile == nil)
                                        Divider()
                                        Button("Clear Action") { onClearAction(slot.id) }
                                            .disabled(slot.action.kind == .none)
                                    }
                                    .accessibilityLabel("Key \(slot.id)")
                                    .accessibilityValue(slot.action.summary)
                            }
                        }
                    }

                    // the 1×3 window sits vertically beside keys 5 / 10 / 15
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(t("Window"), caption: t("Widgets · no input"))
                        VStack(spacing: 12) {
                            ForEach(profile.slots.filter(\.isWindow)) { slot in
                                KeyTile(slot: slot,
                                        image: nil,                       // widgets render here
                                        widgetPage: (profile.activePage + 1, profile.pages.count),
                                        selected: selected == slot.id,
                                        pressed: false,
                                        size: 80)
                                    .onTapGesture { selected = slot.id }
                                    .help("Display only — no input on this pane")
                                    .contextMenu {
                                        Button("Configure Widget…") { selected = slot.id }
                                    }
                                    .accessibilityLabel("Window pane \(slot.id - 15), display only")
                                    .accessibilityValue(slot.widget?.kind.title ?? "no widget")
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func imageURL(_ slot: Slot) -> URL? {
        guard let name = slot.imageFile else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deckhand/images/\(profile.id.uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func drop(_ providers: [NSItemProvider], slot: Int) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { onDropImage(url, slot) }
        }
        return true
    }

    private func clearImage(_ slot: Int) {
        onClearImage(slot)
    }
}

struct SectionLabel: View {
    let text: String
    var caption: String? = nil
    init(_ text: String, caption: String? = nil) {
        self.text = text
        self.caption = caption
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.headline)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct KeyTile: View {
    let slot: Slot
    let image: URL?
    var widgetPage: (index: Int, count: Int)? = nil
    /// span mode: the shared strip widget plus which third this tile shows
    var stripSlice: (config: WidgetConfig, pane: Int, page: (index: Int, count: Int))? = nil
    var seam: SeamStyle = .separate
    let selected: Bool
    let pressed: Bool
    var size: CGFloat = 96

    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering && !selected ? Color.accentColor.opacity(0.08)
                                            : Color(nsColor: .controlBackgroundColor))
            if let slice = stripSlice, slice.config.kind != .none {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let strip = WidgetRenderer.stripImage(for: slice.config, page: slice.page,
                                                             now: context.date, bleed: true,
                                                             seam: seam),
                       let crop = strip.cropping(to: CGRect(x: 0, y: slice.pane * WidgetRenderer.side,
                                                            width: WidgetRenderer.side,
                                                            height: WidgetRenderer.side)) {
                        Image(decorative: crop, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            } else if let widget = slot.widget, widget.kind != .none, let page = widgetPage {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let cg = WidgetRenderer.image(for: widget, page: page, now: context.date) {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            } else if let image, let ns = NSImage(contentsOf: image) {
                Image(nsImage: ns)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                VStack(spacing: 5) {
                    Text("\(slot.id)")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    if hovering {
                        Label("Assign", systemImage: "plus")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if slot.action.kind != .none {
                        Image(systemName: slot.action.kind.symbol)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if slot.isWindow {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "eye.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(5)
                    }
                    Spacer()
                }
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor
                                       : (hovering ? Color.primary.opacity(0.25) : Color.primary.opacity(0.12)),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1,
                                                 dash: slot.isWindow ? [4, 3] : []))
        }
        .frame(width: size, height: size)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .scaleEffect(pressed ? 0.96 : 1)
        .shadow(color: selected ? Color.accentColor.opacity(0.25) : .clear, radius: 6)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(slot.action.summary)
    }
}


/// Routes menu commands to the view in one modifier. A long `.onReceive` chain made the body's
/// type-check explode ("unable to type-check this expression in reasonable time").
struct NotificationRouter: ViewModifier {
    let handlers: [String: (Notification) -> Void]

    func body(content: Content) -> some View {
        handlers.reduce(AnyView(content)) { view, entry in
            AnyView(view.onReceive(NotificationCenter.default.publisher(for: .init(entry.key))) { note in
                entry.value(note)
            })
        }
    }
}
