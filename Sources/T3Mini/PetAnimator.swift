import AppKit
import Combine
import T3MiniCore

/// Slices a pet sprite atlas into frames.
final class SpriteSheet {
    let package: PetPackage
    private(set) var rows: [PetAnimation: [CGImage]] = [:]
    private(set) var look: [CGImage] = []  // 16 directions, index 0 = up, clockwise

    init?(package: PetPackage) {
        guard let src = CGImageSourceCreateWithURL(package.sheetURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.package = package
        let cw = Int(PetPackage.cellSize.width), ch = Int(PetPackage.cellSize.height)
        func cell(_ r: Int, _ c: Int) -> CGImage? { image.cropping(to: CGRect(x: c * cw, y: r * ch, width: cw, height: ch)) }
        for anim in PetAnimation.allCases {
            rows[anim] = (0..<anim.frameDurationsMs.count).compactMap { cell(anim.rawValue, $0) }
        }
        if package.version >= 2 {
            look = (0..<16).compactMap { cell(9 + $0 / 8, $0 % 8) }
        }
    }
}

/// Drives which sprite frame is on screen:
///  - a status animation plays 3 times, then the pet falls back to a slow idle loop (6x slower);
///  - pointer over the sprite holds `jumping`; dragging holds `running-left/right`;
///  - when idle, v2 pets look toward the cursor (16 directions);
///  - reduced motion shows only the first frame.
final class PetAnimator: ObservableObject {
    @Published private(set) var frame: CGImage?
    var sheet: SpriteSheet? { didSet { restart() } }

    /// The animation for the current attention state.
    private(set) var base: PetAnimation = .idle
    var dragDirection: PetAnimation? { didSet { if dragDirection != oldValue { restart() } } }
    var hoveringSprite = false { didSet { if hoveringSprite != oldValue { restart() } } }
    /// Screen-space centre of the pet, used for look-at-cursor.
    var petCenter: CGPoint = .zero

    private var oneShot: PetAnimation?
    private var baseLoopsLeft = 0
    private var current: PetAnimation = .idle
    private var index = 0
    private var frameStarted = Date()
    private var timer: Timer?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let statusLoops = 3
    static let idleSlowdown = 6.0

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// New attention state: play its clip three times (again, if `replay`).
    func setBase(_ anim: PetAnimation, replay: Bool = false) {
        guard anim != base || replay else { return }
        base = anim
        baseLoopsLeft = anim == .idle ? 0 : Self.statusLoops
        restart()
    }

    /// One pass of a clip (e.g. waving for the first-awake greeting).
    func play(_ anim: PetAnimation) {
        oneShot = anim
        restart()
    }

    var effective: PetAnimation {
        if let d = dragDirection { return d }
        if hoveringSprite { return .jumping }
        if let o = oneShot { return o }
        return baseLoopsLeft > 0 ? base : .idle
    }

    private func restart() {
        current = effective
        index = 0
        frameStarted = Date()
        render()
    }

    private func durations(_ a: PetAnimation) -> [Int] {
        a == .idle ? a.frameDurationsMs.map { Int(Double($0) * Self.idleSlowdown) } : a.frameDurationsMs
    }

    private func render() {
        guard let sheet else { frame = nil; return }
        if reduceMotion {
            frame = sheet.rows[current]?.first ?? sheet.rows[.idle]?.first
            return
        }
        if current == .idle, let lookFrame = lookFrame(sheet) {  // idle only: keep status clips visible
            frame = lookFrame
            return
        }
        let frames = sheet.rows[current] ?? []
        frame = frames.isEmpty ? sheet.rows[.idle]?.first : frames[min(index, frames.count - 1)]
    }

    /// Look toward the cursor anywhere on screen (no change when it sits on the sprite centre).
    private func lookFrame(_ sheet: SpriteSheet) -> CGImage? {
        guard sheet.look.count == 16 else { return nil }
        let m = NSEvent.mouseLocation
        let dx = m.x - petCenter.x, dy = m.y - petCenter.y
        guard hypot(dx, dy) > 1 else { return nil }
        var deg = atan2(dx, dy) * 180 / .pi  // 0 = up, clockwise (screen y grows upward)
        if deg < 0 { deg += 360 }
        return sheet.look[Int((deg / 22.5).rounded()) % 16]
    }

    private func tick() {
        guard sheet != nil, !reduceMotion else { return }
        let d = durations(current)
        let elapsed = Date().timeIntervalSince(frameStarted) * 1000
        if elapsed >= Double(d[min(index, d.count - 1)]) {
            index += 1
            frameStarted = Date()
            if index >= d.count {
                index = 0
                if current == oneShot {
                    oneShot = nil
                } else if current == base, baseLoopsLeft > 0, dragDirection == nil, !hoveringSprite {
                    baseLoopsLeft -= 1
                }
                if effective != current { restart(); return }
            }
        }
        render()
    }
}
