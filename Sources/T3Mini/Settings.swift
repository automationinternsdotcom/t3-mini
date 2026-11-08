import AppKit
import Combine

enum DisplayMode: String, CaseIterable { case pet, mini }
enum Visibility: String, CaseIterable { case always, onDemand }
/// Pet width in points, 80-224 with a default of 112 (height keeps the 192:208 cell aspect).
enum PetSize: String, CaseIterable {
    case small, medium, large, extraLarge
    var width: CGFloat {
        switch self {
        case .small: return 80
        case .medium: return 112
        case .large: return 160
        case .extraLarge: return 224
        }
    }
    var scale: CGFloat { width / 192 }
    var title: String {
        switch self {
        case .small: return "Small (80)"
        case .medium: return "Medium (112, default)"
        case .large: return "Large (160)"
        case .extraLarge: return "Extra large (224)"
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var mode: DisplayMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var visibility: Visibility { didSet { d.set(visibility.rawValue, forKey: "visibility") } }
    @Published var petId: String { didSet { d.set(petId, forKey: "petId") } }
    @Published var size: PetSize { didSet { d.set(size.rawValue, forKey: "size") } }
    @Published var shown: Bool { didSet { d.set(shown, forKey: "shown") } }
    @Published var mutedThreads: Set<String> { didSet { d.set(Array(mutedThreads), forKey: "mutedThreads") } }
    /// Dismissed card keys, oldest first (pruned to the newest 400).
    @Published var dismissedEvents: [String] { didSet { d.set(Array(dismissedEvents.suffix(400)), forKey: "dismissedEvents") } }
    @Published var lastProjectId: String? { didSet { d.set(lastProjectId, forKey: "lastProjectId") } }
    /// Pets that have already shown their first-awake greeting (once per pet).
    var greetedPets: Set<String> {
        get { Set(d.stringArray(forKey: "greetedPets") ?? []) }
        set { d.set(Array(newValue), forKey: "greetedPets") }
    }
    /// Screen position (bottom-left, AppKit coordinates) of the pet — the overlay is laid out around it.
    var petOrigin: NSPoint? {
        get {
            guard let a = d.array(forKey: "petOrigin") as? [Double], a.count == 2 else { return nil }
            return NSPoint(x: a[0], y: a[1])
        }
        set { d.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: "petOrigin") }
    }

    private init() {
        mode = DisplayMode(rawValue: d.string(forKey: "mode") ?? "") ?? .pet
        visibility = Visibility(rawValue: d.string(forKey: "visibility") ?? "") ?? .always
        petId = d.string(forKey: "petId") ?? "Built-in:tee"
        size = PetSize(rawValue: d.string(forKey: "size") ?? "") ?? .medium
        shown = d.object(forKey: "shown") as? Bool ?? true
        mutedThreads = Set(d.stringArray(forKey: "mutedThreads") ?? [])
        dismissedEvents = d.stringArray(forKey: "dismissedEvents") ?? []
        lastProjectId = d.string(forKey: "lastProjectId")
    }
}
