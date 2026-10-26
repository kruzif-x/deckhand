// hidprobe.swift — read-only probe of a vendor-defined HID device.
//
// Opens the Stream Dock (VID 0x5548 / PID 0x6674) through IOHIDManager, dumps every
// device property macOS exposes, then listens for input reports for a few seconds.
// It never writes an output/feature report, so nothing is changed on the device.
//
//   swiftc -O -framework IOKit -framework CoreFoundation hidprobe.swift -o hidprobe
//   ./hidprobe [seconds]
import Foundation
import IOKit.hid

let vendorID = 0x5548
let productID = 0x6674
let listenSeconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 6.0 : 6.0

func hex(_ data: Data, limit: Int = 64) -> String {
    let prefix = data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    return data.count > limit ? prefix + " … (\(data.count) bytes)" : prefix
}

func describe(_ dev: IOHIDDevice) {
    print("=== device ===")
    let keys = [
        kIOHIDVendorIDKey, kIOHIDProductIDKey, kIOHIDVersionNumberKey,
        kIOHIDProductKey, kIOHIDManufacturerKey, kIOHIDSerialNumberKey,
        kIOHIDTransportKey, kIOHIDLocationIDKey, kIOHIDPrimaryUsagePageKey,
        kIOHIDPrimaryUsageKey, kIOHIDMaxInputReportSizeKey,
        kIOHIDMaxOutputReportSizeKey, kIOHIDMaxFeatureReportSizeKey,
        kIOHIDReportIntervalKey, "Built-In", "HIDRMDeviceState",
    ]
    for key in keys {
        if let value = IOHIDDeviceGetProperty(dev, key as CFString) {
            let s = "\(value)"
            print(String(format: "  %-26s %@", (key as NSString).utf8String!, s))
        }
    }
    if let rd = IOHIDDeviceGetProperty(dev, kIOHIDReportDescriptorKey as CFString) as? Data {
        print("  reportDescriptor           \(hex(rd, limit: 96))")
    }
}

// line-buffer stdout so a background run's output is visible while it is still listening
setvbuf(stdout, nil, _IOLBF, 0)

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Any] = [
    kIOHIDVendorIDKey: vendorID,
    kIOHIDProductIDKey: productID,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

var opened = false
var reportCount = 0
var reportBytes = 0
var buffer = [UInt8](repeating: 0, count: 4096)

let inputCallback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    reportCount += 1
    reportBytes += length
    if reportCount <= 8 {
        let data = Data(bytes: report, count: length)
        print("  report[\(length)] \(hex(data, limit: 48))")
    }
}

let deviceCallback: IOHIDDeviceCallback = { _, _, _, dev in
    describe(dev)

    let openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    print("  IOHIDDeviceOpen -> \(openResult)")

    // Feature reports: the descriptor declares MaxFeatureReportSize = 0, so a device that
    // honours it answers kIOReturnUnsupported. Anything readable here is extra info the
    // firmware exposes; the call is GET-only, nothing is written back.
    for id in 0...7 {
        var feature = [UInt8](repeating: 0, count: 512)
        var len = 512
        let r = feature.withUnsafeMutableBufferPointer { buf -> IOReturn in
            IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(id), buf.baseAddress!, &len)
        }
        if r == kIOReturnSuccess && len > 0 {
            let data = Data(feature.prefix(len))
            print("  featureReport(id: \(id)) -> ok, len=\(len): \(hex(data, limit: 48))")
            if let text = String(data: data, encoding: .utf8), text.allSatisfy({ $0.isASCII && !$0.isNewline }) {
                print("      as ascii: \(text)")
            }
        } else {
            print("  featureReport(id: \(id)) -> \(r), len=\(len)")
        }
    }

    if openResult == kIOReturnSuccess {
        opened = true
        buffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceRegisterInputReportCallback(
                dev, buf.baseAddress!, buf.count, inputCallback, nil)
        }
        print("  listening for input reports for \(Int(listenSeconds))s …")
    }
}

IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let managerOpen = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen -> \(managerOpen)")

CFRunLoopRunInMode(CFRunLoopMode.defaultMode, listenSeconds, false)

print("=== result ===")
print("  device opened: \(opened)")
print("  input reports: \(reportCount) (\(reportBytes) bytes)")
if reportCount == 0 {
    print("  (device is quiet until the vendor protocol polls it: no unsolicited traffic)")
}
exit(0)
