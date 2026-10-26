// main.swift — streamdock-mcp: a stdio MCP server for StreamDockLite.
//
// It does not touch USB itself. The app owns the panel exclusively, so this server forwards
// every tool call over the app's Unix control socket and returns the JSON reply as MCP content.
//
// Register with any MCP client:
//   command: /Users/rolandchia/Downloads/streamdock-reverse/app/Deckhand.app/Contents/MacOS/streamdock-mcp
import Foundation

let socketPath: String = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Deckhand", isDirectory: true)
    return dir.appendingPathComponent("control.sock").path
}()

// MARK: - control socket client

func callApp(_ request: [String: Any], timeout: TimeInterval = 8, retried: Bool = false) -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return ["ok": false, "error": "socket() failed"] }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        return ["ok": false, "error": "socket path too long"]
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
        }
    }

    let connected = withUnsafePointer(to: &addr) { ptr -> Bool in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard connected else {
        return ["ok": false,
                "error": "Deckhand is not running (no control socket at \(socketPath))"]
    }

    var payload = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
    payload.append(0x0A)
    payload.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        _ = write(fd, base, raw.count)
    }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        response.append(contentsOf: buffer[0..<n])
        if response.contains(0x0A) { break }
    }
    guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
        // the app is main-actor bound, so a full page push can occasionally outlast one request;
        // retry once instead of surfacing a spurious failure to the agent
        if !retried { return callApp(request, timeout: timeout, retried: true) }
        return ["ok": false, "error": "no reply from the app"]
    }
    return object
}

// MARK: - tools

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
}

let tools: [Tool] = [
    Tool(name: "deck_status",
         description: "Connection state, firmware, active profile and page count of the Stream Dock panel.",
         schema: ["type": "object", "properties": [:] as [String: Any]]),
    Tool(name: "list_pages",
         description: "List the pages of the open profile and which one is active (maximum 4).",
         schema: ["type": "object", "properties": [:] as [String: Any]]),
    Tool(name: "set_page",
         description: "Switch the panel to a page by index (0-based) and push that page's images.",
         schema: ["type": "object",
                  "properties": ["index": ["type": "integer", "description": "0-based page index"]],
                  "required": ["index"]]),
    Tool(name: "add_page",
         description: "Add an empty page to the open profile (up to 4 pages).",
         schema: ["type": "object", "properties": [:] as [String: Any]]),
    Tool(name: "remove_page",
         description: "Delete a page by index. The last remaining page cannot be removed.",
         schema: ["type": "object",
                  "properties": ["index": ["type": "integer"]],
                  "required": ["index"]]),
    Tool(name: "set_key_image",
         description: "Draw an image file on a key. Slots 1-15 are keys, 16-18 are the 1x3 window panes.",
         schema: ["type": "object",
                  "properties": [
                    "slot": ["type": "integer", "minimum": 1, "maximum": 18],
                    "path": ["type": "string", "description": "absolute path to a PNG/JPEG"],
                    "page": ["type": "integer", "description": "page index, defaults to the active page"],
                  ],
                  "required": ["slot", "path"]]),
    Tool(name: "set_key_action",
         description: "Bind a key. kinds: none, hotkey, text, openApp, openURL, shell. For hotkey give keyCode (macOS virtual key) and modifiers (NSEvent flags: cmd 1048576, shift 131072, opt 524288, ctrl 262144).",
         schema: ["type": "object",
                  "properties": [
                    "slot": ["type": "integer", "minimum": 1, "maximum": 18],
                    "kind": ["type": "string", "enum": ["none", "hotkey", "openApp", "openURL", "shell", "mute", "volumeUp", "volumeDown", "pageNext", "pagePrevious", "pageHome"]],
                    "keyCode": ["type": "integer"],
                    "modifiers": ["type": "integer"],
                    "text": ["type": "string"],
                    "target": ["type": "string", "description": "app path, URL or shell command"],
                    "page": ["type": "integer"],
                  ],
                  "required": ["slot", "kind"]]),
    Tool(name: "press_key",
         description: "Run the action bound to a key as if the physical button were pressed.",
         schema: ["type": "object",
                  "properties": ["slot": ["type": "integer"]],
                  "required": ["slot"]]),
    Tool(name: "set_window_mode",
         description: "Use the vertical 1x3 window either as one strip across all three panes (mode=span) or as three independent panes (mode=perPane).",
         schema: ["type": "object",
                  "properties": [
                    "mode": ["type": "string", "enum": ["span", "perPane"]],
                    "kind": ["type": "string", "enum": ["clock", "date", "cpu", "memory", "page", "text", "none"],
                             "description": "for mode=span, the widget shown across the strip"],
                    "text": ["type": "string"],
                    "showsSeconds": ["type": "boolean"],
                  ],
                  "required": ["mode"]]),
    Tool(name: "set_widget",
         description: "Put a widget in one of the 1x3 window panes (slots 16-18): clock, date, cpu, memory, page, text, none.",
         schema: ["type": "object",
                  "properties": [
                    "slot": ["type": "integer", "minimum": 16, "maximum": 18],
                    "kind": ["type": "string",
                             "enum": ["none", "clock", "date", "cpu", "memory", "page", "text"]],
                    "text": ["type": "string", "description": "for kind=text"],
                    "showsSeconds": ["type": "boolean", "description": "for kind=clock"],
                    "page": ["type": "integer"],
                  ],
                  "required": ["slot", "kind"]]),
    Tool(name: "send_to_device",
         description: "Push every image of the active page to the panel.",
         schema: ["type": "object", "properties": [:] as [String: Any]]),
    Tool(name: "clear_device",
         description: "Blank every key on the panel.",
         schema: ["type": "object", "properties": [:] as [String: Any]]),
    Tool(name: "set_brightness",
         description: "Set key brightness, 0-100.",
         schema: ["type": "object",
                  "properties": ["value": ["type": "integer", "minimum": 0, "maximum": 100]],
                  "required": ["value"]]),
]

func toolToCommand(_ name: String, _ args: [String: Any]) -> [String: Any] {
    var request = args
    request["cmd"] = [
        "deck_status": "status",
        "list_pages": "status",
        "set_page": "page.set",
        "add_page": "page.add",
        "remove_page": "page.remove",
        "set_key_image": "key.image",
        "set_key_action": "key.action",
        "press_key": "key.press",
        "set_widget": "widget.set",
        "set_window_mode": "window.set",
        "send_to_device": "device.send",
        "clear_device": "device.clear",
        "set_brightness": "device.brightness",
    ][name] ?? name
    return request
}

// MARK: - JSON-RPC plumbing

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

func respond(id: Any?, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
}

func respondError(id: Any?, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }

    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        respond(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "streamdock-mcp", "version": "1.0.0"],
        ])

    case "notifications/initialized", "initialized":
        continue

    case "tools/list":
        respond(id: id, result: [
            "tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] },
        ])

    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard tools.contains(where: { $0.name == name }) else {
            respondError(id: id, code: -32602, message: "unknown tool \(name)")
            continue
        }
        let reply = callApp(toolToCommand(name, args))
        let ok = reply["ok"] as? Bool ?? false
        var json = (try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if !ok { json = "error: " + ((reply["error"] as? String) ?? "unknown") + "\n" + json }
        respond(id: id, result: [
            "content": [["type": "text", "text": json]],
            "isError": !ok,
        ])

    case "ping":
        respond(id: id, result: [String: Any]())

    default:
        if id != nil { respondError(id: id, code: -32601, message: "method not found: \(method)") }
    }
}
