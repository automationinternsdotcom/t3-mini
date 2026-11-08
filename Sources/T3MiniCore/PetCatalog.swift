import CoreGraphics
import Foundation
import ImageIO

/// A pet package: pet.json + sprite atlas (PNG or WebP). Also reads custom pets from ~/.codex/pets.
public struct PetManifest: Codable, Equatable {
    public var id: String
    public var displayName: String
    public var description: String?
    public var spriteVersionNumber: Int?
    public var spritesheetPath: String?
}

public struct PetPackage: Equatable, Identifiable {
    public enum Source: String { case builtIn = "Built-in", t3Mini = "T3 Mini", codex = "Codex" }
    public var id: String { "\(source.rawValue):\(manifest.id)" }
    public var manifest: PetManifest
    public var directory: URL
    public var source: Source
    public var version: Int
    public var sheetURL: URL
    public var sheetSize: CGSize

    public var rows: Int { version >= 2 ? 11 : 9 }
    public static let cellSize = CGSize(width: 192, height: 208)
    public static let columns = 8
}

/// Animation rows and frame timings of the pet atlas.
public enum PetAnimation: Int, CaseIterable {
    case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, running, review

    public var frameDurationsMs: [Int] {
        switch self {
        case .idle: return [280, 110, 110, 140, 140, 320]
        case .runningRight, .runningLeft: return Array(repeating: 120, count: 7) + [220]
        case .waving: return [140, 140, 140, 280]
        case .jumping: return [140, 140, 140, 140, 280]
        case .failed: return Array(repeating: 140, count: 7) + [240]
        case .waiting: return Array(repeating: 150, count: 5) + [260]
        case .running: return Array(repeating: 120, count: 5) + [220]
        case .review: return Array(repeating: 150, count: 5) + [280]
        }
    }

    public var loops: Bool { self != .jumping && self != .waving }

    public static func forState(_ s: AttentionState) -> PetAnimation {
        switch s {
        case .needsInput: return .waiting
        case .blocked: return .failed
        case .ready: return .review
        case .running: return .running
        case .idle: return .idle
        }
    }
}

public enum PetCatalog {
    public enum LoadError: Error, CustomStringConvertible {
        case manifest(URL, String), sheet(URL, String)
        public var description: String {
            switch self {
            case .manifest(let u, let m): return "\(u.lastPathComponent): \(m)"
            case .sheet(let u, let m): return "\(u.path): \(m)"
            }
        }
    }

    public static var t3MiniPetsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3-mini/pets")
    }

    public static var codexPetsDir: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: (h as NSString).expandingTildeInPath).appendingPathComponent("pets")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/pets")
    }

    public static func load(directory: URL, source: PetPackage.Source) throws -> PetPackage {
        let mURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: mURL) else { throw LoadError.manifest(mURL, "missing pet.json") }
        let manifest: PetManifest
        do { manifest = try JSONDecoder().decode(PetManifest.self, from: data) } catch {
            throw LoadError.manifest(mURL, "invalid pet.json: \(error)")
        }
        let version = manifest.spriteVersionNumber ?? 1
        guard version == 1 || version == 2 else { throw LoadError.manifest(mURL, "unsupported spriteVersionNumber \(version)") }
        // spritesheetPath defaults to spritesheet.webp; accept a png sibling too.
        var sheet = directory.appendingPathComponent(manifest.spritesheetPath ?? "spritesheet.webp")
        if !FileManager.default.fileExists(atPath: sheet.path), manifest.spritesheetPath == nil {
            let png = directory.appendingPathComponent("spritesheet.png")
            if FileManager.default.fileExists(atPath: png.path) { sheet = png }
        }
        guard let src = CGImageSourceCreateWithURL(sheet as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw LoadError.sheet(sheet, "unreadable sprite sheet") }
        let expectedH = version >= 2 ? 2288 : 1872
        guard w == 1536, h == expectedH else {
            throw LoadError.sheet(sheet, "expected 1536x\(expectedH) for v\(version), got \(w)x\(h)")
        }
        return PetPackage(manifest: manifest, directory: directory, source: source, version: version,
                          sheetURL: sheet, sheetSize: CGSize(width: w, height: h))
    }

    /// All pets: built-ins first, then T3 Mini custom pets, then pets in ~/.codex/pets.
    public static func discover(builtInDir: URL?) -> (pets: [PetPackage], errors: [String]) {
        var pets: [PetPackage] = []
        var errors: [String] = []
        let sources: [(URL?, PetPackage.Source)] = [(builtInDir, .builtIn), (t3MiniPetsDir, .t3Mini), (codexPetsDir, .codex)]
        for (dir, source) in sources {
            guard let dir,
                  let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                do { pets.append(try load(directory: entry, source: source)) } catch { errors.append("\(error)") }
            }
        }
        return (pets, errors)
    }
}
