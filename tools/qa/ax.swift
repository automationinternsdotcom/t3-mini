// ax: read-only Accessibility dump of an app's windows, for debugging layout and focus.
//   ax <pid> [maxDepth] [--manual on|off|get] [--window-min-layer]
// Prints one line per element: depth, role/subrole, title/description/value, frame (global top-left), actions.
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count > 1, let pid = pid_t(args[1]) else { print("usage: ax <pid> [maxDepth] [--manual on|off|get]"); exit(1) }
let maxDepth = args.count > 2 ? Int(args[2]) ?? 12 : 12
let app = AXUIElementCreateApplication(pid)

if let i = args.firstIndex(of: "--manual"), i + 1 < args.count {
    let mode = args[i + 1]
    var cur: CFTypeRef?
    let rc = AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &cur)
    print("AXManualAccessibility before:", rc == .success ? "\(cur!)" : "unset(\(rc.rawValue))")
    if mode == "on" || mode == "off" {
        let r = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, (mode == "on" ? kCFBooleanTrue : kCFBooleanFalse)!)
        print("set \(mode):", r.rawValue)
    }
    if args.count <= 4 && !args.contains("--dump") { exit(0) }
}

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String? {
    guard let v = attr(e, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func actions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(e, &names) == .success, let a = names as? [String] else { return [] }
    return a.filter { !$0.hasPrefix("AXScroll") && $0 != "AXShowMenu" }
}

var count = 0
func dump(_ e: AXUIElement, _ depth: Int) {
    count += 1
    if count > 4000 { return }
    let role = str(e, kAXRoleAttribute) ?? "?"
    let sub = str(e, kAXSubroleAttribute).map { "/\($0)" } ?? ""
    var bits: [String] = []
    for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, "AXDOMIdentifier", "AXDOMClassList"] {
        if k == "AXDOMClassList" { continue }
        if let s = str(e, k) { bits.append("\(k.replacingOccurrences(of: "AX", with: ""))=\"\(s.prefix(90).replacingOccurrences(of: "\n", with: " "))\"") }
    }
    let f = frame(e).map { "[\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))]" } ?? ""
    let acts = actions(e)
    print(String(repeating: "  ", count: depth) + "\(role)\(sub) \(bits.joined(separator: " ")) \(f)" + (acts.isEmpty ? "" : " {\(acts.joined(separator: ","))}"))
    guard depth < maxDepth, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for k in kids { dump(k, depth + 1) }
}

if args.contains("--focused-value") {
    guard let f = attr(app, kAXFocusedUIElementAttribute) else { print(""); exit(0) }
    print(str(f as! AXUIElement, kAXValueAttribute) ?? "")
    exit(0)
}

guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { print("no windows (AX)"); exit(0) }

// --press "<exact title>": AXPress the first element whose title matches, then exit.
if let i = args.firstIndex(of: "--press"), i + 1 < args.count {
    let target = args[i + 1]
    func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
        if str(e, kAXTitleAttribute) == target || str(e, kAXDescriptionAttribute) == target { return e }
        guard d < 80, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for k in kids { if let f = find(k, d + 1) { return f } }
        return nil
    }
    for w in windows { if let el = find(w, 0) { print("press \(target):", AXUIElementPerformAction(el, kAXPressAction as CFString).rawValue); exit(0) } }
    print("not found: \(target)"); exit(1)
}
for (i, w) in windows.enumerated() {
    print("=== window \(i): \(str(w, kAXTitleAttribute) ?? "") \(frame(w).map { "\($0)" } ?? "")")
    dump(w, 0)
}
