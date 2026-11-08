import AppKit
import Combine
import ServiceManagement
import T3MiniCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = MiniModel()
    lazy var controller = PanelController(model: model)
    let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var clickAwayMonitor: Any?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        setUpStatusItem()
        loadPets()
        controller.onChange = { [weak self] in self?.updateStatusItem() }
        controller.mainMenu = { [weak self] in
            let menu = NSMenu()
            self?.menuNeedsUpdate(menu)
            return menu
        }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.stateChanged() } }
            .store(in: &bag)
        model.transitions.sink { [weak self] a in self?.celebrate(a) }.store(in: &bag)
        settings.$size.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.controller.updatePetCenter() } }.store(in: &bag)
        settings.$mode.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.controller.layoutPanel() }
        }.store(in: &bag)
        model.start()

        hotKey = HotKey { [weak self] in self?.showAndFocus() }
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.controller.isVisible else { return }
            // Global monitors only see clicks in other apps, i.e. outside the overlay.
            // An outside click closes the tray and collapses the bar (a draft stays).
            let ui = self.controller.ui
            // An unsent follow-up keeps its card (and the tray) open, like the composer's draft.
            if !ui.replyDraftPending { ui.closeTray(); ui.replyingTo = nil }
            if ui.draft.isEmpty { ui.chatOpen = false }
            ui.revealed = false
            self.controller.resignKey()
            if self.settings.visibility == .onDemand { self.controller.hide() }
        }

        if settings.shown && settings.visibility == .always { controller.show() }
        greetIfNewPet()
        updateStatusItem()
    }

    // MARK: pets

    private var builtInPetsDir: URL? {
        if let env = ProcessInfo.processInfo.environment["T3MINI_PETS_DIR"] { return URL(fileURLWithPath: env) }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("pets"), FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        // Running unbundled from .build/: walk up to the repo's assets/pets.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("assets/pets")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    func loadPets() {
        try? FileManager.default.createDirectory(at: PetCatalog.t3MiniPetsDir, withIntermediateDirectories: true)
        let (pets, errors) = PetCatalog.discover(builtInDir: builtInPetsDir)
        errors.forEach { NSLog("T3 Mini pet skipped: %@", $0) }
        controller.pets = pets
        controller.applyPet()
    }

    // MARK: state → pet

    private func stateChanged() {
        // The top card decides the pet's animation; its clip plays 3 times, then the pet idles.
        controller.animator.setBase(PetAnimation.forState(model.aggregate))
        if !controller.isDragging { controller.layoutPanel() }  // pill width depends on whether items exist
        updateStatusItem()
    }

    /// A thread newly needs you / finished / failed: replay the status clip even if the top state is unchanged.
    private func celebrate(_ a: ThreadActivity) {
        controller.animator.setBase(PetAnimation.forState(model.aggregate), replay: true)
    }

    /// The first time each pet is shown, a short greeting card appears for 8 s while it waves.
    func greetIfNewPet() {
        guard let pet = controller.currentPet, !settings.greetedPets.contains(pet.id), settings.mode == .pet else { return }
        // On demand starts hidden: greet the next time Mini is shown instead of forcing it open.
        guard controller.isVisible else { return }
        settings.greetedPets.insert(pet.id)
        let text = "Hi, I'm \(pet.manifest.displayName)"
        controller.ui.greeting = text
        controller.animator.play(.waving)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.controller.ui.greeting == text { self?.controller.ui.greeting = nil }
        }
    }

    /// Hotkey: hidden → show and focus the composer; visible but unfocused → focus it;
    /// focused → close the composer (On demand: hide).
    func showAndFocus() {
        if controller.isVisible && controller.panel.isKeyWindow {
            if settings.visibility == .onDemand { controller.hide() } else { controller.ui.closeComposer() }
            return
        }
        controller.show(focusChat: true)
        greetIfNewPet()
    }

    // MARK: URL control: t3mini://show | hide | toggle | chat | mini | pet

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        switch url.host ?? "" {
        case "show": controller.show(); greetIfNewPet()
        case "hide": controller.hide()
        case "toggle": controller.toggle()
        case "chat": controller.show(focusChat: true)
        case "mini": settings.mode = .mini; controller.show()
        case "pet": settings.mode = .pet; controller.show()
        case "activity": controller.ui.expanded = true; controller.show()
        case "debug":  // dev/QA only: opt in with `defaults write com.t3mini.app debugSnapshot -bool true`
            if UserDefaults.standard.bool(forKey: "debugSnapshot") { writeDebugSnapshot() }
        case "unmute": settings.mutedThreads.removeAll()
        default: break
        }
        updateStatusItem()
    }

    /// t3mini://debug → ~/Library/Logs/T3Mini/state.json (for headless verification).
    private func writeDebugSnapshot() {
        let c = controller
        let f = c.panel.frame
        let snap: [String: Any] = [
            "visible": c.isVisible,
            "isKey": c.panel.isKeyWindow,
            "appActive": NSApp.isActive,
            "ignoresMouseEvents": c.panel.ignoresMouseEvents,
            "panelFrame": [f.minX, f.minY, f.width, f.height],
            "interactiveRects": c.interactiveRects.map { [$0.minX, $0.minY, $0.width, $0.height] },
            "mode": settings.mode.rawValue,
            "pet": settings.petId,
            "petLoaded": c.animator.frame != nil,
            "pets": c.pets.map(\.id),
            "aggregate": model.aggregate.rawValue,
            "top": model.top?.title ?? "",
            "visibleCount": model.visible.count,
            "serverRunning": model.serverRunning,
            "expanded": c.ui.expanded,
            "listExpanded": c.ui.listExpanded,
            "contentShift": c.ui.contentShift,
            "pillShift": c.ui.pillShift,
            "chatOpen": c.ui.chatOpen,
            "peeking": c.ui.peeking ?? "",
            "replyingTo": c.ui.replyingTo ?? "",
            "peekMessages": c.ui.peekMessages.count,
            "muted": Array(settings.mutedThreads),
            "cards": model.visible.map { ["id": $0.threadId, "title": $0.title, "state": $0.state.rawValue] },
            "revealed": c.ui.revealed,
            "draft": c.ui.draft,
            "greeting": c.ui.greeting ?? "",
            "anchorTop": c.ui.anchorTop,
            "anchorLeading": c.ui.anchorLeading,
            "petFrame": [c.petFrame.minX, c.petFrame.minY, c.petFrame.width, c.petFrame.height],
            "animation": "\(c.animator.effective)",
            // Centre of each tagged control in global top-left coordinates (as CGEvent uses).
            "controls": c.taggedRects.mapValues { r -> [Double] in
                let s = c.screenRect(r)
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                return [Double(s.midX), Double(top - s.midY), Double(r.width), Double(r.height)]
            },
            "toast": c.ui.toast ?? "",
            "screens": NSScreen.screens.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] },
        ]
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/T3Mini")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: snap, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("state.json"))
        }
    }

    // MARK: menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let state = model.aggregate
        let symbol: String
        switch state {
        case .needsInput: symbol = "pawprint.circle.fill"
        case .blocked: symbol = "exclamationmark.triangle.fill"
        case .ready: symbol = "checkmark.circle.fill"
        case .running: symbol = "pawprint.fill"
        case .idle: symbol = "pawprint"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "T3 Mini: \(state.label)")
        img?.isTemplate = state == .idle || state == .running
        button.image = img
        if state != .idle && state != .running {
            let tint: NSColor = state == .needsInput ? .systemOrange : state == .blocked ? .systemRed : .systemGreen
            button.image = img?.withSymbolConfiguration(.init(paletteColors: [tint]))
        }
        let n = model.attention.count
        button.title = n > 0 ? " \(n)" : ""
        button.imagePosition = .imageLeading
        button.toolTip = model.top.map { "\($0.state.label): \($0.title)" } ?? "T3 Mini: all caught up"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !model.serverRunning {
            menu.addItem(disabled("T3 Code isn't running"))
        } else if model.visible.isEmpty {
            menu.addItem(disabled("All caught up"))
        } else {
            for a in model.visible.prefix(8) {
                let item = NSMenuItem(title: "\(a.state.label) · \(a.title)", action: #selector(openActivity(_:)), keyEquivalent: "")
                item.representedObject = a.threadId
                item.target = self
                item.image = NSImage(systemSymbolName: a.state.symbol, accessibilityDescription: nil)
                item.toolTip = a.subtitle
                menu.addItem(item)
            }
        }
        let muted = settings.mutedThreads
        if !muted.isEmpty {
            let mm = NSMenu()
            let known = model.mutedTitles
            for id in muted.sorted(by: { (known[$0] ?? $0) < (known[$1] ?? $1) }) {
                let i = item("Unmute “\(known[id] ?? "chat")”", #selector(unmute(_:)))
                i.representedObject = id
                mm.addItem(i)
            }
            menu.addItem(submenu("Muted chats (\(muted.count))", mm))
        }
        menu.addItem(.separator())
        menu.addItem(item(controller.isVisible ? "Hide Mini" : "Show Mini", #selector(togglePanel), "p", [.control, .option]))
        menu.addItem(item("Quick Chat…", #selector(quickChat)))
        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for (title, mode) in [("Pet", DisplayMode.pet), ("Mini (no pet)", DisplayMode.mini)] {
            let i = item(title, #selector(setMode(_:)))
            i.representedObject = mode.rawValue
            i.state = settings.mode == mode ? .on : .off
            modeMenu.addItem(i)
        }
        menu.addItem(submenu("Mode", modeMenu))

        let petMenu = NSMenu()
        var lastSource: PetPackage.Source?
        for p in controller.pets {
            if let ls = lastSource, ls != p.source { petMenu.addItem(.separator()) }
            if lastSource != p.source { petMenu.addItem(disabled(p.source == .builtIn ? "Built-in" : "Custom (\(p.source.rawValue))")) }
            lastSource = p.source
            let i = item(p.manifest.displayName, #selector(choosePet(_:)))
            i.representedObject = p.id
            i.state = p.id == settings.petId ? .on : .off
            i.toolTip = p.manifest.description
            petMenu.addItem(i)
        }
        petMenu.addItem(.separator())
        petMenu.addItem(item("Open Pets Folder", #selector(openPetsFolder)))
        petMenu.addItem(item("Reload Pets", #selector(reloadPets)))
        menu.addItem(submenu("Pet", petMenu))

        let sizeMenu = NSMenu()
        for s in PetSize.allCases {
            let i = item(s.title, #selector(setSize(_:)))
            i.representedObject = s.rawValue
            i.state = settings.size == s ? .on : .off
            sizeMenu.addItem(i)
        }
        menu.addItem(submenu("Pet Size", sizeMenu))

        let visMenu = NSMenu()
        for (title, v) in [("Always visible", Visibility.always), ("On demand (⌃⌥P, hides on click away)", Visibility.onDemand)] {
            let i = item(title, #selector(setVisibility(_:)))
            i.representedObject = v.rawValue
            i.state = settings.visibility == v ? .on : .off
            visMenu.addItem(i)
        }
        menu.addItem(submenu("Visibility", visMenu))

        if #available(macOS 13.0, *), Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            let login = item("Launch at Login", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open T3 Code", #selector(openT3)))
        menu.addItem(item("Quit T3 Mini", #selector(quit), "q"))
        menu.addItem(.separator())
        menu.addItem(disabled("Unofficial — not affiliated with T3 Tools or OpenAI"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    @objc private func openActivity(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { T3Actions.openThread(id) }
    }
    @objc private func togglePanel() { controller.toggle(); if controller.isVisible { greetIfNewPet() } }
    @objc private func unmute(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { settings.mutedThreads.remove(id) }
    }
    @objc private func quickChat() { controller.show(focusChat: true) }
    @objc private func setMode(_ sender: NSMenuItem) {
        settings.mode = DisplayMode(rawValue: sender.representedObject as? String ?? "") ?? .pet
        controller.show()
    }
    @objc private func choosePet(_ sender: NSMenuItem) {
        settings.petId = sender.representedObject as? String ?? settings.petId
        settings.mode = .pet
        controller.applyPet()
        controller.show()
        greetIfNewPet()
    }
    @objc private func setSize(_ sender: NSMenuItem) {
        settings.size = PetSize(rawValue: sender.representedObject as? String ?? "") ?? .medium
    }
    @objc private func setVisibility(_ sender: NSMenuItem) {
        settings.visibility = Visibility(rawValue: sender.representedObject as? String ?? "") ?? .always
        if settings.visibility == .always { controller.show() }
    }
    @objc private func openPetsFolder() { NSWorkspace.shared.open(PetCatalog.t3MiniPetsDir) }
    @objc private func reloadPets() { loadPets() }
    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            controller.ui.say("Couldn't change Launch at Login: \(error.localizedDescription)", for: 6)
            controller.show()
        }
    }
    @objc private func openT3() { T3Actions.activateT3() }
    @objc private func quit() { NSApp.terminate(nil) }
}
