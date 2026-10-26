// axclick.swift — click the first element whose accessibility text equals the argument.
// Usage: ./axclick "Send to Device" [clickCount]
import Cocoa
import ApplicationServices

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let clicks = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 1) : 1
let appName = "Stream Dock"

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
    print("app not running"); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

var hit: AXUIElement?
func walk(_ el: AXUIElement, depth: Int) {
    if depth > 16 || hit != nil { return }
    for key in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
        if let s = attr(el, key) as? String, s == target {
            hit = el
            return
        }
    }
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { walk(k, depth: depth + 1) }
    }
}
walk(ax, depth: 0)

guard let el = hit else { print("'\(target)' not found"); exit(2) }
var posRef: CFTypeRef?, sizeRef: CFTypeRef?
AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef)
AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef)
var pos = CGPoint.zero, size = CGSize.zero
if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
let point = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
print("clicking '\(target)' at \(Int(point.x)),\(Int(point.y)) size \(Int(size.width))x\(Int(size.height))")

let source = CGEventSource(stateID: .hidSystemState)
for click in 1...clicks {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else { continue }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        e.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}
print("done")
