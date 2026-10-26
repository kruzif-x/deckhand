// hidraw.swift — log EVERY input report, unfiltered, with a timestamp.
//
// hidreader deliberately drops idle padding and write acks; that is wrong when the question is
// "does this firmware emit a release event?" — a release may not carry the key code in byte 9
// and would be filtered out. This dumper prints every report with the offsets of all non-zero
// bytes, so press and release edges can be told apart from the raw stream.
//
//   swiftc -O -framework IOKit -framework CoreFoundation hidraw.swift -o hidraw
//   ./hidraw            # log until killed
//   ./hidraw 30         # log for 30 s
import Foundation
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)

let VENDOR: Int = 0x5548
let PRODUCT: Int = 0x6674
let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 0) : 0

let t0 = Date()

func emit(_ json: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: json),
       let s = String(data: d, encoding: .utf8) { print(s) }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT,
] as CFDictionary)

var buffer = [UInt8](repeating: 0, count: 4096)

let inputCallback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    let n = Int(length)
    let buf = UnsafeBufferPointer(start: report, count: n)
    var nonzero: [String] = []
    for i in 0..<min(n, 64) where buf[i] != 0 {
        nonzero.append("\(i)=\(String(format: "%02x", buf[i]))")
    }
    let head = (0..<min(n, 16)).map { String(format: "%02x", buf[$0]) }.joined(separator: " ")
    emit([
        "t_ms": Int(Date().timeIntervalSince(t0) * 1000),
        "len": n,
        "head": head,
        "nonzero": nonzero.joined(separator: " "),
    ])
}

let deviceCallback: IOHIDDeviceCallback = { _, _, _, dev in
    let rc = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    guard rc == kIOReturnSuccess else { emit(["error": "open failed", "code": Int(rc)]); return }
    buffer.withUnsafeMutableBufferPointer { b in
        IOHIDDeviceRegisterInputReportCallback(dev, b.baseAddress!, b.count, inputCallback, nil)
    }
    emit(["ready": true])
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
    emit(["error": "manager open failed"]); exit(1)
}
if seconds > 0 { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false); exit(0) }
CFRunLoopRun()
