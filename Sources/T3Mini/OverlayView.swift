import AppKit
import Combine
import SwiftUI
import T3MiniCore

// Layout (see docs/behavior.md):
//  - at rest only the pet shows (plus a status badge); moving the pointer near it reveals a compact
//    bar beside it: [+ new chat] | [bell + count]. Clicking the pet opens the composer.
//  - the bell opens the activity tray (cards for threads that need you), above or below the pet.

/// Frames of the parts of the overlay that should receive clicks (in the overlay's coordinate space).
struct InteractiveRectsKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// Named control frames (e.g. "bell", "card:<id>", "reply:<id>") for hit-testing right-clicks and headless UI tests.
struct TaggedRectsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as clickable; everywhere else, clicks fall through to the windows underneath.
    func interactive() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: InteractiveRectsKey.self, value: [g.frame(in: .named("overlay"))])
        })
    }

    func tagged(_ name: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: TaggedRectsKey.self, value: [name: g.frame(in: .named("overlay"))])
        })
    }
}

/// Per-view mutable state (an observable stand-in for @State).
final class ViewState<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}

/// Transient UI state for the overlay.
final class OverlayState: ObservableObject {
    @Published var expanded = false  // activity tray visible (collapsed stack or list)
    @Published var listExpanded = false  // tray shows the full list rather than the collapsed stack
    /// Horizontal nudge so the 330 pt bar/tray stay 16 pt inside the screen while centred on the pet.
    @Published var contentShift: CGFloat = 0
    /// Same for the compact pill (its own width; usually 0, i.e. exactly centred on the pet).
    @Published var pillShift: CGFloat = 0
    /// Card under the pointer, computed from geometry by the panel's mouse timer (SwiftUI's onHover goes
    /// stale in a click-through, non-activating panel, e.g. after a context menu).
    @Published var hoveredCard: String?
    @Published var chatOpen = false  // composer open (new chat)
    @Published var draft = ""  // composer text; a draft keeps the bar open
    @Published var replyingTo: String?  // thread id with inline follow-up field
    @Published var replyDrafts: [String: String] = [:]  // follow-up text per thread (survives an outside click)
    var replyDraftPending: Bool { replyingTo.map { !(replyDrafts[$0] ?? "").isEmpty } ?? false }
    @Published var peeking: String?  // thread id with transcript peek open
    @Published var peekMessages: [StateReader.Message] = []
    @Published var greeting: String?  // first-awake card
    @Published var toast: String?
    @Published var busy = false
    @Published var focusChat = UUID()  // bump to focus the composer
    /// Pet is in the upper half of the screen: open the tray below it instead of above.
    @Published var anchorTop = false
    /// Pet is in the left half of the screen: open the bar/tray to its right.
    @Published var anchorLeading = false
    /// Pointer is near the pet (or the controls it revealed). At rest only the pet shows.
    @Published var revealed = false
    /// Make the (non-activating) panel key so a text field can take typing.
    var makeKey: () -> Void = {}
    var resignKey: () -> Void = {}

    func say(_ text: String, for seconds: Double = 4) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    /// Bell cycle: hidden → collapsed stack → hidden; expanded list → collapsed stack.
    /// With one card there is no stack, so the bell simply shows/hides it.
    func bellTapped(count: Int) {
        if !expanded { expanded = true; listExpanded = false }
        else if listExpanded && count > 1 { listExpanded = false }
        else { closeTray() }
    }

    func bellLabel(count: Int) -> String {
        if !expanded { return "Notifications (\(count))" }
        return listExpanded && count > 1 ? "Show fewer" : "Hide notifications"
    }

    func closeTray() { expanded = false; listExpanded = false }

    func openComposer() {
        chatOpen = true
        makeKey()
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.focusChat = UUID() }
        }
    }

    func closeComposer() {
        chatOpen = false
        resignKey()
    }
}

extension AttentionState {
    var color: Color {
        switch self {
        case .needsInput: return Color(red: 1.0, green: 0.62, blue: 0.2)
        case .blocked: return Color(red: 0.95, green: 0.3, blue: 0.3)
        case .ready: return Color(red: 0.3, green: 0.82, blue: 0.5)
        case .running: return Color(red: 0.4, green: 0.65, blue: 1.0)
        case .idle: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .needsInput: return "exclamationmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .ready: return "checkmark.circle.fill"
        case .running: return "circle.dotted"
        case .idle: return "clock"
        }
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .interactive()
    }
}

/// Animations that respect Reduce Motion.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation? { reduced ? nil : .spring(response: 0.3, dampingFraction: 0.85) }
    static var fade: Animation? { reduced ? nil : .easeOut(duration: 0.2) }
    static var opacity: AnyTransition { reduced ? .identity : .opacity }
    static func slide(_ edge: Edge) -> AnyTransition { reduced ? .identity : .move(edge: edge).combined(with: .opacity) }
}

/// The rounded "glass" surface used by the bar and its buttons.
struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .interactive()
    }
}

struct StatusIcon: View {
    let state: AttentionState
    @StateObject private var spin = ViewState(false)
    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.color)
            .rotationEffect(.degrees(state == .running && spin.v ? 360 : 0))
            .animation(state == .running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? .linear(duration: 2).repeatForever(autoreverses: false) : .default, value: spin.v)
            .onAppear { spin.v = true }
            .accessibilityLabel(state == .needsInput ? "Question" : state.label)
    }
}

struct OverlayView: View {
    @ObservedObject var model: MiniModel
    @ObservedObject var settings: Settings
    @ObservedObject var animator: PetAnimator
    @ObservedObject var ui: OverlayState
    let controller: PanelController

    var body: some View {
        // Everything is a column centred on the pet — pet, bar (4 pt gap), tray (12 pt gap) —
        // growing downward when the pet is in the upper half of the screen, upward otherwise.
        let items = columnItems()
        VStack(alignment: .center, spacing: 0) {
            // Stable ids: the pet must keep its identity when the bar appears/disappears, or a drag is cancelled.
            ForEach(ui.anchorTop ? items : items.reversed(), id: \.id) { $0.view }
        }
        .padding(.vertical, PanelController.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: ui.anchorTop ? .top : .bottom)
        .coordinateSpace(name: "overlay")
        .onPreferenceChange(InteractiveRectsKey.self) { rects in controller.interactiveRects = rects }
        .onPreferenceChange(TaggedRectsKey.self) { rects in controller.taggedRects = rects }
        // Reduce Motion: no springs, fades or slides.
        .animation(Motion.spring, value: ui.expanded)
        .animation(Motion.spring, value: ui.listExpanded)
        .animation(Motion.fade, value: ui.revealed)
        .animation(Motion.fade, value: ui.chatOpen)
        .animation(Motion.fade, value: ui.toast)
    }

    struct Item { let id: String; let view: AnyView }
    private func gap(_ id: String, _ h: CGFloat) -> Item { Item(id: id, view: AnyView(Color.clear.frame(width: 1, height: h))) }

    /// Listed from the pet outward.
    private func columnItems() -> [Item] {
        var out: [Item] = []
        let showBar = settings.mode == .mini || ui.revealed || ui.expanded || ui.chatOpen
        if settings.mode == .pet {
            out.append(Item(id: "pet", view: AnyView(PetSprite(animator: animator, settings: settings, controller: controller, model: model, ui: ui))))
            if showBar { out.append(gap("gap-bar", 4)) }
        }
        if showBar {
            out.append(Item(id: "bar", view: AnyView(ControlBar(model: model, settings: settings, ui: ui, controller: controller)
                .offset(x: ui.chatOpen ? ui.contentShift : ui.pillShift).transition(Motion.opacity))))
        }
        if let greeting = ui.greeting {  // first-awake card sits nearest the pet, the tray beyond it
            out.append(gap("gap-greeting", 12))
            out.append(Item(id: "greeting", view: AnyView(GreetingCard(text: greeting, ui: ui).offset(x: ui.contentShift).transition(Motion.opacity))))
        }
        if ui.expanded {
            out.append(gap("gap-tray", ui.greeting == nil ? 12 : 8))
            out.append(Item(id: "tray", view: AnyView(ActivityTray(model: model, ui: ui, controller: controller).offset(x: ui.contentShift)
                .transition(Motion.slide(ui.anchorTop ? .top : .bottom)))))
        }
        if let toast = ui.toast {
            out.append(gap("gap-toast", 8))
            out.append(Item(id: "toast", view: AnyView(Card { Text(toast).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                .frame(maxWidth: 330).offset(x: ui.contentShift).transition(Motion.opacity))))
        }
        return out
    }
}

// MARK: - Pet

struct PetSprite: View {
    @ObservedObject var animator: PetAnimator
    @ObservedObject var settings: Settings
    let controller: PanelController
    @ObservedObject var model: MiniModel
    @ObservedObject var ui: OverlayState
    @StateObject private var dragging = ViewState(false)

    var body: some View {
        let s = settings.size.scale
        Group {
            if let frame = animator.frame {
                Image(decorative: frame, scale: 1).interpolation(.none).resizable()
            } else {
                Image(systemName: "pawprint.fill").resizable().scaledToFit().padding(30).foregroundStyle(.secondary)
            }
        }
        .frame(width: 192 * s, height: 208 * s)
        .contentShape(Rectangle().inset(by: 30 * s))
        .overlay(alignment: .topTrailing) { badge(s) }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging.v { dragging.v = true; controller.beginDrag(translation: value.translation) }
                    animator.dragDirection = controller.drag()
                }
                .onEnded { _ in
                    dragging.v = false
                    animator.dragDirection = nil
                    controller.endDrag()
                }
        )
        .onTapGesture(count: 1) { controller.petClicked() }
        .help("Click to chat · Drag to move (hold ⌥ to snap to an edge) · Right-click for options")
        .accessibilityLabel("\(controller.currentPetName), \(model.aggregate.label)")
        .tagged("pet")
        .interactive()
    }

    /// Amber when something needs input or is blocked, green when the top item is ready;
    /// only while the tray is closed.
    @ViewBuilder private func badge(_ s: CGFloat) -> some View {
        let attention = model.attention.contains { $0.state == .needsInput || $0.state == .blocked }
        let success = model.top?.state == .ready
        if !ui.expanded, attention || success {
            Circle().fill(attention ? AttentionState.needsInput.color : AttentionState.ready.color)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .offset(x: -26 * s, y: 40 * s)
                .accessibilityLabel(attention ? "Needs attention" : "Ready")
        }
    }
}

// MARK: - Control bar: compact pill [+] [bell]; expands into the composer

struct ControlBar: View {
    @ObservedObject var model: MiniModel
    @ObservedObject var settings: Settings
    @ObservedObject var ui: OverlayState
    let controller: PanelController

    var body: some View {
        let count = model.visible.count
        Group {
            if ui.chatOpen {
                HStack(alignment: .bottom, spacing: 6) {
                    Composer(model: model, settings: settings, ui: ui, controller: controller)
                    if count > 0 || ui.expanded { bell(count: count).frame(width: 40, height: 40).modifier(Glass()) }
                }
                .frame(maxWidth: 330)
            } else {
                // Compact pill: 20 pt icons, 20 pt gaps, 10 pt ends → 80 pt for two icons.
                HStack(spacing: 20) {
                    iconButton("Start new chat", "plus") { ui.openComposer() }.tagged("newchat")
                    if count > 0 || ui.expanded { bell(count: count) }
                }
                .padding(.horizontal, 10).frame(height: 40)
                .modifier(Glass())
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in if settings.mode == .mini { controller.beginDragIfNeeded(); _ = controller.drag() } }
                    .onEnded { _ in if settings.mode == .mini { controller.endDrag() } })
                .tagged("bar")
            }
        }
    }

    private func bell(count: Int) -> some View {
        let label = ui.bellLabel(count: count)
        let chevron = ui.anchorTop ? "chevron.up" : "chevron.down"
        return Button { ui.bellTapped(count: count) } label: {
            Image(systemName: ui.expanded ? chevron : (count > 0 ? "bell.fill" : "bell"))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20, height: 20)
                .overlay(alignment: .topTrailing) {
                    if !ui.expanded, count > 0 {
                        Text("\(count)").font(.system(size: 8, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3).frame(minWidth: 12, minHeight: 12)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 7, y: -6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(count > 0 || ui.expanded ? Color.primary : Color.secondary)
        .help(label)
        .accessibilityLabel(label)
        .tagged("bell")
    }

    private func iconButton(_ label: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct Composer: View {
    @ObservedObject var model: MiniModel
    @ObservedObject var settings: Settings
    @ObservedObject var ui: OverlayState
    let controller: PanelController
    @FocusState private var focused: Bool

    var body: some View {
        let project = model.defaultProject
        HStack(spacing: 6) {
            Menu {
                ForEach(model.projects) { p in
                    Button((p.id == project?.id ? "✓ " : "") + p.title) { settings.lastProjectId = p.id }
                }
            } label: {
                Text(project?.title ?? "Project").font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Project for new chats")
            .tagged("project")
            // Grows with the draft (up to 5 lines); Return sends, Option-Return adds a line.
            TextField("Start new chat", text: $ui.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .onSubmit(send)
                .frame(minWidth: 100)
                .padding(.vertical, 10)
                .tagged("composer")
            Button(action: send) {
                Image(systemName: ui.busy ? "hourglass" : "arrow.up.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .disabled(ui.draft.trimmingCharacters(in: .whitespaces).isEmpty || ui.busy || project == nil)
            .help("Send message").accessibilityLabel("Send message")
            .tagged("send")
        }
        .padding(.horizontal, 10).frame(minHeight: 40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .interactive()
        .accessibilityElement(children: .contain)
        .onAppear { if ui.chatOpen { focusSoon() } }
        .onChange(of: ui.focusChat) { _ in focusSoon() }
        .onExitCommand { ui.closeComposer() }
    }

    private func focusSoon() {
        controller.makeKey()
        DispatchQueue.main.async { focused = true }
    }

    private func send() {
        let msg = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, !ui.busy, let project = model.defaultProject else { return }
        ui.busy = true
        ui.say("Starting your chat", for: 15)
        let chosenModel = project.hasDefaultModel ? nil : model.fallbackModel(projectId: project.id)
        T3Actions.start(projectId: project.id, message: msg, model: chosenModel) { r in
            ui.busy = false
            if r.ok {
                ui.draft = ""
                ui.say("Started a new chat in \(project.title)")
                ui.closeComposer()  // the new thread appears as a Running card in the tray
                settings.lastProjectId = project.id
            } else {
                ui.say("Unable to start chat: \(r.output.prefix(160))", for: 7)
            }
            model.refresh(force: true)
        }
    }
}

// MARK: - Activity tray

struct GreetingCard: View {
    let text: String
    @ObservedObject var ui: OverlayState
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.wave.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(.system(size: 12, weight: .semibold))
                    Text("I'll tell you when a T3 thread needs you.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 300)
        .onTapGesture { ui.greeting = nil }
        .tagged("greeting")
    }
}

struct ActivityTray: View {
    @ObservedObject var model: MiniModel
    @ObservedObject var ui: OverlayState
    let controller: PanelController

    var body: some View {
        let items = model.visible
        Group {
            if items.isEmpty {
                Card { Text("All caught up. Nothing needs you.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .tagged("empty")
            } else if !ui.listExpanded && items.count > 1 {
                collapsedStack(items)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(items) { a in ActivityCard(a: a, model: model, ui: ui) }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 2)
                }
                .frame(maxHeight: controller.trayMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .interactive()
                .tagged("list")
            }
        }
        .frame(width: 330)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
        .onChange(of: items.isEmpty) { empty in if empty { ui.closeTray() } }
    }

    /// Collapsed stack: the top card, with up to two smaller cards peeking behind it
    /// (+8 / +16 pt, scaled 0.94 / 0.86). Clicking it expands the list.
    private func collapsedStack(_ items: [ThreadActivity]) -> some View {
        let dir: CGFloat = ui.anchorTop ? 1 : -1
        return ZStack(alignment: ui.anchorTop ? .top : .bottom) {
            ForEach(Array([16, 8].enumerated()), id: \.offset) { i, off in
                if items.count > 2 - i {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
                        .frame(height: 56)
                        .scaleEffect(off == 16 ? 0.86 : 0.94)
                        .offset(y: CGFloat(off) * dir)
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                }
            }
            ActivityCard(a: items[0], model: model, ui: ui, stacked: true)
        }
        .padding(ui.anchorTop ? .bottom : .top, 16)
        .frame(maxHeight: controller.trayMaxHeight, alignment: ui.anchorTop ? .top : .bottom)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { ui.listExpanded = true }  // ghost cards expand too
        .interactive()
        .accessibilityLabel("Show all \(items.count) notifications")
        .tagged("stack")
    }
}

struct ActivityCard: View {
    let a: ThreadActivity
    @ObservedObject var model: MiniModel
    @ObservedObject var ui: OverlayState
    /// Top card of the collapsed stack: a click expands the list instead of opening the thread.
    var stacked = false
    @FocusState private var replyFocused: Bool
    private var hovering: Bool { ui.hoveredCard == a.threadId }

    private var replyText: Binding<String> {
        Binding(get: { ui.replyDrafts[a.threadId] ?? "" }, set: { ui.replyDrafts[a.threadId] = $0 })
    }

    private func closeReply() {
        ui.replyingTo = nil
        ui.resignKey()  // hand typing back to the user's app
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                StatusIcon(state: a.state).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let digest = a.summary {
                        // Ready: one high-signal line for what you need to do, one for the situation.
                        Text(digest.need ?? "Nothing needed from you")
                            .font(.system(size: 11.5, weight: digest.need == nil ? .regular : .semibold))
                            .foregroundStyle(digest.need == nil ? Color.secondary : Color.primary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .tagged("need:\(a.threadId)")
                    }
                    HStack(spacing: 4) {
                        Text(a.state.label).foregroundStyle(a.state.color)
                        Text("·").foregroundStyle(.tertiary)
                        Text(a.summary?.situation ?? a.subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.system(size: 11))
                }
                Spacer(minLength: 4)
                if (hovering || ui.replyingTo == a.threadId) && !stacked {
                    Button { if ui.replyingTo == a.threadId { closeReply() } else { ui.replyingTo = a.threadId } } label: {
                        Image(systemName: "arrowshape.turn.up.left").font(.system(size: 12, weight: .medium))
                            .frame(width: 32, height: 32)
                            .background(ui.replyingTo == a.threadId ? Color.primary.opacity(0.12) : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Reply to \(a.title)").accessibilityLabel("Reply to \(a.title)")
                    .tagged("reply:\(a.threadId)")
                }
            }
            .frame(minHeight: 38)
            .contentShape(Rectangle())
            .onTapGesture {
                if stacked { ui.listExpanded = true } else { T3Actions.openThread(a.threadId) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([a.title, a.summary.map { $0.need ?? "Nothing needed from you" }, a.state.label,
                                 a.summary?.situation ?? a.subtitle, "Open in T3"].compactMap { $0 }.joined(separator: ". "))
            .accessibilityAddTraits(.isButton)
            .tagged("cardbody:\(a.threadId)")

            // Questions and approvals are answered in T3 itself.
            if a.state == .needsInput && !stacked {
                Button { T3Actions.openThread(a.threadId) } label: {
                    Text("Review in T3").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(a.state.color.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open \(a.title) in T3 to respond")
                .tagged("review:\(a.threadId)")
            }
            if ui.peeking == a.threadId && !stacked { Transcript(messages: ui.peekMessages) }
            if ui.replyingTo == a.threadId && !stacked {
                HStack {
                    TextField("Follow up", text: replyText, onCommit: send)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .focused($replyFocused)
                        .accessibilityLabel("Follow up on \(a.title)")
                        .onAppear {
                            ui.makeKey()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { replyFocused = true }
                        }
                        .onExitCommand { closeReply() }
                        .tagged("replyfield:\(a.threadId)")
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                        .buttonStyle(.plain).disabled(replyText.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || ui.busy)
                        .help("Send message").accessibilityLabel("Send message")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: 330, alignment: .leading)
        .frame(minHeight: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        // Hover-only dismiss "x" on the card's top-left corner.
        .overlay(alignment: .topLeading) {
            if hovering && !stacked {
                Button { model.dismiss(a) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .offset(x: 0, y: -4)
                .help("Dismiss \(a.title)").accessibilityLabel("Dismiss \(a.title)")
                .tagged("dismiss:\(a.threadId)")
            }
        }
        // No .interactive() here: inside the scrolling list a card's frame is unclipped; the list (or the
        // stack) reports the visible clickable area instead.
        .help(a.projectTitle.map { "\(a.title) — \($0)" } ?? a.title)
        .tagged("card:\(a.threadId)")
    }

    private func send() {
        let text = replyText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !ui.busy else { return }
        ui.busy = true
        T3Actions.send(threadId: a.threadId, message: text) { r in
            ui.busy = false
            if r.ok {
                ui.replyDrafts[a.threadId] = nil
                closeReply()
                ui.say("Sent to “\(a.title)”")
            } else {
                ui.say("Unable to send reply: \(r.output.prefix(160))", for: 7)
            }
            model.refresh(force: true)
        }
    }
}

struct Transcript: View {
    let messages: [StateReader.Message]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if messages.isEmpty { Text("Loading messages").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(messages) { m in
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.role == "user" ? "You" : "Agent").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(m.role == "user" ? Color.accentColor : .secondary)
                    Text(m.text.count > 400 ? String(m.text.prefix(400)) + "…" : m.text)
                        .font(.system(size: 11)).lineLimit(6).textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Conversation transcript")
    }
}
