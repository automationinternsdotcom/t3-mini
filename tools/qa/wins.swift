import CoreGraphics
import Foundation
let opts: CGWindowListOption = CommandLine.arguments.contains("all") ? [.optionAll] : [.optionOnScreenOnly]
let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").contains(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "T3Mini") {
  print(w[kCGWindowOwnerName as String] ?? "", "layer", w[kCGWindowLayer as String] ?? "", "onscreen", w[kCGWindowIsOnscreen as String] ?? "-", "bounds", w[kCGWindowBounds as String] ?? "", "alpha", w[kCGWindowAlpha as String] ?? "")
}
