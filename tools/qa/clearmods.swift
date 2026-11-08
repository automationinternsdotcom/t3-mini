import CoreGraphics
import Foundation
let src = CGEventSource(stateID: .hidSystemState)
for key: CGKeyCode in [59, 58] { // ctrl, option key-up
  let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false); e?.flags = []; e?.type = .flagsChanged; e?.post(tap: .cghidEventTap); usleep(20000)
}
let f = CGEvent(source: src); f?.type = .flagsChanged; f?.flags = []; f?.post(tap: .cghidEventTap)
usleep(50000)
print("flags now:", CGEventSource.flagsState(.combinedSessionState).rawValue)
