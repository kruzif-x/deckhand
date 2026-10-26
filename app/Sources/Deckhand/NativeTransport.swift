// NativeTransport.swift — Deckhand's own driver for the Stream Dock 293S. No vendor dylib.
//
// Recovered from libtransport.dylib (arm64, Ghidra):
//
//   reports     512-byte output reports: [payload][0x00 pad]; the vendor counts 513 with report ID
//   commands    "CRT\0\0BAT" + BE32(len) + key + jpeg    image
//               "CRT\0\0LIG" + 0x00 0x00 + percent       brightness
//               "CRT\0\0STP"                             commit / refresh after a batch
//               "CRT\0\0DIS"                             wake the screen
//               "CRT\0\0CONNECT"                         keep-alive
//               "M_V" + page                             change page
//   chunking    511 bytes per report (TransportSession::chunkSize)
//   handshake   TransportSession::transact() reads one input report after every write
//               (TransportDevice::readReserved → hid_read_timeout). The panel stops accepting
//               data once those acknowledgements are never drained — this was the missing half.
import Foundation
import IOKit
import IOKit.hid

final class NativeTransport {
    static let vendorID: Int = 0x5548
    static let productID: Int = 0x6674

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    private var ioThread: Thread?
    private var ioRunLoop: CFRunLoop?

    /// Signalled by every incoming report: one ack per outgoing report.
    private let ackSemaphore = DispatchSemaphore(value: 0)
    private var ackTimeouts = 0

    private let reportID: UInt8 = 0x00
    private let reportSize = 513                 // report ID + 512 payload, as the vendor counts it
    private var chunkSize: Int { reportSize - (reportID == 0 ? 0 : 1) - 1 }

    private(set) var firmware: String?
    var onKeyPress: ((Int) -> Void)?

    static let hardwareToLogical: [Int: Int] = [
        13: 1, 10: 2, 7: 3, 4: 4, 1: 5,
        14: 6, 11: 7, 8: 8, 5: 9, 2: 10,
        15: 11, 12: 12, 9: 13, 6: 14, 3: 15,
    ]

    var isOpen: Bool { device != nil }

    // MARK: lifecycle

    func open() -> Bool {
        guard device == nil else { return true }

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,
              let dev = set.first else {
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }

        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }

        manager = m
        device = dev
        firmware = readFirmware(dev)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(m, { ctx, result, _, _, _, report, length in
            guard let ctx, result == kIOReturnSuccess else { return }
            Unmanaged<NativeTransport>.fromOpaque(ctx).takeUnretainedValue()
                .handle(report: report, length: length)
        }, ctx)

        // Input reports carry both key presses and the per-write acks, so they are delivered on a
        // dedicated run-loop thread: the writer must be able to wait on the semaphore without
        // stalling the loop that signals it.
        startIOLoop(for: dev)
        return true
    }

    private func startIOLoop(for dev: IOHIDDevice) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.ioRunLoop = CFRunLoopGetCurrent()
            if let manager = self.manager {
                IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(),
                                                CFRunLoopMode.defaultMode.rawValue)
            }
            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(),
                                           CFRunLoopMode.defaultMode.rawValue)
            while self.device != nil {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false)
            }
        }
        thread.name = "deckhand.hid"
        thread.qualityOfService = .userInteractive
        thread.start()
        ioThread = thread
    }

    func close() {
        if let device, let loop = ioRunLoop {
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
        }
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        if let loop = ioRunLoop { CFRunLoopStop(loop) }
        ioRunLoop = nil
        ioThread = nil
        if let manager {
            if let loop = ioRunLoop {
                IOHIDManagerUnscheduleFromRunLoop(manager, loop, CFRunLoopMode.defaultMode.rawValue)
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    // MARK: input / acknowledgements

    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var lastCode = -1
    private var lastTime = Date.distantPast

    private func handle(report: UnsafePointer<UInt8>, length: Int) {
        ackSemaphore.signal()          // one report = one acknowledgement

        guard length >= 11 else { return }
        let code = Int(report[9])
        guard code != 0, code != 0xFF, let logical = Self.hardwareToLogical[code] else { return }

        // the firmware repeats a report while a key is held: one press = one action
        let now = Date()
        if code == lastCode, now.timeIntervalSince(lastTime) < 0.35 { return }
        lastCode = code
        lastTime = now
        DispatchQueue.main.async { [weak self] in self?.onKeyPress?(logical) }
    }

    private func readFirmware(_ dev: IOHIDDevice) -> String? {
        for id in 1...8 {
            var buf = [UInt8](repeating: 0, count: 512)
            var len = 512
            let rc = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(id), &buf, &len)
            guard rc == kIOReturnSuccess, len > 2 else { continue }
            let text = String(decoding: buf.prefix(min(len, 64)).filter { $0 >= 0x20 && $0 < 0x7F },
                              as: UTF8.self)
            if text.hasPrefix("V"), text.count >= 4 { return text }
        }
        return nil
    }

    // MARK: output

    /// One report, then wait for the panel to acknowledge it.
    private func writeReport(_ slice: ArraySlice<UInt8>) -> Bool {
        guard let device else { return false }
        var report = [UInt8](repeating: 0, count: reportSize - 1)
        for (i, byte) in slice.enumerated() { report[i] = byte }

        let rc = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID),
                                 buf.baseAddress!, buf.count)
        }
        guard rc == kIOReturnSuccess else { return false }

        // The panel does not acknowledge image reports (the vendor's own read times out as well),
        // so pace instead of waiting: 2 ms between reports keeps the device's buffer happy.
        usleep(2_000)
        return true
    }

    @discardableResult
    func write(_ payload: [UInt8]) -> Bool {
        guard device != nil else { return false }
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            guard writeReport(payload[offset..<end]) else { return false }
            offset = end
        }
        return true
    }

    /// One image = one 13-byte header report followed by the JPEG in its own reports.
    /// Captured from the vendor library under lldb (IOHIDDeviceSetReport, arm64):
    ///   report 1  "CRT\0\0BAT" + BE32(len) + key, zero padded to 512
    ///   report 2n JPEG bytes, 511 per report
    /// Concatenating header and JPEG into one stream (my first attempt) makes the panel ignore it.
    @discardableResult
    func sendImage(_ jpeg: Data, key: Int) -> Bool {
        let n = UInt32(jpeg.count)
        var header: [UInt8] = [0x43, 0x52, 0x54, 0x00, 0x00, 0x42, 0x41, 0x54]
        header += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                   UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        header.append(UInt8(truncatingIfNeeded: key))
        guard writeReport(header[...]) else { return false }

        var offset = 0
        while offset < jpeg.count {
            let end = min(offset + 512, jpeg.count)   // TransportSession::chunkSize = 513 − 1 = 512
            let slice = jpeg[offset..<end]
            guard writeReport(ArraySlice(slice)) else { return false }
            offset = end
        }
        return true
    }

    @discardableResult
    func setPage(_ page: Int) -> Bool {
        write([0x4D, 0x5F, 0x56, UInt8(truncatingIfNeeded: page)])   // "M_V" + page
    }

    @discardableResult
    func setBrightness(_ percent: UInt8) -> Bool {
        write([0x43, 0x52, 0x54, 0x00, 0x00, 0x4C, 0x49, 0x47, 0x00, 0x00, min(percent, 100)])
    }

    /// "CRT\0\0STP" — the vendor's refresh(); a batch is only shown once this lands.
    @discardableResult
    func commit() -> Bool {
        write([0x43, 0x52, 0x54, 0x00, 0x00, 0x53, 0x54, 0x50])
    }

    /// "CRT\0\0DIS" — the panel ignores image writes while its screen is off.
    @discardableResult
    func wakeScreen() -> Bool {
        write([0x43, 0x52, 0x54, 0x00, 0x00, 0x44, 0x49, 0x53])
    }

    @discardableResult
    func heartbeat() -> Bool {
        write(Array("CRT\u{0}\u{0}CONNECT".utf8))
    }
}
