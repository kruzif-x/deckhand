// Device.swift — the panel API. Output and input both go through NativeTransport, Deckhand's own
// IOKit driver: the vendor libtransport.dylib is neither loaded nor shipped.
//
// The protocol constants live in NativeTransport.swift, with the addresses they were recovered from.
import Foundation
import IOKit
import IOKit.hid
import AppKit

/// What the OS reports about the panel — model, ids, firmware and the physical USB port.
struct DeviceSummary: Equatable {
    var model: String = "Stream Dock"
    var vendor: UInt16 = DeckDevice.vendorID
    var product: UInt16 = DeckDevice.productID
    var firmware: String?
    var serial: String?
    var locationID: UInt32?
    var portNode: String?
    var controller: String?
    var manufacturer: String?

    var idText: String { String(format: "0x%04X : 0x%04X", vendor, product) }

    var portText: String {
        var parts: [String] = []
        if let portNode { parts.append(portNode) }
        if let locationID {
            let bus = (locationID >> 24) & 0xFF
            parts.append(String(format: "0x%08X", locationID))
            if bus > 0 { parts.append("bus \(bus)") }
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var controllerText: String? { controller }

    /// Sidebar-width friendly: the ids are shown on their own row.
    var modelShort: String {
        model.replacingOccurrences(of: #"\s*\(0x[0-9A-Fa-f]+\)$"#, with: "", options: .regularExpression)
    }
}

final class DeckDevice {
    static let vendorID: UInt16 = 0x5548
    static let productID: UInt16 = 0x6674

    // 15 pressable keys, then the 1x3 window (display only)
    static let buttonSlots = 1...15
    static let windowSlots = 16...18

    /// The panel numbers its keys by hardware code, not by the order you see. Images must be
    /// written to the hardware code, otherwise every picture lands on the wrong key:
    /// logical 1 (top-left) is hardware 13, logical 5 (top-right) is hardware 1, and so on.
    static let logicalToHardware: [Int: Int] = [
        1: 13, 2: 10, 3: 7, 4: 4, 5: 1,
        6: 14, 7: 11, 8: 8, 9: 5, 10: 2,
        11: 15, 12: 12, 13: 9, 14: 6, 15: 3,
        16: 16, 17: 17, 18: 18,
    ]

    static let hardwareToLogical: [Int: Int] = [
        13: 1, 10: 2, 7: 3, 4: 4, 1: 5,
        14: 6, 11: 7, 8: 8, 5: 9, 2: 10,
        15: 11, 12: 12, 9: 13, 6: 14, 3: 15,
    ]

    private let native = NativeTransport()
    private var hidManager: IOHIDManager?
    private var heartbeat: Timer?
    private(set) var firmware: String?
    private(set) var summary = DeviceSummary()

    var onKeyPress: ((Int) -> Void)? {
        get { native.onKeyPress }
        set { native.onKeyPress = newValue }
    }
    var onConnectionChange: ((Bool) -> Void)?

    var isConnected: Bool { native.isOpen }
    var deviceSummary: DeviceSummary { summary }

    init() {}

    // MARK: lifecycle

    func connectIfPossible() {
        guard !native.isOpen else { return }
        guard native.open() else { return }

        firmware = native.firmware
        summary.firmware = firmware
        startMonitoring()
        _ = native.wakeScreen()
        _ = native.setBrightness(90)
        startHeartbeat()
        Log.write("panel opened with the native driver · fw \(firmware ?? "unknown")")
        onConnectionChange?(true)
    }

    func disconnect() {
        heartbeat?.invalidate(); heartbeat = nil
        if let hidManager { IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        hidManager = nil
        native.close()
        summary = DeviceSummary()
        onConnectionChange?(false)
    }

    private func handleRemoval() {
        guard native.isOpen else { return }
        heartbeat?.invalidate(); heartbeat = nil
        native.close()
        firmware = nil
        summary = DeviceSummary()
        Log.write("panel disconnected (unplugged)")
        onConnectionChange?(false)
    }

    private func startHeartbeat() {
        // the firmware expects a keep-alive; our driver sends the same "CRT\0\0CONNECT" frame
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.native.isOpen else { return }
            self.native.heartbeat()
        }
    }

    // MARK: output

    @discardableResult
    func setImage(slot: Int, jpeg: Data) -> Bool {
        guard native.isOpen else { return false }
        let hardware = Self.logicalToHardware[slot] ?? slot
        return native.sendImage(jpeg, key: hardware)
    }

    func setBrightness(_ percent: UInt8) {
        guard native.isOpen else { return }
        native.setBrightness(percent)
    }

    func clearAll() {
        guard native.isOpen else { return }
        for slot in Self.buttonSlots { _ = setImage(slot: slot, jpeg: Self.blackFrame) }
    }

    /// Called after every batch: wake first (the panel ignores writes while asleep), then keep-alive.
    func refresh() {
        guard native.isOpen else { return }
        native.wakeScreen()
        native.commit()
        native.heartbeat()
    }

    /// Wake the panel before a burst of image writes.
    func prepareForWrite() {
        guard native.isOpen else { return }
        native.wakeScreen()
    }

    /// Report the active page to the firmware ("M_V" + page). Pages are host-side: the panel
    /// stores no page data and accepted every value 0…255 without complaint.
    func setPage(_ index: Int) {
        guard native.isOpen else { return }
        native.setPage(max(0, index))
    }

    /// 85×85 near-black JPEG, rendered once and reused for blanking.
    static let blackFrame: Data = {
        let side = 85
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(gray: 0.03, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = ctx.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg,
                                                              properties: [.compressionFactor: 0.9]) ?? Data()
    }()

    // MARK: summary + hotplug

    private func startMonitoring() {
        guard hidManager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
        ] as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            guard let ctx else { return }
            let me = Unmanaged<DeckDevice>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                me.gatherSummary(from: dev)
                if !me.native.isOpen { me.connectIfPossible() }
            }
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<DeckDevice>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.handleRemoval() }
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = m
    }

    /// Read model, ids, serial and the physical USB port from the HID device and its parents.
    /// The chain on this Mac is:
    ///   IOUSBHostInterface → IOUSBHostDevice → usb-drd2-port-hs (AppleUSB20XHCIARMPort)
    ///   → AppleT8112USBXHCI → usb-drd2 → arm-io
    private func gatherSummary(from dev: IOHIDDevice) {
        func prop(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        func name(_ entry: io_registry_entry_t) -> String {
            var buf = [CChar](repeating: 0, count: 256)
            IORegistryEntryGetName(entry, &buf)
            return String(cString: buf)
        }
        func cls(_ entry: io_registry_entry_t) -> String {
            var buf = [CChar](repeating: 0, count: 256)
            IOObjectGetClass(entry, &buf)
            return String(cString: buf)
        }
        func stringProp(_ d: IOHIDDevice, _ key: String) -> String? {
            (IOHIDDeviceGetProperty(d, key as CFString) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func intProp(_ d: IOHIDDevice, _ key: String) -> Int? {
            (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue
        }

        var s = DeviceSummary()
        s.vendor = UInt16(truncatingIfNeeded: intProp(dev, kIOHIDVendorIDKey) ?? Int(Self.vendorID))
        s.product = UInt16(truncatingIfNeeded: intProp(dev, kIOHIDProductIDKey) ?? Int(Self.productID))
        s.locationID = intProp(dev, kIOHIDLocationIDKey).map { UInt32(truncatingIfNeeded: $0) }
        s.serial = stringProp(dev, kIOHIDSerialNumberKey)

        var productName = stringProp(dev, kIOHIDProductKey) ?? ""
        var vendorName = stringProp(dev, kIOHIDManufacturerKey) ?? ""

        var entry = IOHIDDeviceGetService(dev)
        var portNode: String?
        var controller: String?
        var depth = 0

        while entry != 0, depth < 8 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { break }
            let parentName = name(parent)
            let parentClass = cls(parent)
            if portNode == nil, parentClass.contains("Port") || parentName.contains("port") {
                portNode = parentName
                if s.locationID == nil, let loc = prop(parent, "locationID") as? NSNumber {
                    s.locationID = UInt32(truncatingIfNeeded: loc.intValue)
                }
            }
            if controller == nil, parentClass.contains("XHCI"), !parentClass.contains("Port"),
               !parentName.contains("port") {
                controller = parentName
            }
            if productName.isEmpty, let p = prop(parent, "USB Product Name") as? String {
                productName = p.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if vendorName.isEmpty, let v = prop(parent, "USB Vendor Name") as? String {
                vendorName = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            entry = parent
            depth += 1
        }

        s.model = productName.isEmpty
            ? "Stream Dock 293S (\(String(format: "0x%04X", s.product)))"
            : (productName.localizedCaseInsensitiveContains("293")
                ? productName
                : "\(productName) 293S")
        s.manufacturer = vendorName.isEmpty ? nil : vendorName
        s.portNode = portNode
        s.controller = controller
        s.firmware = firmware ?? native.firmware
        summary = s
        DispatchQueue.main.async { self.onConnectionChange?(true) }
    }
}
