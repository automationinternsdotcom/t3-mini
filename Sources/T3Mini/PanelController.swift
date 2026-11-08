import AppKit
import SwiftUI
import T3MiniCore

/// Borderless, transparent, non-activating panel that floats above every app on every Space.
final class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }
    // Key (for typing) without activating the app, so the user's current app keeps focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // The panel may hang off-screen; only the pet is kept on-screen (see PanelController.layoutPanel).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Right-click menu. Handled in AppKit because SwiftUI's .contextMenu swallows
    /// left clicks on views that also have tap/drag gestures.
    var rightClickMenu: ((NSPoint) -> NSMenu?)?
    /// Scroll-wheel hook (the collapsed stack expands on scroll). Return true if handled.
    var scrollHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if UserDefaults.standard.bool(forKey: "traceEvents") {
            T3Actions.trace("event type=\(event.type.rawValue) at=\(NSStringFromPoint(event.locationInWindow)) ignores=\(ignoresMouseEvents)")
        }
        if event.type == .scrollWheel, scrollHandler?(event) == true { return }
        if event.type == .rightMouseDown, let menu = rightClickMenu?(event.locationInWindow), let view = contentView {
            let wasKey = isKeyWindow, wasActive = NSApp.isActive
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            // The menu's tracking loop leaves the panel key and SwiftUI's hover tracking stale:
            // hand focus back and rebuild tracking areas so card hover keeps working.
            // popUpContextMenu activates the (accessory) app and leaves the panel key: hand both back unless the
            // user was typing in the panel (then keep the field focused).
            if !wasKey { resignKey() }
            if !wasActive { NSApp.deactivate() }  // the user's app keeps activation (a key panel still types)
            if wasKey { makeKey(); DispatchQueue.main.async { [weak self] in self?.makeKey() } }  // after deactivate settles
            view.updateTrackingAreas()
            view.subviews.forEach { $0.updateTrackingAreas() }
            if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: mouseLocationOutsideOfEventStream,
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                super.sendEvent(moved)
            }
            return
        }
        super.sendEvent(event)
    }
}

/// Hosting view that never resizes the panel and takes the first click even while T3 Mini is inactive.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PanelController {
    /// Transparent canvas around the pet; big enough for the 330 pt bar + bell + largest pet, and the tray.
    static let panelSize = NSSize(width: 660, height: 720)
    static let pad: CGFloat = 10
    /// Snap inset from the work-area edges.
    static let edgeMargin: CGFloat = 16
    /// Proximity reveal (tuned by hand): enter within 40 pt, leave beyond 56 pt, dismiss 300 ms later.
    static let proximityEnter: CGFloat = 40
    static let proximityExit: CGFloat = 56
    static let dismissDelay: TimeInterval = 0.3

    let panel = OverlayPanel(size: PanelController.panelSize)
    let model: MiniModel
    let settings = Settings.shared
    let ui = OverlayState()
    let animator = PetAnimator()
    var pets: [PetPackage] = []
    var onChange: (() -> Void)?
    /// Main menu (status-bar menu contents), used for right-click on the pet or bar.
    var mainMenu: (() -> NSMenu)?

    /// Where the pet (or the Mini bar) sits on screen. Everything else is laid out around it.
    private(set) var petFrame: NSRect = .zero
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var lastDragX: CGFloat = 0
    private var lastDirection: PetAnimation = .runningRight
    private var mouseTimer: Timer?
    private var leftProximityAt: Date?

    /// Clickable regions reported by the SwiftUI overlay (top-left origin, panel points).
    var interactiveRects: [CGRect] = [] { didSet { updateMouse() } }
    /// Named control frames, same coordinates (see `tagged(_:)`).
    var taggedRects: [String: CGRect] = [:]

    init(model: MiniModel) {
        self.model = model
        let root = OverlayView(model: model, settings: settings, animator: animator, ui: ui, controller: self)
        let host = OverlayHostingView(rootView: root)
        if #available(macOS 13.0, *) { host.sizingOptions = [] }  // don't let SwiftUI grow the window
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setContentSize(Self.panelSize)
        panel.contentMinSize = Self.panelSize
        panel.contentMaxSize = Self.panelSize
        ui.makeKey = { [weak self] in self?.panel.makeKey() }
        ui.resignKey = { [weak self] in self?.panel.resignKey() }
        panel.rightClickMenu = { [weak self] p in self?.menu(at: p) }
        panel.scrollHandler = { [weak self] e in self?.handleScroll(e) ?? false }
        placeInitially()
        // The panel is mostly transparent: only accept the mouse over the pet and cards,
        // so the windows underneath stay clickable everywhere else.
        panel.ignoresMouseEvents = true
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.032, repeats: true) { [weak self] _ in self?.updateMouse() }
        RunLoop.main.add(mouseTimer!, forMode: .common)
        // Re-clamp after display / resolution changes and wake.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layoutPanel() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.layoutPanel() }
    }

    // MARK: geometry helpers

    /// Panel-local (top-left origin) rect → screen (AppKit, bottom-left origin).
    func screenRect(_ r: CGRect) -> CGRect {
        let f = panel.frame
        return CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    private static func distance(_ p: NSPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Room for the tray: what's left between the bar and the screen edge (and within the canvas).
    var trayMaxHeight: CGFloat {
        let canvas = Self.panelSize.height - anchorSize.height - 3 * Self.pad - 70
        guard let v = screen(for: petFrame)?.visibleFrame else { return canvas }
        // Subtract what actually sits between the pet and the tray: bar (composer grows to ~5 lines),
        // greeting card, toast.
        let bar: CGFloat = ui.chatOpen ? 112 : 40
        let extras: CGFloat = (ui.greeting != nil ? 72 : 0) + (ui.toast != nil ? 58 : 0)
        let room = (ui.anchorTop ? petFrame.minY - v.minY : v.maxY - petFrame.maxY) - 4 - bar - 12 - extras - Self.edgeMargin
        // Never more than the real space (the list scrolls / the stack clips inside it).
        return max(0, min(canvas - extras - (bar - 40), room))
    }

    // MARK: mouse: click-through, proximity reveal, sprite hover

    private func updateMouse() {
        guard panel.isVisible else { return }
        let m = NSEvent.mouseLocation
        let dragging = dragStartMouse != nil

        // Hover on the sprite itself holds the jumping animation.
        let sprite = taggedRects["pet"].map(screenRect) ?? .zero
        animator.hoveringSprite = !dragging && settings.mode == .pet
            && sprite.insetBy(dx: sprite.width * 0.2, dy: sprite.height * 0.15).contains(m)

        // Proximity (Pet mode): distance to the sprite or any revealed control, with hysteresis.
        if settings.mode == .pet && !dragging {
            let targets = [petFrame] + (ui.revealed ? interactiveRects.map(screenRect) : [])
            let d = targets.map { Self.distance(m, $0) }.min() ?? .infinity
            if d <= Self.proximityEnter || (ui.revealed && d <= Self.proximityExit) {
                leftProximityAt = nil
                if !ui.revealed { ui.revealed = true }
            } else if ui.revealed {
                if leftProximityAt == nil { leftProximityAt = Date() }
                if Date().timeIntervalSince(leftProximityAt!) >= Self.dismissDelay, !keepsBarOpen {
                    ui.revealed = false
                    if ui.chatOpen && ui.draft.isEmpty { ui.chatOpen = false }
                    leftProximityAt = nil
                }
            }
        }

        // Card hover from geometry (robust where SwiftUI's tracking areas go stale).
        // Most-visible card under the pointer wins (a card scrolled out of view can't steal hover).
        let hovered = ui.expanded ? taggedRects.filter { $0.key.hasPrefix("card:") }
            .map { ($0.key, visible($0.value)) }
            .filter { !$0.1.isEmpty && screenRect($0.1).insetBy(dx: -4, dy: -4).contains(m) }
            .max { $0.1.height < $1.1.height }
            .map { String($0.0.dropFirst("card:".count)) } : nil
        if ui.hoveredCard != hovered { ui.hoveredCard = hovered }

        let inside = dragging || interactiveRects.contains { screenRect($0).insetBy(dx: -3, dy: -3).contains(m) }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    /// The bar stays open while typing, with a draft, or while the tray is open.
    var keepsBarOpen: Bool {
        ui.expanded || ui.replyingTo != nil || !ui.draft.isEmpty || ui.busy || (ui.chatOpen && panel.isKeyWindow)
            || ui.greeting != nil
    }

    /// A card's frame clipped to the visible list (cards scrolled out of view have no visible area).
    private func visible(_ card: CGRect) -> CGRect {
        guard let clip = ui.listExpanded || taggedRects["stack"] == nil ? taggedRects["list"] : taggedRects["stack"] else { return card }
        let r = card.intersection(clip)
        return r.isNull ? .zero : r
    }

    // MARK: scroll to expand the stack

    private var scrollAccum: CGFloat = 0
    private var scrollStart = Date.distantPast

    /// Wheel travel of ≥32 pt within a 180 ms gesture *toward the stack* expands it; travel the
    /// other way while the list is scrolled to its end nearest the bar collapses it back to the stack.
    /// "Toward the stack" = away from the bar: down when the tray is below the pet, up when it is above.
    private func handleScroll(_ e: NSEvent) -> Bool {
        guard ui.expanded, model.visible.count > 1 else { return false }
        let p = CGPoint(x: e.locationInWindow.x, y: Self.panelSize.height - e.locationInWindow.y)
        // scrollingDeltaY < 0 means the content moves up (scrolling "down").
        let dy = -e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 40)  // one wheel notch ≈ 40 pt
        let towardStack = ui.anchorTop ? dy : -dy
        if Date().timeIntervalSince(scrollStart) > 0.18 { scrollAccum = 0; scrollStart = Date() }
        if !ui.listExpanded {
            guard let stack = taggedRects["stack"], stack.contains(p) else { return false }
            scrollAccum += towardStack
            if scrollAccum >= 32 { ui.listExpanded = true; scrollAccum = 0 }
            return true
        }
        guard let list = taggedRects["list"], list.contains(p), towardStack < 0, listAtBarEnd(e) else { return false }
        scrollAccum += -towardStack
        if scrollAccum >= 32 { ui.listExpanded = false; scrollAccum = 0 }
        return true
    }

    /// Is the list's scroll view at the end closest to the bar (top when the tray is below the pet)?
    private func listAtBarEnd(_ e: NSEvent) -> Bool {
        guard let hit = panel.contentView?.hitTest(e.locationInWindow), let sv = hit.enclosingScrollView ?? (hit as? NSScrollView),
              let doc = sv.documentView else { return true }  // not scrollable → treat as at the end
        let y = sv.contentView.bounds.origin.y
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        let atTop = doc.isFlipped ? y <= 1 : y >= maxY - 1
        let atBottom = doc.isFlipped ? y >= maxY - 1 : y <= 1
        return ui.anchorTop ? atTop : atBottom
    }

    // MARK: right-click

    private func menu(at windowPoint: NSPoint) -> NSMenu? {
        // window coords (bottom-left) → overlay coords (top-left)
        let p = CGPoint(x: windowPoint.x, y: Self.panelSize.height - windowPoint.y)
        if let hit = taggedRects.first(where: { $0.key.hasPrefix("card:") && visible($0.value).contains(p) }) {
            let id = String(hit.key.dropFirst("card:".count))
            if let a = model.visible.first(where: { $0.threadId == id }) { return cardMenu(a) }
        }
        return mainMenu?()
    }

    private func cardMenu(_ a: ThreadActivity) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ run: @escaping () -> Void) {
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
            item.target = action
            item.representedObject = action  // keep the target alive with the item
            m.addItem(item)
        }
        add(a.state == .needsInput ? "Review in T3" : "Open in T3") { T3Actions.openThread(a.threadId) }
        add("Reply") { [weak self] in self?.ui.listExpanded = true; self?.ui.replyingTo = a.threadId }
        add(ui.peeking == a.threadId ? "Hide transcript" : "Peek transcript") { [weak self] in
            guard let self else { return }
            if self.ui.peeking == a.threadId { self.ui.peeking = nil; return }
            self.ui.peeking = a.threadId
            self.ui.peekMessages = []
            self.model.messages(for: a.threadId) { msgs in if self.ui.peeking == a.threadId { self.ui.peekMessages = msgs } }
        }
        m.addItem(.separator())
        add("Mute chat") { [weak self] in self?.model.toggleMute(a) }  // unmute: "Muted chats" menu
        add("Dismiss") { [weak self] in self?.model.dismiss(a) }
        return m
    }

    // MARK: visibility

    var isVisible: Bool { panel.isVisible }

    func show(focusChat: Bool = false) {
        layoutPanel()
        panel.orderFrontRegardless()
        settings.shown = true
        if focusChat { ui.revealed = true; ui.openComposer() }
        onChange?()
    }

    func hide() {
        panel.orderOut(nil)
        settings.shown = false
        ui.closeTray()
        ui.revealed = false
        if ui.draft.isEmpty { ui.chatOpen = false }
        onChange?()
    }

    func toggle() { isVisible ? hide() : show() }
    func makeKey() { panel.makeKey() }
    func resignKey() { panel.resignKey() }

    // MARK: pets

    func applyPet() {
        animator.sheet = currentPet.flatMap(SpriteSheet.init(package:))
    }

    var currentPet: PetPackage? { pets.first { $0.id == settings.petId } ?? pets.first }
    var currentPetName: String { currentPet?.manifest.displayName ?? "your pet" }

    // MARK: placement & dragging

    /// Size of the anchor element: the pet sprite, or the compact bar in Mini mode.
    var anchorSize: NSSize {
        settings.mode == .pet
            ? NSSize(width: 192 * settings.size.scale, height: 208 * settings.size.scale)
            : NSSize(width: 80, height: 40)  // bar-only pill
    }

    private func placeInitially() {
        let size = anchorSize
        if let o = settings.petOrigin {
            petFrame = NSRect(origin: o, size: size)
        } else if let v = NSScreen.main?.visibleFrame {
            // First run: bottom-right, 24 pt in from the edges.
            petFrame = NSRect(x: v.maxX - size.width - 24, y: v.minY + 24, width: size.width, height: size.height)
        }
        layoutPanel()
    }

    private func screen(for r: NSRect) -> NSScreen? {
        let c = NSPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.first { $0.frame.contains(c) }
            ?? NSScreen.screens.min { Self.distance(c, $0.frame) < Self.distance(c, $1.frame) }
            ?? NSScreen.main
    }

    /// Keep the pet fully on-screen (anywhere, including the top and left edges), then place the
    /// panel so the bar and tray open toward the middle of the screen (flipping above/below as needed).
    func layoutPanel(clamp: Bool = true) {
        let size = anchorSize
        if petFrame.size != size {  // size or mode changed: keep the pet's centre
            petFrame = NSRect(x: petFrame.midX - size.width / 2, y: petFrame.midY - size.height / 2,
                              width: size.width, height: size.height)
        }
        if clamp, let v = screen(for: petFrame)?.visibleFrame {
            petFrame.origin.x = min(max(petFrame.minX, v.minX), v.maxX - petFrame.width)
            petFrame.origin.y = min(max(petFrame.minY, v.minY), v.maxY - petFrame.height)
            // Open toward the side of the pet with more room; the tray is clipped to the real space.
            let top = (petFrame.minY - v.minY) >= (v.maxY - petFrame.maxY)
            let leading = petFrame.midX < v.midX
            if ui.anchorTop != top { ui.anchorTop = top }
            if ui.anchorLeading != leading { ui.anchorLeading = leading }
            // Bar and tray (330 pt) are centred on the pet but kept 16 pt inside the screen.
            let m = Self.edgeMargin
            func shift(_ half: CGFloat) -> CGFloat {
                max(v.minX + m - (petFrame.midX - half), 0) + min(v.maxX - m - (petFrame.midX + half), 0)
            }
            if ui.contentShift != shift(165) { ui.contentShift = shift(165) }
            // The pill is 80 pt (40 without the bell); in Mini mode it *is* the clamped anchor → no shift.
            let pill: CGFloat = settings.mode == .mini ? 0 : shift(model.visible.isEmpty ? 20 : 40)
            if ui.pillShift != pill { ui.pillShift = pill }
        }
        let w = Self.panelSize.width, h = Self.panelSize.height, pad = Self.pad
        let x = petFrame.midX - w / 2  // the column is centred on the pet
        let y = ui.anchorTop ? petFrame.maxY + pad - h : petFrame.minY - pad
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        animator.petCenter = CGPoint(x: petFrame.midX, y: petFrame.midY)
    }

    /// `translation`: how far the pointer already moved before the drag was recognised (the 4 pt threshold),
    /// so the pet stays under the exact point that was pressed.
    func beginDrag(translation: CGSize = .zero) {
        let m = NSEvent.mouseLocation
        dragStartMouse = NSPoint(x: m.x - translation.width, y: m.y + translation.height)
        dragStartOrigin = petFrame.origin
        lastDragX = NSEvent.mouseLocation.x
        ui.revealed = false
    }

    func beginDragIfNeeded() { if dragStartMouse == nil { beginDrag() } }

    /// Moves the pet with the cursor; returns the run direction for the sprite.
    func drag() -> PetAnimation? {
        guard let m0 = dragStartMouse, let o0 = dragStartOrigin else { return nil }
        let m = NSEvent.mouseLocation
        petFrame.origin = NSPoint(x: o0.x + m.x - m0.x, y: o0.y + m.y - m0.y)
        layoutPanel(clamp: false)  // follow the cursor freely; settle on release
        let dx = m.x - lastDragX
        if abs(dx) >= 4 { lastDirection = dx > 0 ? .runningRight : .runningLeft; lastDragX = m.x }
        return lastDirection
    }

    /// The pet stays exactly where it is dropped (kept on-screen); holding Option at release snaps it
    /// to one of six slots ({top, bottom} x {left, centre, right}).
    func endDrag() {
        dragStartMouse = nil
        dragStartOrigin = nil
        if NSEvent.modifierFlags.contains(.option), let v = screen(for: petFrame)?.visibleFrame {
            let m = Self.edgeMargin
            let third = (petFrame.midX - v.minX) / v.width
            let x: CGFloat = third < 1.0 / 3 ? v.minX + m
                : third >= 2.0 / 3 ? v.maxX - m - petFrame.width
                : v.midX - petFrame.width / 2
            let y: CGFloat = petFrame.midY > v.midY ? v.maxY - m - petFrame.height : v.minY + m
            animateSnap(to: NSPoint(x: x, y: y))
        } else {
            layoutPanel()
            settings.petOrigin = petFrame.origin
        }
    }

    private func animateSnap(to target: NSPoint) {
        let start = petFrame.origin
        let steps = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 12
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.016) { [weak self] in
                guard let self, self.dragStartMouse == nil else { return }
                let t = Double(i) / Double(steps)
                let e = 1 - pow(1 - t, 3)  // ease-out
                self.petFrame.origin = NSPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e)
                self.layoutPanel(clamp: i == steps)
                if i == steps { self.settings.petOrigin = self.petFrame.origin }
            }
        }
    }

    func updatePetCenter() { layoutPanel() }
    var isDragging: Bool { dragStartMouse != nil }

    // MARK: interactions

    /// Clicking the pet toggles the quick-chat composer.
    func petClicked() {
        if ui.chatOpen && panel.isKeyWindow {
            ui.closeComposer()
        } else {
            ui.revealed = true
            ui.openComposer()
        }
    }
}

/// Closure-backed target for NSMenuItem actions.
final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}
