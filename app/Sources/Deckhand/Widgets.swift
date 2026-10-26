// Widgets.swift — the 1×3 window panes are host-rendered widgets.
//
// The panel has no widgets of its own: it just shows an image per pane, so the app renders an
// 80×80 JPEG on a timer and pushes it. Clock/date/CPU/memory/page number are all computed here.
import Foundation
import AppKit
import CoreText
import SwiftUI

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case none, clock, date, cpu, memory, page, text
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .clock: "Clock"
        case .date: "Date"
        case .cpu: "CPU usage"
        case .memory: "Memory usage"
        case .page: "Page number"
        case .text: "Custom text"
        }
    }

    var symbol: String {
        switch self {
        case .none: "slash.circle"
        case .clock: "clock"
        case .date: "calendar"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .page: "square.grid.3x3.middle.filled"
        case .text: "textformat"
        }
    }

    /// Seconds between refreshes — a static label does not need a timer tick.
    var refreshInterval: Double {
        switch self {
        case .none: 0
        case .clock: 1
        case .cpu, .memory: 2
        case .date, .page, .text: 60
        }
    }
}

/// How the panes meet the white bezel between them.
enum SeamStyle: String, Codable, CaseIterable, Identifiable {
    case separate        // inset card per pane, border all round
    case connected       // edge-to-edge design with a spine + gradient so the gap reads as a seam
    var id: String { rawValue }
    var title: String { self == .separate ? "Separate tiles" : "Continuous design" }
}

enum WindowMode: String, Codable, CaseIterable, Identifiable {
    case span            // one widget across the whole 240×80 strip
    case perPane         // three independent widgets
    var id: String { rawValue }
    var title: String { self == .span ? "Span the whole window" : "One widget per pane" }
}

/// How the 1×3 window is used. Stored per profile so it travels with Save As.
struct WindowConfig: Codable, Equatable {
    var mode: WindowMode = .perPane
    var widget: WidgetConfig = WidgetConfig()
    /// The 1×3 window has no separating bezel, so a spanning widget is drawn across the whole
    /// 240×80 surface. Flip to false only for a unit that really does have pane gaps.
    var bleed: Bool = true
    var seam: SeamStyle = .separate
    /// Height actually accepted by the pane window. The firmware crops from the top, so padding
    /// past 80 px is what paints the pale bands between panes black.
    var paneHeight: Int = 80

    // Tolerant decoding: a missing key must never invalidate the whole profile file
    // (synthesised Codable throws on absent non-optional keys, which silently dropped every
    // profile and reverted the app to an empty "Main").
    private enum CodingKeys: String, CodingKey { case mode, widget, bleed, seam, paneHeight }

    init(mode: WindowMode = .perPane, widget: WidgetConfig = WidgetConfig(),
         bleed: Bool = true, seam: SeamStyle = .separate, paneHeight: Int = 80) {
        self.mode = mode
        self.widget = widget
        self.bleed = bleed
        self.seam = seam
        self.paneHeight = paneHeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(WindowMode.self, forKey: .mode) ?? .perPane
        widget = try c.decodeIfPresent(WidgetConfig.self, forKey: .widget) ?? WidgetConfig()
        bleed = try c.decodeIfPresent(Bool.self, forKey: .bleed) ?? true
        seam = try c.decodeIfPresent(SeamStyle.self, forKey: .seam) ?? .separate
        paneHeight = try c.decodeIfPresent(Int.self, forKey: .paneHeight) ?? 80
    }
}

struct WidgetConfig: Codable, Equatable {
    var kind: WidgetKind = .none
    var text: String = ""
    var showsSeconds: Bool = false

    private enum CodingKeys: String, CodingKey { case kind, text, showsSeconds }

    init(kind: WidgetKind = .none, text: String = "", showsSeconds: Bool = false) {
        self.kind = kind
        self.text = text
        self.showsSeconds = showsSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(WidgetKind.self, forKey: .kind) ?? .none
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        showsSeconds = try c.decodeIfPresent(Bool.self, forKey: .showsSeconds) ?? false
    }
}

// MARK: - system figures

enum SysInfo {
    private static var lastCPU: (busy: UInt64, total: UInt64)?

    static func cpuPercent() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice
        let total = busy &+ idle
        defer { lastCPU = (busy, total) }
        guard let last = lastCPU, total > last.total else { return 0 }
        let dBusy = Double(busy &- last.busy), dTotal = Double(total &- last.total)
        return dTotal > 0 ? min(100, max(0, dBusy / dTotal * 100)) : 0
    }

    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    static func memoryUsedPercent() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.inactive_count)
                    + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        return total > 0 ? min(100, Double(used) / Double(total) * 100) : 0
    }
}

// MARK: - renderer

enum WidgetRenderer {
    static let side = 80
    static let stripWidth = 80          // the window is vertical: 80 wide × 240 tall

    /// Render one widget across the whole window, then cut it into the three panes.
    /// Each pane gets its own crop and its own single firmware rotation.
    static func stripJpegs(for config: WidgetConfig, page: (index: Int, count: Int),
                           now: Date = Date(), bleed: Bool = true,
                           seam: SeamStyle = .separate, paneHeight: Int = 80) -> [Data] {
        guard config.kind != .none,
              let strip = stripImage(for: config, page: page, now: now, bleed: bleed, seam: seam) else { return [] }
        var out: [Data] = []
        let height = max(side, paneHeight)
        for pane in 0..<3 {
            let rect = CGRect(x: 0, y: pane * side, width: side, height: side)
            guard let crop = strip.cropping(to: rect) else { continue }

            // pad to the height the window actually shows, designs centred, padding pure black
            guard let ctx = CGContext(data: nil, width: side, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: height))
            ctx.draw(crop, in: CGRect(x: 0, y: (height - side) / 2, width: side, height: side))

            guard let img = ctx.makeImage(), let data = ImagePrep.prepareTall(img, side: side, height: height) else { continue }
            out.append(data)
        }
        return out
    }

    static func stripImage(for config: WidgetConfig, page: (index: Int, count: Int),
                           now: Date = Date(), bleed: Bool = true,
                           seam: SeamStyle = .separate) -> CGImage? {
        guard config.kind != .none else { return nil }
        let width = CGFloat(side), height = CGFloat(side * 3)
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)


        func text(_ string: String, size fontSize: CGFloat, weight: NSFont.Weight,
                  x: CGFloat, baseline: CGFloat, color: NSColor = .white, mono: Bool = true) {
            let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
                            : NSFont.systemFont(ofSize: fontSize, weight: weight)
            let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, ctx)
        }
        func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight, mono: Bool = true) -> CGFloat {
            let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                            : NSFont.systemFont(ofSize: size, weight: weight)
            let attr = NSAttributedString(string: string, attributes: [.font: font])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
        }

        _ = bleed
        drawBleed(ctx, width: width, height: height, config: config, page: page, now: now, seam: seam)
        return ctx.makeImage()
    }

    // MARK: full-bleed layout (no bezel between the panes)

    private static func drawBleed(_ ctx: CGContext, width: CGFloat, height: CGFloat,
                                  config: WidgetConfig, page: (index: Int, count: Int), now: Date,
                                  seam: SeamStyle) {
        func font(_ size: CGFloat, _ weight: NSFont.Weight, mono: Bool = true) -> NSFont {
            mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                 : NSFont.systemFont(ofSize: size, weight: weight)
        }
        func line(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight,
                  x: CGFloat, baseline: CGFloat, color: NSColor = .white, mono: Bool = true) -> CGFloat {
            let attr = NSAttributedString(string: string,
                                          attributes: [.font: font(size, weight, mono: mono), .foregroundColor: color])
            let l = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(l, ctx)
            return CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        }
        func measure(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, mono: Bool = true) -> CGFloat {
            let attr = NSAttributedString(string: string, attributes: [.font: font(size, weight, mono: mono)])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
        }
        let cell = CGFloat(side)
        let margin: CGFloat = seam == .separate ? 10 : 14
        let grey = NSColor(white: 0.8, alpha: 1)

        // White plastic bezels separate the panes, so each pane is its own tile with an inset.
        // Nothing is drawn across a boundary, and the 6 px margin keeps text off the keycap edge.
        // continuous style: one gradient down the whole column and a spine that lines up across
        // the gaps, so the three panes read as one surface even though the band is not paintable
        if seam == .connected {
            let colours = [CGColor(red: 0.14, green: 0.16, blue: 0.20, alpha: 1),
                           CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colours, locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: height),
                                       end: CGPoint(x: 0, y: 0), options: [])
            }
            ctx.setFillColor(CGColor(red: 0.35, green: 0.72, blue: 0.95, alpha: 0.95))
            ctx.fill(CGRect(x: 0, y: 0, width: 3, height: height))          // left spine
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
            ctx.fill(CGRect(x: width - 1, y: 0, width: 1, height: height))  // right hairline
        }

        for band in 0..<3 {
            // "connected": paint edge to edge so a graphic runs into the bezel and appears to
            // continue on the next pane. "separate": inset card with its own border.
            let inset: CGFloat = seam == .separate ? 3 : 0
            let rect = CGRect(x: inset, y: height - CGFloat(band + 1) * cell + inset,
                              width: width - inset * 2, height: cell - inset * 2)
            if seam == .separate {
                ctx.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1))
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil))
                ctx.fillPath()
            }

            if seam == .separate {
                ctx.setStrokeColor(CGColor(red: 0.24, green: 0.60, blue: 0.82, alpha: 0.9))
                ctx.setLineWidth(1)
                ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   cornerWidth: 9, cornerHeight: 9, transform: nil))
                ctx.strokePath()
            }
        }

        // three 80 px bands, top → bottom (CG origin is bottom-left, so band 0 is the top one)
        func bandBaseline(_ band: Int, inset: CGFloat = 0) -> CGFloat {
            height - CGFloat(band) * cell - cell + inset
        }
        let mid: CGFloat = 28          // optical baseline inside an 80 px band, measured from its floor

        switch config.kind {
        case .none:
            break

        case .clock:
            let t = DateFormatter(); t.dateFormat = "HH:mm"
            let time = t.string(from: now)
            // shrink until it fits the 80 px band with margins
            var timeSize: CGFloat = 28
            while timeSize > 14, measure(time, timeSize, .bold) > width - 18 { timeSize -= 1 }
            let tw = measure(time, timeSize, .bold)
            _ = line(time, timeSize, .bold, x: (width - tw) / 2, baseline: bandBaseline(0) + mid + 6)

            let sec = DateFormatter(); sec.dateFormat = "ss"
            let s = sec.string(from: now) + "s"
            let sw = measure(s, 15, .medium)
            _ = line(s, 15, .medium, x: (width - sw) / 2, baseline: bandBaseline(1) + mid, color: grey)

            let d = DateFormatter(); d.dateFormat = "EEE d"
            let dateText = d.string(from: now).uppercased()
            let dw = measure(dateText, 11, .medium, mono: false)
            _ = line(dateText, 11, .medium, x: (width - dw) / 2, baseline: bandBaseline(2) + mid,
                     color: grey, mono: false)

        case .date:
            let weekday = DateFormatter(); weekday.dateFormat = "EEE"
            let day = DateFormatter(); day.dateFormat = "d"
            let month = DateFormatter(); month.dateFormat = "MMM"
            let w1 = measure(weekday.string(from: now).uppercased(), 14, .semibold, mono: false)
            _ = line(weekday.string(from: now).uppercased(), 14, .semibold,
                     x: (width - w1) / 2, baseline: bandBaseline(0) + mid, color: grey, mono: false)
            let w2 = measure(day.string(from: now), 32, .bold)
            _ = line(day.string(from: now), 32, .bold,
                     x: (width - w2) / 2, baseline: bandBaseline(1) + mid + 2)
            let w3 = measure(month.string(from: now).uppercased(), 14, .semibold, mono: false)
            _ = line(month.string(from: now).uppercased(), 14, .semibold,
                     x: (width - w3) / 2, baseline: bandBaseline(2) + mid, color: grey, mono: false)

        case .cpu, .memory:
            let pct = config.kind == .cpu ? SysInfo.cpuPercent() : SysInfo.memoryUsedPercent()
            let label = config.kind == .cpu ? "CPU" : "MEM"
            let lw = measure(label, 11, .medium, mono: false)
            _ = line(label, 11, .medium, x: (width - lw) / 2, baseline: bandBaseline(0) + mid,
                     color: grey, mono: false)

            let value = String(format: "%.0f%%", pct)
            var valueSize: CGFloat = 30
            while valueSize > 16, measure(value, valueSize, .bold) > width - 18 { valueSize -= 1 }
            let vw = measure(value, valueSize, .bold)
            _ = line(value, valueSize, .bold, x: (width - vw) / 2, baseline: bandBaseline(1) + mid + 2)

            // level bar in the bottom band
            let bar = CGRect(x: 12, y: bandBaseline(2) + mid, width: width - 24, height: 10)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.2))
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            var filled = bar
            filled.size.width = bar.width * CGFloat(max(0, min(1, pct / 100)))
            ctx.setFillColor(CGColor(red: 0.35, green: 0.72, blue: 0.95, alpha: 1))
            ctx.addPath(CGPath(roundedRect: filled, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()

        case .page:
            let label = "PAGE"
            let lw = measure(label, 10, .medium, mono: false)
            _ = line(label, 10, .medium, x: (width - lw) / 2, baseline: bandBaseline(0) + mid,
                     color: grey, mono: false)
            let value = "\(page.index)"
            let vw = measure(value, 34, .bold)
            _ = line(value, 34, .bold, x: (width - vw) / 2, baseline: bandBaseline(1) + mid + 2)
            let total = "/ \(page.count)"
            let tw2 = measure(total, 14, .semibold)
            _ = line(total, 14, .semibold, x: (width - tw2) / 2, baseline: bandBaseline(2) + mid,
                     color: grey)

        case .text:
            let body = config.text.isEmpty ? "—" : config.text
            var size: CGFloat = 24
            while size > 9, measure(body, size, .semibold, mono: false) > width - 16 { size -= 1 }
            let w = measure(body, size, .semibold, mono: false)
            _ = line(body, size, .semibold, x: (width - w) / 2,
                     baseline: bandBaseline(1) + mid + 2, mono: false)
        }
    }

    static func jpeg(for config: WidgetConfig, page: (index: Int, count: Int),
                     now: Date = Date()) -> Data? {
        guard config.kind != .none else { return nil }
        guard let cg = image(for: config, page: page, now: now) else { return nil }
        return ImagePrep.prepare(cg, side: side)      // includes the firmware's single rotation
    }

    static func image(for config: WidgetConfig, page: (index: Int, count: Int),
                      now: Date = Date()) -> CGImage? {
        let side = CGFloat(self.side)
        guard let ctx = CGContext(data: nil, width: self.side, height: self.side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        // tile background + hairline frame, same language as the key tiles
        let tile = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1))
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()

        func draw(_ text: String, size fontSize: CGFloat, weight: NSFont.Weight = .semibold,
                  y baseline: CGFloat, color: NSColor = .white, mono: Bool = true) {
            let font = mono
                ? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
                : NSFont.systemFont(ofSize: fontSize, weight: weight)
            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: (side - CGFloat(width)) / 2, y: baseline)
            CTLineDraw(line, ctx)
        }

        switch config.kind {
        case .none:
            break

        case .clock:
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            draw(f.string(from: now), size: 24, weight: .bold, y: config.showsSeconds ? 36 : 28)
            if config.showsSeconds {
                f.dateFormat = "ss"
                draw(f.string(from: now) + "s", size: 12, weight: .medium, y: 20,
                     color: NSColor(white: 0.8, alpha: 1))
            }

        case .date:
            let weekday = DateFormatter(); weekday.dateFormat = "EEE"
            let day = DateFormatter(); day.dateFormat = "d"
            let month = DateFormatter(); month.dateFormat = "MMM"
            draw(weekday.string(from: now).uppercased(), size: 8, weight: .regular, y: 60,
                 color: NSColor(white: 0.8, alpha: 1), mono: false)
            draw(day.string(from: now), size: 24, weight: .bold, y: 30)
            draw(month.string(from: now).uppercased(), size: 9, weight: .medium, y: 16,
                 color: NSColor(white: 0.7, alpha: 1), mono: false)

        case .cpu:
            let pct = SysInfo.cpuPercent()
            draw("CPU", size: 9, weight: .medium, y: 62, color: NSColor(white: 0.82, alpha: 1), mono: false)
            draw(String(format: "%.0f%%", pct), size: 21, weight: .bold, y: 32)
            bar(ctx, min(1, pct / 100), y: 20)

        case .memory:
            let pct = SysInfo.memoryUsedPercent()
            draw("MEM", size: 9, weight: .medium, y: 62, color: NSColor(white: 0.82, alpha: 1), mono: false)
            draw(String(format: "%.0f%%", pct), size: 21, weight: .bold, y: 32)
            bar(ctx, min(1, pct / 100), y: 20)

        case .page:
            draw("PAGE", size: 9, weight: .medium, y: 62, color: NSColor(white: 0.82, alpha: 1), mono: false)
            draw("\(page.index)/\(page.count)", size: 21, weight: .bold, y: 30)

        case .text:
            let body = config.text.isEmpty ? "—" : config.text
            let fontSize: CGFloat = body.count > 6 ? 11 : (body.count > 3 ? 16 : 22)
            draw(body, size: fontSize, weight: .semibold, y: 32, mono: false)
        }

        ctx.setStrokeColor(CGColor(red: 0.24, green: 0.60, blue: 0.82, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.strokePath()

        return ctx.makeImage()
    }

    private static func bar(_ ctx: CGContext, _ fraction: Double, y: CGFloat) {
        let width = CGFloat(side) - 24
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.12))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 12, y: y, width: width, height: 4),
                           cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.fillPath()

        ctx.setFillColor(CGColor(red: 0.35, green: 0.72, blue: 0.95, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 12, y: y,
                                              width: width * CGFloat(max(0, min(1, fraction))),
                                              height: 4),
                           cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.fillPath()
    }
}
