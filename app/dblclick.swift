// dblclick.swift — find a sidebar row by its text via the accessibility tree and double-click it.
// Used to verify that double-clicking a profile loads it onto the device.
import Cocoa
import ApplicationServices

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test 2"
let appName = "Stream Dock"

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
    print("app not running"); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

var hit: AXUIElement?
func walk(_ el: AXUIElement, depth: Int) {
    if depth > 14 || hit != nil { return }
    if let role = attr(el, kAXRoleAttribute) as? String, role == kAXStaticTextRole as String,
       let value = attr(el, kAXValueAttribute) as? String, value == target {
        hit = el
        return
    }
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { walk(k, depth: depth + 1) }
    }
}
walk(ax, depth: 0)

guard let row = hit else { print("row '\(target)' not found"); exit(2) }
var posRef: CFTypeRef?, sizeRef: CFTypeRef?
AXUIElementCopyAttributeValue(row, kAXPositionAttribute as CFString, &posRef)
AXUIElementCopyAttributeValue(row, kAXSizeAttribute as CFString, &sizeRef)
var pos = CGPoint.zero, size = CGSize.zero
if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }

let point = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
print("double-clicking '\(target)' at \(Int(point.x)),\(Int(point.y))")

let source = CGEventSource(stateID: .hidSystemState)
for click in 1...2 {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: point, mouseButton: .left) else { continue }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        e.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
print("done")
