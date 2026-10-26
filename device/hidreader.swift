// hidreader.swift — IOHID input reader for the Stream Dock 293 (VID 0x5548 / PID 0x6674).
//
// The vendor SDK's decoder is unusable for this unit: StreamDock._is_input_event_packet()
// requires packets framed "ACK"/"OK" (41 43 4B … 4F 4B) while the firmware sends a 512-byte
// report that is all zeros except byte 9 (key code) and byte 10 (state). Every press fails
// that test and is dropped. This reader takes the reports straight from IOHID and prints one
// JSON line per event, so any language can consume it.
//
//   swiftc -O -framework IOKit -framework CoreFoundation hidreader.swift -o hidreader
//   ./hidreader            # stream JSON lines until killed
//   ./hidreader 30         # stop after 30 s
//
// Output:
//   {"hw":13,"state":0,"logical":1}      // key 1 on the hardware = logical key 1
import Foundation
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)

let VENDOR: Int = 0x5548
let PRODUCT: Int = 0x6674

// hardware code -> logical key, from StreamDock293s._IMAGE_KEY_MAP
let hardwareToLogical: [Int: Int] = [
    13: 1, 10: 2, 7: 3, 4: 4, 1: 5,
    14: 6, 11: 7, 8: 8, 5: 9, 2: 10,
    15: 11, 12: 12, 9: 13, 6: 14, 3: 15,
    16: 16, 17: 17, 18: 18,
]

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 0) : 0

func emit(_ json: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: json),
       let s = String(data: d, encoding: .utf8) {
        print(s)
    }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT,
] as CFDictionary)

var buffer = [UInt8](repeating: 0, count: 4096)

let inputCallback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    guard length >= 11 else { return }
    let code = Int(report[9])
    let state = Int(report[10])
    if code == 0 || code == 0xFF { return }        // idle padding / write ack
    var json: [String: Any] = ["hw": code, "state": state]
    if let logical = hardwareToLogical[code] { json["logical"] = logical }
    emit(json)
}

let deviceCallback: IOHIDDeviceCallback = { _, _, _, dev in
    if let fw = IOHIDDeviceGetProperty(dev, "Product" as CFString) {
        emit(["device": "\(fw)"])
    } else {
        emit(["device": "streamdock", "vid": VENDOR, "pid": PRODUCT])
    }
    let rc = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    guard rc == kIOReturnSuccess else {
        emit(["error": "open failed", "code": Int(rc)])
        return
    }
    buffer.withUnsafeMutableBufferPointer { buf in
        IOHIDDeviceRegisterInputReportCallback(dev, buf.baseAddress!, buf.count, inputCallback, nil)
    }
    emit(["ready": true])
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
    emit(["error": "manager open failed"])
    exit(1)
}

if seconds > 0 {
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false)
    exit(0)
}
CFRunLoopRun()
