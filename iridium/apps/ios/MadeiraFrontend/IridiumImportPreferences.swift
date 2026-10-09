import Foundation
import UIKit

/// Read the old presentation records. The original records and images stay intact.
enum IridiumImportPreferences {
    struct Appearance: Decodable {
        var title: String?
        var matchID: Int?
        var cover: String?
        var background: String?
        var favorite: Bool
    }
    struct Layout: Decodable {
        var version: Int
        var controls: [Control]
        struct Control: Decodable {
            var id: UUID
            var mapping: String
            var centerX, centerY, size, opacity: Double
            var isHidden: Bool
        }
    }
    static func appearances() throws -> [UUID: Appearance] {
        let file = URL.applicationSupportDirectory.appendingPathComponent("LibraryArtwork/library.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([UUID: Appearance].self, from: Data(contentsOf: file))
    }
    static func image(_ name: String) throws -> URL {
        let root = URL.applicationSupportDirectory.appendingPathComponent("LibraryArtwork").resolvingSymlinksInPath()
        let file = root.appendingPathComponent(name).resolvingSymlinksInPath()
        guard file.deletingLastPathComponent() == root else { throw IridiumLibraryImport.Failure.outsideFolder }
        return file
    }
    static func cover(for id: UUID) throws -> (Appearance?, String?) {
        let appearance = try appearances()[id]
        guard let name = appearance?.cover else { return (appearance, nil) }
        let source = try image(name)
        guard FileManager.default.fileExists(atPath: source.path) else { return (appearance, nil) }
        let directory = LibraryModel.documents.appendingPathComponent("madeira-art")
        let filename = "imported-" + id.uuidString + "." + source.pathExtension
        let target = directory.appendingPathComponent(filename)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(LibraryModel.documents.resolvingSymlinksInPath().path + "/") else {
            throw IridiumLibraryImport.Failure.outsideFolder
        }
        guard target.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
            throw IridiumLibraryImport.Failure.outsideFolder
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            guard FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) else { throw IridiumLibraryImport.Failure.conflictingGame }
        } else { try FileManager.default.copyItem(at: source, to: target) }
        return (appearance, filename)
    }
    @MainActor static func controls(for id: UUID, entry: inout LibraryEntry) throws {
        let defaults = UserDefaults.standard
        let enabled = "IridiumTouchControllerEnabled." + id.uuidString
        entry.touchControls = defaults.object(forKey: enabled) == nil
            ? defaults.bool(forKey: "IridiumTouchControlsDefaultEnabled") : defaults.bool(forKey: enabled)
        guard let data = defaults.data(forKey: "IridiumTouchControllerLayout." + id.uuidString) else { return }
        let layout = try JSONDecoder().decode(Layout.self, from: data)
        guard layout.version == 1 else { return }
        let names = ["leftStick": "LS", "rightStick": "RS", "a": "A", "b": "B", "x": "X", "y": "Y",
                     "leftBumper": "LB", "rightBumper": "RB", "leftTrigger": "LT", "rightTrigger": "RT",
                     "leftStickButton": "L3", "rightStickButton": "R3", "menu": "Menu", "view": "View"]
        let bounds = UIScreen.main.bounds
        let shortEdge = Double(min(bounds.width, bounds.height))
        entry.controls = layout.controls.filter { !$0.isHidden }.flatMap { old -> [TouchControl] in
            guard old.centerX.isFinite, old.centerY.isFinite, old.size.isFinite else { return [] }
            // Old sizes used the screen's short edge. Madeira stores a multiplier
            // of its 64-point control diameter, independent of runtime resolution.
            let scale = max(0.5, min(2, old.size * shortEdge / 64))
            let x = max(0.02, min(0.98, old.centerX)), y = max(0.02, min(0.98, old.centerY))
            if old.mapping == "dpad" {
                return [("D↑", 0.0, -0.03), ("D↓", 0.0, 0.03), ("D←", -0.03, 0.0), ("D→", 0.03, 0.0)].map {
                    TouchControl(nx: x + $0.1, ny: y + $0.2, scale: scale / 2, action: .pad($0.0))
                }
            }
            guard let name = names[old.mapping] else { return [] }
            return [TouchControl(id: old.id, nx: x, ny: y, scale: scale, action: .pad(name))]
        }
        let opacity = layout.controls.filter { !$0.isHidden && $0.opacity.isFinite }.map(\.opacity).min()
        entry.controlOpacity = opacity.map { max(0.15, min(1, $0)) }
    }
}
