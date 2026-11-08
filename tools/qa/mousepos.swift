import CoreGraphics
import Foundation
for _ in 0..<8 { let p = CGEvent(source: nil)!.location; print(Int(p.x), Int(p.y)); usleep(500000) }
