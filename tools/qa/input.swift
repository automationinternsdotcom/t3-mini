import CoreGraphics
import Foundation
let a = CommandLine.arguments
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(20000) }
switch a[1] {
case "hotkey": // ctrl+opt+P with real modifier press/release
  let src = CGEventSource(stateID: .hidSystemState)
  func key(_ k: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, _ type: CGEventType? = nil) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down); e?.flags = flags
    if let type { e?.type = type }
    post(e)
  }
  key(59, true, [.maskControl], .flagsChanged)
  key(58, true, [.maskControl, .maskAlternate], .flagsChanged)
  key(35, true, [.maskControl, .maskAlternate]); key(35, false, [.maskControl, .maskAlternate])
  key(58, false, [.maskControl], .flagsChanged)
  key(59, false, [], .flagsChanged)
case "drag": // drag x1 y1 x2 y2
  let p1 = CGPoint(x: Double(a[2])!, y: Double(a[3])!), p2 = CGPoint(x: Double(a[4])!, y: Double(a[5])!)
  post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p1, mouseButton: .left))
  usleep(150000)
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p1, mouseButton: .left))
  for i in 1...20 { let t = Double(i)/20; post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: p1.x + (p2.x-p1.x)*t, y: p1.y + (p2.y-p1.y)*t), mouseButton: .left)) }
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p2, mouseButton: .left))
case "dragopt": // like drag, but hold Option at release
  let p1 = CGPoint(x: Double(a[2])!, y: Double(a[3])!), p2 = CGPoint(x: Double(a[4])!, y: Double(a[5])!)
  let src = CGEventSource(stateID: .hidSystemState)
  post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p1, mouseButton: .left)); usleep(150000)
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p1, mouseButton: .left))
  for i in 1...20 { let t = Double(i)/20; post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: p1.x + (p2.x-p1.x)*t, y: p1.y + (p2.y-p1.y)*t), mouseButton: .left)) }
  let od = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: true); od?.type = .flagsChanged; od?.flags = [.maskAlternate]; post(od); usleep(80000)
  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p2, mouseButton: .left); up?.flags = [.maskAlternate]; post(up); usleep(80000)
  let ou = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: false); ou?.type = .flagsChanged; ou?.flags = []; post(ou)
case "scroll": // scroll x y dy (pixels; negative = content moves up / wheel down)
  let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!), dy = Int32(a[4])!
  post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)); usleep(120000)
  for _ in 0..<6 { let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy / 6, wheel2: 0, wheel3: 0); e?.location = p; post(e) }
case "click":
  let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
  post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)); usleep(150000)
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
case "move":
  post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: Double(a[2])!, y: Double(a[3])!), mouseButton: .left))
case "type":
  let src = CGEventSource(stateID: .hidSystemState)
  for ch in a[2].utf16 {
    var c = ch
    let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true); d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(d)
    let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false); u?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(u)
  }
case "fullscreen": // ctrl+cmd+F
  let src = CGEventSource(stateID: .hidSystemState)
  func key(_ k: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, _ type: CGEventType? = nil) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down); e?.flags = flags
    if let type { e?.type = type }
    post(e)
  }
  key(59, true, [.maskControl], .flagsChanged); key(55, true, [.maskControl, .maskCommand], .flagsChanged)
  key(3, true, [.maskControl, .maskCommand]); key(3, false, [.maskControl, .maskCommand])
  key(55, false, [.maskControl], .flagsChanged); key(59, false, [], .flagsChanged)
case "key": // key <code> [count]
  let src = CGEventSource(stateID: .hidSystemState)
  let n = a.count > 3 ? Int(a[3])! : 1
  for _ in 0..<n { post(CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(a[2])!, keyDown: true)); post(CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(a[2])!, keyDown: false)) }
case "rclick":
  let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
  post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .right)); usleep(150000)
  post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: .right))
  post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: .right))
case "return":
  let src = CGEventSource(stateID: .hidSystemState)
  post(CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)); post(CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false))
default: break
}
