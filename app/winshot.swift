// winshot.swift — find a window by owner name and capture just it.
// usage: swiftc winshot.swift -o winshot; ./winshot "Stream Dock" out.png
import Foundation
import CoreGraphics
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: winshot <owner-substring> <out.png>"); exit(1) }
let needle = args[1].lowercased()
let outPath = args[2]

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}

for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let title = (w[kCGWindowName as String] as? String) ?? ""
    guard owner.lowercased().contains(needle) || title.lowercased().contains(needle) else { continue }
    guard let num = w[kCGWindowNumber as String] as? Int,
          let bounds = w[kCGWindowBounds as String] as? [String: Any],
          let h = bounds["Height"] as? Double, h > 200 else { continue }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(num)", outPath]
    try? p.run(); p.waitUntilExit()
    print("captured \(owner) / \(title) window \(num) -> \(outPath)")
    exit(0)
}
print("window not found for '\(needle)'")
exit(2)
