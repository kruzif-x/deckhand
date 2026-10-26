// Hotkey.swift — key-combination formatting, keystroke emission, and a recorder control.
import AppKit
import Carbon.HIToolbox
import SwiftUI

enum HotkeyFormatter {
    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6",
        98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4",
        119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func describe(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += keyNames[keyCode] ?? "key \(keyCode)"
        return s
    }
}

enum HotkeyEngine {
    /// Synthetic keystrokes need Accessibility permission; everything else works without it.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func post(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        let cgFlags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        down.flags = cgFlags
        up.flags = cgFlags
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
    }

    /// US-layout character map: real key events are far more reliable than unicode injection
    /// (some AppKit text views ignore synthetic unicode-only events).
    private static let charMap: [Character: (UInt16, Bool)] = {
        let rows: [(String, UInt16)] = [
            ("abcdefghijklmnopqrstuvwxyz", 0), ("1234567890", 18),
        ]
        _ = rows
        var m: [Character: (UInt16, Bool)] = [:]
        let plain: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
            ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29),
            ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
            ("n", 45), ("m", 46), (".", 47), (" ", 49), ("`", 50),
        ]
        for (ch, code) in plain { m[ch] = (code, false) }
        let shifted: [(Character, UInt16)] = [
            ("A", 0), ("S", 1), ("D", 2), ("F", 3), ("H", 4), ("G", 5), ("Z", 6), ("X", 7),
            ("C", 8), ("V", 9), ("B", 11), ("Q", 12), ("W", 13), ("E", 14), ("R", 15),
            ("Y", 16), ("T", 17), ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("^", 22),
            ("%", 23), ("+", 24), ("(", 25), ("&", 26), ("_", 27), ("*", 28), (")", 29),
            ("}", 30), ("O", 31), ("U", 32), ("{", 33), ("I", 34), ("P", 35), ("L", 37),
            ("J", 38), ("\"", 39), ("K", 40), (":", 41), ("|", 42), ("<", 43), ("?", 44),
            ("N", 45), ("M", 46), (">", 47),
        ]
        for (ch, code) in shifted { m[ch] = (code, true) }
        return m
    }()

    static func post(text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            if ch == "\n" {
                post(keyCode: 36, flags: [])
                continue
            }
            if let (code, shift) = charMap[ch] {
                let flags: NSEvent.ModifierFlags = shift ? .shift : []
                guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
                      let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { continue }
                let cg = CGEventFlags(rawValue: UInt64(flags.rawValue))
                down.flags = cg; up.flags = cg
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(6_000)
            } else {
                // non-ASCII: fall back to unicode injection
                guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
                var utf16 = Array(String(ch).utf16)
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(6_000)
            }
        }
    }

    /// Runs a script file. A plain path (what the picker produces) is executed with the right
    /// interpreter; anything that isn't a file is still treated as a shell command so old
    /// bindings made in the text field keep working.
    static func runScript(_ target: String) {
        let path = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        let process = Process()
        if FileManager.default.fileExists(atPath: path) {
            let ext = (path as NSString).pathExtension.lowercased()
            switch ext {
            case "scpt", "applescript":
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [path]
            case "sh", "zsh", "bash", "command":
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [path]
            default:
                if FileManager.default.isExecutableFile(atPath: path) {
                    process.executableURL = URL(fileURLWithPath: path)
                } else {
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = [path]
                }
            }
            Log.write("running script \(path)")
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", path]
            Log.write("running command \(path)")
        }
        // capture stderr/exit so a blocked script (TCC, bad shebang, missing interpreter)
        // reports why instead of failing silently
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        process.terminationHandler = { finished in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if finished.terminationStatus != 0 {
                Log.write("script exited \(finished.terminationStatus)\(output.isEmpty ? "" : ": " + output)")
            } else if !output.isEmpty {
                Log.write("script output: \(output)")
            }
        }
        do { try process.run() } catch { Log.write("script failed to start: \(error.localizedDescription)") }
    }

    /// Post a system-defined media key (volume up/down, mute). These are the same events the F11/F12
    /// keys generate, so no Accessibility translation is needed beyond the normal key-event grant.
    static func systemKey(_ code: Int) {
        func post(_ down: Bool) {
            let flags = down ? 0xA00 : 0xB00
            let data1 = (code << 16) | flags
            if let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                              modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, subtype: 8, data1: data1, data2: -1) {
                event.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(true)
        usleep(20_000)
        post(false)
    }

    static func run(_ action: KeyAction) {
        if action.kind == .hotkey, !isTrusted {
            Log.write("blocked: no Accessibility permission for synthetic keystrokes")
        }
        switch action.kind {
        case .none:
            break
        case .hotkey:
            post(keyCode: action.keyCode, flags: NSEvent.ModifierFlags(rawValue: action.modifierFlags))
        case .text:
            post(text: action.text)
        case .openApp:
            let url = URL(fileURLWithPath: action.target)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        case .openURL:
            if let url = URL(string: action.target) { NSWorkspace.shared.open(url) }
        case .mute:
            systemKey(7)                  // NX_KEYTYPE_MUTE
        case .volumeUp:
            systemKey(0)                  // NX_KEYTYPE_SOUND_UP
        case .volumeDown:
            systemKey(1)                  // NX_KEYTYPE_SOUND_DOWN
        case .page, .pageNext, .pagePrevious, .pageHome:
            break          // handled by DeckModel, which owns the profile store
        case .shell:
            runScript(action.target)
        }
    }
}

// MARK: - recorder

/// Small AppKit view that captures one keystroke plus modifiers.
final class RecorderView: NSView {
    var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isArmed = false
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    func arm() {
        isArmed = true
        window?.makeFirstResponder(self)
    }

    func disarm() {
        isArmed = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    override func keyDown(with event: NSEvent) {
        guard isArmed else { return super.keyDown(with: event) }
        if event.keyCode == 53 { onCancel?(); disarm(); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        onCapture?(event.keyCode, flags)
        disarm()
    }

    override func flagsChanged(with event: NSEvent) {
        // modifiers alone never complete a binding; wait for the real key
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !isArmed { arm() }
    }
}

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt16
    @Binding var flags: UInt
    @Binding var recording: Bool

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onCapture = { code, mods in
            keyCode = code
            flags = mods.rawValue
            recording = false
        }
        v.onCancel = { recording = false }
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) {
        if recording, !v.isArmed { v.arm() }
        if !recording, v.isArmed { v.disarm() }
    }
}
