// main.swift — app entry plus a small CLI for headless checks.
import SwiftUI
import AppKit
import ApplicationServices
import ImageIO
import CoreGraphics

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--cli") {
            CLI.run()
            exit(0)
        }
        DeckhandApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: ProfileStore?
    var saveHandler: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = store?.hasUnsavedChanges ?? false
        let newOnes = store?.unsavedProfileIDs.count ?? 0
        Log.write("quit requested · store=\(store != nil) unsaved=\(dirty) newProfiles=\(newOnes)")
        guard let store, store.hasUnsavedChanges else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to your profiles?"
        alert.informativeText = "You have a new or changed profile that has not been written to disk."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let saveHandler { saveHandler() } else { store.save() }
            Log.write("profiles saved on quit")
            return .terminateNow
        case .alertSecondButtonReturn:
            Log.write("profiles discarded on quit")
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

struct DeckhandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ProfileStore()
    @StateObject private var deck = DeckModel()

    var body: some Scene {
        WindowGroup("Deckhand") {
            ContentView()
                .environmentObject(store)
                .environmentObject(deck)
                // the three panes need room: sidebar 220 + keys/window 640 + inspector 260.
                // below this the sidebar labels and inspector fields get clipped.
                .frame(minWidth: 1140, minHeight: 660)
                .onAppear {
                    appDelegate.store = store
                    appDelegate.saveHandler = { NotificationCenter.default.post(name: .init("deck.save"), object: nil) }
                }
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Profile") {
                    NotificationCenter.default.post(name: .init("deck.newProfile"), object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Load Profile…") {
                    NotificationCenter.default.post(name: .init("deck.loadProfile"), object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    NotificationCenter.default.post(name: .init("deck.save"), object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    NotificationCenter.default.post(name: .init("deck.saveAs"), object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Duplicate Profile") {
                    NotificationCenter.default.post(name: .init("deck.duplicateProfile"), object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Remove Profile from Sidebar") {
                    NotificationCenter.default.post(name: .init("deck.removeProfile"), object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)

                Divider()

                Button("Send to Device") {
                    store.makeLive(store.selection)
                    NotificationCenter.default.post(name: .init("deck.sendAll"), object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - headless CLI

enum CLI {
    static func run() {
        let args = CommandLine.arguments
        guard let cmdIndex = args.firstIndex(of: "--cli"), cmdIndex + 1 < args.count else {
            print("usage: Deckhand --cli <info|image <slot> <file>|clear>")
            return
        }
        let cmd = args[cmdIndex + 1]

        // pure image path, no device needed — used to check the 90° rotation against PIL
        if cmd == "prep" {
            guard cmdIndex + 4 < args.count,
                  let side = Int(args[cmdIndex + 4]) else { print("usage: prep <in> <out> <side>"); return }
            guard let data = ImagePrep.prepare(url: URL(fileURLWithPath: args[cmdIndex + 2]), side: side) else {
                print("cannot read"); return
            }
            try? data.write(to: URL(fileURLWithPath: args[cmdIndex + 3]))
            print("wrote \(data.count) bytes")
            return
        }

        // compose <in> <out> <side> <quarterTurns> <zoom> <dx> <dy> — headless editor pipeline
        if cmd == "compose" {
            guard cmdIndex + 8 < args.count,
                  let side = Int(args[cmdIndex + 4]),
                  let turns = Int(args[cmdIndex + 5]),
                  let zoom = Double(args[cmdIndex + 6]),
                  let dx = Double(args[cmdIndex + 7]),
                  let dy = Double(args[cmdIndex + 8]) else {
                print("usage: compose <in> <out> <side> <turns> <zoom> <dx> <dy>"); return
            }
            guard let src = ImagePrep.load(URL(fileURLWithPath: args[cmdIndex + 2])) else {
                print("cannot read image"); return
            }
            let edit = ImageEdit(quarterTurns: turns, zoom: CGFloat(zoom),
                                 offset: CGSize(width: dx, height: dy))
            guard let out = ImageRenderer.compose(src, edit: edit, side: side),
                  let data = ImagePrep.jpeg(out, quality: 0.95) else { print("compose failed"); return }
            try? data.write(to: URL(fileURLWithPath: args[cmdIndex + 3]))
            print("composed \(side)x\(side) turns=\(turns) zoom=\(zoom) -> \(data.count) bytes")
            return
        }

        // usbinfo — dump what the OS exposes for the panel, including the port chain
        if cmd == "usbinfo" {
            let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(m, [
                kIOHIDVendorIDKey: DeckDevice.vendorID,
                kIOHIDProductIDKey: DeckDevice.productID,
            ] as CFDictionary)
            IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
            guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let dev = set.first else {
                print("no device"); return
            }
            for key in [kIOHIDProductKey, kIOHIDManufacturerKey, kIOHIDSerialNumberKey,
                        kIOHIDLocationIDKey, kIOHIDVendorIDKey, kIOHIDProductIDKey,
                        kIOHIDTransportKey, kIOHIDVersionNumberKey, "USB Product Name",
                        "USB Vendor Name", "USB Serial Number", "PortNum", "SessionID"] {
                if let value = IOHIDDeviceGetProperty(dev, key as CFString) {
                    print("  \(key) = \(value)")
                }
            }
            let service = IOHIDDeviceGetService(dev)
            var entry = service
            print("  --- parent chain ---")
            for _ in 0..<10 {
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
                      parent != 0 else { break }
                var nameBuf = [CChar](repeating: 0, count: 256)
                IORegistryEntryGetName(parent, &nameBuf)
                var clsBuf = [CChar](repeating: 0, count: 256)
                IOObjectGetClass(parent, &clsBuf)
                var loc: AnyObject?
                IORegistryEntryCreateCFProperty(parent, "locationID" as CFString, kCFAllocatorDefault, 0)
                    .map { loc = $0.takeRetainedValue() }
                print("  \(String(cString: nameBuf))  [\(String(cString: clsBuf))]"
                      + (loc != nil ? "  locationID=\(loc!)" : ""))
                entry = parent
            }
            return
        }

        // strip <kind> <out.png> — the 240×80 span design, upright (no firmware rotation)
        if cmd == "strip" {
            guard cmdIndex + 3 < args.count,
                  let kind = WidgetKind(rawValue: args[cmdIndex + 2]) else {
                print("usage: strip <clock|date|cpu|memory|page|text> <out.png>"); return
            }
            var config = WidgetConfig(kind: kind)
            config.showsSeconds = true
            config.text = kind == .text ? "Deckhand" : ""
            let seam = (cmdIndex + 4 < args.count ? SeamStyle(rawValue: args[cmdIndex + 4]) : nil) ?? .separate
            guard let cg = WidgetRenderer.stripImage(for: config, page: (1, 2), seam: seam) else { print("render failed"); return }
            let url = URL(fileURLWithPath: args[cmdIndex + 3]) as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            print("strip \(kind.rawValue) [\(seam.rawValue)] → \(cg.width)×\(cg.height)")
            return
        }

        // widget <kind> <out.jpg> [page] [count] — render a window widget headlessly
        if cmd == "widget" {
            guard cmdIndex + 3 < args.count,
                  let kind = WidgetKind(rawValue: args[cmdIndex + 2]) else {
                print("usage: widget <clock|date|cpu|memory|page|text> <out.jpg>"); return
            }
            let page = cmdIndex + 4 < args.count ? (Int(args[cmdIndex + 4]) ?? 1) : 1
            let count = cmdIndex + 5 < args.count ? (Int(args[cmdIndex + 5]) ?? 1) : 1
            var config = WidgetConfig(kind: kind)
            config.showsSeconds = true
            guard let data = WidgetRenderer.jpeg(for: config, page: (page, count)) else {
                print("render failed"); return
            }
            try? data.write(to: URL(fileURLWithPath: args[cmdIndex + 3]))
            print("rendered \(kind.rawValue) → \(data.count) bytes")
            return
        }

        // nativesend <slot> <file> — pushes one image through our own driver, no vendor dylib
        if cmd == "nativesend" {
            guard cmdIndex + 3 < args.count, let slot = Int(args[cmdIndex + 2]) else {
                print("usage: nativesend <slot> <file>"); return
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[cmdIndex + 3])) else {
                print("cannot read \(args[cmdIndex + 3])"); return
            }
            let t = NativeTransport()
            guard t.open() else { print("open failed"); return }
            t.wakeScreen()
            let hw = DeckDevice.logicalToHardware[slot] ?? slot
            let ok = t.sendImage(data, key: hw)
            t.commit()                      // "CRT\0\0STP" — the vendor's refresh */
            t.heartbeat()
            print("native send slot \(slot) \(data.count) bytes → \(ok ? "ok" : "FAILED")")
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            t.close()
            return
        }

        // nativehw <hardwareKey> <file> — write straight to a hardware key, no slot mapping
        if cmd == "nativehw" {
            guard cmdIndex + 3 < args.count, let hw = Int(args[cmdIndex + 2]) else {
                print("usage: nativehw <key> <file>"); return
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[cmdIndex + 3])) else {
                print("cannot read"); return
            }
            let t = NativeTransport()
            guard t.open() else { print("open failed"); return }
            t.wakeScreen()
            let ok = t.sendImage(data, key: hw)
            t.commit()
            print("hw \(hw) \(data.count) bytes → \(ok ? "ok" : "FAILED")")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            t.close()
            return
        }

        // listen <seconds> — print every key press read through the transport (hardware test)
        if cmd == "listen" {
            let seconds = UInt32(cmdIndex + 2 < args.count ? (Int(args[cmdIndex + 2]) ?? 10) : 10)
            let device = DeckDevice()
            device.connectIfPossible()
            guard device.isConnected else { print("no device"); return }
            setvbuf(stdout, nil, _IOLBF, 0)
            device.onKeyPress = { key in print("key \(key)") }
            print("listening \(seconds)s — press keys now")
            RunLoop.current.run(until: Date().addingTimeInterval(Double(seconds)))
            device.disconnect()
            return
        }

        // fill <slot> <r> <g> <b> — solid colour, for hardware probing
        if cmd == "fill" {
            guard cmdIndex + 5 < args.count,
                  let slot = Int(args[cmdIndex + 2]),
                  let r = UInt8(args[cmdIndex + 3]), let g = UInt8(args[cmdIndex + 4]),
                  let b = UInt8(args[cmdIndex + 5]) else {
                print("usage: fill <slot> <r> <g> <b> [size]"); return
            }
            let side = (cmdIndex + 6 < args.count ? Int(args[cmdIndex + 6]) : nil) ?? ImagePrep.size(for: slot)
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                     blue: CGFloat(b) / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard let img = ctx.makeImage(),
                  let data = ImagePrep.prepareTall(img, side: side, height: side) else { return }

            let device = DeckDevice()
            device.connectIfPossible()
            guard device.isConnected else { print("no device"); return }
            let ok = device.setImage(slot: slot, jpeg: data)
            device.refresh()
            print("slot \(slot) ← rgb(\(r),\(g),\(b))  rc=\(ok ? 0 : 1)")
            device.disconnect()
            return
        }

        let device = DeckDevice()
        device.connectIfPossible()

        guard device.isConnected else {
            print("no device")
            return
        }

        switch cmd {
        case "info":
            print("connected  firmware=\(device.firmware ?? "unknown")")
        case "summary":
            // let the HID matching callback run, then print what the UI will show
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let d = device.deviceSummary
            print("model      \(d.model)")
            print("ids        \(d.idText)")
            print("manufacturer \(d.manufacturer ?? "—")")
            print("port       \(d.portText)")
            print("controller \(d.controllerText ?? "—")")
            print("firmware   \(d.firmware ?? "—")")
            print("serial     \(d.serial ?? "—")")
        case "image":
            guard cmdIndex + 3 < args.count,
                  let slot = Int(args[cmdIndex + 2]) else { print("usage: image <slot> <file>"); return }
            let path = args[cmdIndex + 3]
            guard let data = ImagePrep.prepare(url: URL(fileURLWithPath: path),
                                               side: ImagePrep.size(for: slot)) else {
                print("cannot read \(path)"); return
            }
            let ok = device.setImage(slot: slot, jpeg: data)
            device.refresh()
            print("slot \(slot) <- \(path)  (\(data.count) bytes)  rc=\(ok ? 0 : 1)")
        case "clear":
            device.clearAll()
            print("cleared")
        case "type":
            let text = args[(cmdIndex + 2)...].joined(separator: " ")
            print("trusted=\(AXIsProcessTrusted())")
            HotkeyEngine.post(text: text)
            print("typed \(text.count) characters")
        case "hotkey":
            guard cmdIndex + 3 < args.count,
                  let code = UInt16(args[cmdIndex + 2]) else { print("usage: hotkey <keycode> <flags>"); return }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(args[cmdIndex + 3]) ?? 0)
            print("trusted=\(AXIsProcessTrusted())")
            HotkeyEngine.post(keyCode: code, flags: flags)
            print("posted keyCode=\(code) \(HotkeyFormatter.describe(keyCode: code, flags: flags))")
        default:
            print("unknown command \(cmd)")
        }
        device.disconnect()
    }
}
