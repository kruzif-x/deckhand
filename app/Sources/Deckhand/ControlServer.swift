// ControlServer.swift — a local control socket so external processes (the MCP server, scripts,
// agents) can drive the app without touching HID directly: the app keeps exclusive ownership of
// the device, and everyone else talks to it over a Unix socket in Application Support.
import Foundation
import Network

@MainActor
final class ControlServer {
    static let shared = ControlServer()

    private var listener: NWListener?
    private weak var store: ProfileStore?
    private weak var deck: DeckModel?

    static var socketPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deckhand", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control.sock").path
    }

    func start(store: ProfileStore, deck: DeckModel) {
        guard listener == nil else { return }
        self.store = store
        self.deck = deck

        let path = Self.socketPath
        try? FileManager.default.removeItem(atPath: path)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: path)

        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                Task { @MainActor in self?.receive(conn, buffer: Data()) }
            }
            l.start(queue: .main)
            listener = l
            Log.write("control socket listening at \(path)")
        } catch {
            Log.write("control socket failed: \(error.localizedDescription)")
        }
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer = buffer[(newline + 1)...]
                if let response = self.handle(line: Data(line)) {
                    conn.send(content: response, completion: .contentProcessed { _ in })
                }
            }

            if isComplete || error != nil { conn.cancel(); return }
            Task { @MainActor in self.receive(conn, buffer: buffer) }
        }
    }

    private func handle(line: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cmd = object["cmd"] as? String else {
            return Self.encode(["ok": false, "error": "malformed request"])
        }
        let reply = execute(cmd: cmd, args: object)
        return Self.encode(reply)
    }

    private static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    // MARK: command routing

    private func execute(cmd: String, args: [String: Any]) -> [String: Any] {
        guard let store, let deck else { return ["ok": false, "error": "app not ready"] }
        guard let profileID = store.liveProfileID ?? store.selection,
              let pidx = store.profiles.firstIndex(where: { $0.id == profileID }) else {
            return ["ok": false, "error": "no profile selected"]
        }

        func int(_ key: String, _ fallback: Int = 0) -> Int { args[key] as? Int ?? fallback }

        switch cmd {
        case "status":
            let p = store.profiles[pidx]
            return [
                "ok": true,
                "connected": deck.connected,
                "firmware": deck.firmware ?? "",
                "profile": p.name,
                "activePage": p.activePage,
                "pages": p.pages.count,
                "maxPages": Profile.maxPages,
                "live": store.profiles.first(where: { $0.id == store.liveProfileID })?.name ?? "",
                "selected": store.profiles.first(where: { $0.id == store.selection })?.name ?? "",
                "socket": Self.socketPath,
            ]

        case "profiles.select":
            let want = (args["name"] as? String) ?? (args["id"] as? String) ?? ""
            guard let target = store.profiles.first(where: { $0.name == want || $0.id.uuidString == want }) else {
                return ["ok": false, "error": "no profile matching \(want)"]
            }
            store.selection = target.id            // highlight only — the panel keeps its profile
            return ["ok": true, "selected": target.id.uuidString,
                    "live": store.liveProfileID?.uuidString ?? ""]

        case "profiles.new":
            let name = (args["name"] as? String) ?? "New Profile"
            store.addProfile(named: name)
            return ["ok": true, "created": store.profiles.last?.id.uuidString ?? "", "name": name]

        case "profiles.remove":
            let want = (args["name"] as? String) ?? (args["id"] as? String) ?? ""
            guard let target = store.profiles.first(where: { $0.name == want || $0.id.uuidString == want }) else {
                return ["ok": false, "error": "no profile matching \(want)"]
            }
            // unlink from the sidebar only — the .sdprofile file and image folder stay on disk
            store.removeFromSidebar(target.id)
            Log.write("mcp: removed \(want) from the sidebar (files kept)")
            return ["ok": true, "removed": target.id.uuidString,
                    "file": target.fileURLPath ?? ""]

        case "profiles.activate":
            let want = (args["name"] as? String) ?? (args["id"] as? String) ?? ""
            guard let target = store.profiles.first(where: { $0.name == want || $0.id.uuidString == want }),
                  let i = store.profiles.firstIndex(where: { $0.id == target.id }) else {
                return ["ok": false, "error": "no profile matching \(want)"]
            }
            store.makeLive(target.id)
            store.selection = target.id
            let page = store.profiles[i].activePage
            deck.setPage(page)
            deck.send(store.profiles[i], images: imagesFor(pidx: i, page: page, store: store))
            Log.write("mcp: activated profile \(target.name) on the device")
            return ["ok": true, "live": target.id.uuidString]

        case "profiles.list":
            return ["ok": true, "profiles": store.profiles.map {
                ["id": $0.id.uuidString, "name": $0.name, "pages": $0.pages.count, "activePage": $0.activePage]
            }, "selected": store.selection?.uuidString ?? "",
               "live": store.liveProfileID?.uuidString ?? ""]

        case "page.set":
            let index = int("index")
            guard store.profiles[pidx].pages.indices.contains(index) else {
                return ["ok": false, "error": "page \(index) does not exist"]
            }
            store.profiles[pidx].selectPage(index)
            store.save()
            deck.setPage(index)
            deck.send(store.profiles[pidx], images: imagesFor(pidx: pidx, page: index, store: store))
            Log.write("mcp: page.set \(index)")
            return ["ok": true, "activePage": index]

        case "page.add":
            guard store.profiles[pidx].addPage() else {
                return ["ok": false, "error": "limit reached (\(Profile.maxPages) pages)"]
            }
            store.save()
            deck.setPage(store.profiles[pidx].activePage)
            Log.write("mcp: page.add → \(store.profiles[pidx].pages.count) pages")
            return ["ok": true, "pages": store.profiles[pidx].pages.count,
                    "activePage": store.profiles[pidx].activePage]

        case "page.remove":
            guard store.profiles[pidx].removePage(at: int("index")) else {
                return ["ok": false, "error": "cannot remove the last page"]
            }
            store.save()
            deck.setPage(store.profiles[pidx].activePage)
            Log.write("mcp: page.remove → \(store.profiles[pidx].pages.count) pages")
            return ["ok": true, "pages": store.profiles[pidx].pages.count]

        case "key.image":
            let page = int("page", store.profiles[pidx].activePage)
            let slot = int("slot")
            guard let path = args["path"] as? String else { return ["ok": false, "error": "path required"] }
            guard store.profiles[pidx].pages.indices.contains(page),
                  let sidx = store.profiles[pidx].pages[page].slots.firstIndex(where: { $0.id == slot }) else {
                return ["ok": false, "error": "no slot \(slot) on page \(page)"]
            }
            guard let name = store.importImage(from: URL(fileURLWithPath: path),
                                               for: Slot(id: slot),
                                               profileID: profileID, page: page) else {
                return ["ok": false, "error": "could not read \(path)"]
            }
            store.profiles[pidx].pages[page].slots[sidx].imageFile = name
            store.save()
            if page == store.profiles[pidx].activePage, let url = store.imageURL(profileID: profileID, slot: Slot(id: slot), page: page),
               let data = ImagePrep.prepare(url: url, side: ImagePrep.size(for: slot)) {
                deck.sendSingle(slot: slot, data: data)
            }
            Log.write("mcp: key.image page \(page) slot \(slot) <- \(path)")
            return ["ok": true, "slot": slot, "page": page, "file": name]

        case "key.action":
            let page = int("page", store.profiles[pidx].activePage)
            let slot = int("slot")
            guard store.profiles[pidx].pages.indices.contains(page),
                  let sidx = store.profiles[pidx].pages[page].slots.firstIndex(where: { $0.id == slot }) else {
                return ["ok": false, "error": "no slot \(slot) on page \(page)"]
            }
            var action = KeyAction()
            if let kind = args["kind"] as? String, let k = ActionKind(rawValue: kind) {
                if k == .text { return ["ok": false, "error": "text actions are retired; use hotkey, openApp, openURL or shell"] }
                action.kind = k
            }
            action.keyCode = UInt16(int("keyCode"))
            action.modifierFlags = UInt(int("modifiers"))
            action.text = args["text"] as? String ?? ""
            action.target = args["target"] as? String ?? ""
            store.profiles[pidx].pages[page].slots[sidx].action = action
            if let label = args["label"] as? String { store.profiles[pidx].pages[page].slots[sidx].label = label }
            store.save()
            Log.write("mcp: key.action page \(page) slot \(slot) → \(action.kind.rawValue) \(action.summary)")
            return ["ok": true, "slot": slot, "summary": action.summary]

        case "key.press":
            let slot = int("slot")
            guard let slotAction = store.profiles[pidx].slot(slot) else {
                return ["ok": false, "error": "no slot \(slot)"]
            }
            if let target = slotAction.action.kind.pageTarget
                ?? (slotAction.action.kind == .page ? slotAction.action.target : nil) {
                // page changes need the profile store, which the view owns
                NotificationCenter.default.post(name: .init("deck.pageRequest"), object: nil,
                                                userInfo: ["target": target])
            } else {
                HotkeyEngine.run(slotAction.action)
            }
            Log.write("mcp: key.press \(slot) → \(slotAction.action.summary)")
            return ["ok": true, "slot": slot, "action": slotAction.action.summary]

        case "window.set":
            let modeRaw = (args["mode"] as? String) ?? "span"
            guard let mode = WindowMode(rawValue: modeRaw) else {
                return ["ok": false, "error": "mode must be span or perPane"]
            }
            var window = store.profiles[pidx].window ?? WindowConfig()
            window.mode = mode
            if let kindRaw = args["kind"] as? String, let kind = WidgetKind(rawValue: kindRaw) {
                window.widget.kind = kind
            }
            if let text = args["text"] as? String { window.widget.text = text }
            if let seconds = args["showsSeconds"] as? Bool { window.widget.showsSeconds = seconds }
            store.profiles[pidx].window = window
            store.save()
            Log.write("mcp: window mode → \(mode.rawValue)")
            return ["ok": true, "mode": mode.rawValue, "kind": window.widget.kind.rawValue]

        case "widget.set":
            let page = int("page", store.profiles[pidx].activePage)
            let slot = int("slot")
            guard slot >= 16, slot <= 18 else {
                return ["ok": false, "error": "widgets live in the 1×3 window (slots 16-18)"]
            }
            guard store.profiles[pidx].pages.indices.contains(page),
                  let sidx = store.profiles[pidx].pages[page].slots.firstIndex(where: { $0.id == slot }) else {
                return ["ok": false, "error": "no slot \(slot) on page \(page)"]
            }
            let kindRaw = (args["kind"] as? String) ?? "none"
            guard let kind = WidgetKind(rawValue: kindRaw) else {
                return ["ok": false, "error": "unknown widget \(kindRaw)"]
            }
            var widget = store.profiles[pidx].pages[page].slots[sidx].widget ?? WidgetConfig()
            widget.kind = kind
            if let text = args["text"] as? String { widget.text = text }
            if let seconds = args["showsSeconds"] as? Bool { widget.showsSeconds = seconds }
            store.profiles[pidx].pages[page].slots[sidx].widget = (kind == .none ? nil : widget)
            store.save()
            Log.write("mcp: widget page \(page) pane \(slot) → \(kind.rawValue)")
            return ["ok": true, "slot": slot, "kind": kind.rawValue]

        case "device.send":
            let page = store.profiles[pidx].activePage
            deck.setPage(page)
            deck.send(store.profiles[pidx], images: imagesFor(pidx: pidx, page: page, store: store))
            return ["ok": true, "sent": imagesFor(pidx: pidx, page: page, store: store).count]

        case "device.clear":
            deck.clearDevice()
            Log.write("mcp: device.clear")
            return ["ok": true]

        case "device.brightness":
            deck.setBrightness(UInt8(clamping: int("value", 90)))
            return ["ok": true, "brightness": int("value", 90)]

        default:
            return ["ok": false, "error": "unknown command \(cmd)"]
        }
    }

    private func imagesFor(pidx: Int, page: Int, store: ProfileStore) -> [(Int, URL)] {
        guard store.profiles[pidx].pages.indices.contains(page) else { return [] }
        let profile = store.profiles[pidx]
        return profile.pages[page].slots.compactMap { slot in
            guard !slot.isWindow else { return nil }        // panes are widget-driven
            guard let url = store.imageURL(profileID: profile.id, slot: slot, page: page) else { return nil }
            return (slot.id, url)
        }
    }
}
