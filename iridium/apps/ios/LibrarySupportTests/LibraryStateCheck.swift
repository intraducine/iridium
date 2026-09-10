import Foundation
import UIKit

@main struct LibraryStateCheck {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iridium-state-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryArtwork(root: root, testCredential: "")
        let id = UUID()
        try store.update(id) { $0.title = "Private prototype"; $0.matchID = 12; $0.matchName = "Wrong title" }
        let data = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try store.setImage(data, id: id, background: false)
        try store.setImage(data, id: id, background: true)
        try store.removeMatch(id)
        let reopened = LibraryArtwork(root: root, testCredential: "")
        let item = reopened.appearance(id)
        precondition(item.title == "Private prototype" && item.matchID == nil && !item.automaticLookup)
        precondition(item.customCover && item.customBackground)
        precondition(reopened.image(item.cover) != nil && reopened.image(item.background) != nil)
        do { try reopened.setImage(Data("invalid".utf8), id: id, background: false); fatalError("Invalid image was accepted") } catch {}
        precondition(reopened.appearance(id) == item)
        try reopened.update(id) { $0.title = nil }
        precondition(LibraryArtwork(root: root, testCredential: "").appearance(id).title == nil)
        precondition(LibraryArtwork.query("C:\\private\\My_Game.exe") == "My Game")
        let file = root.appendingPathComponent("library.json")
        let original = Data("invalid JSON".utf8)
        try original.write(to: file)
        let corrupt = LibraryArtwork(root: root, testCredential: "")
        do { try corrupt.update(id) { $0.title = "overwrite" }; fatalError("Invalid metadata was overwritten") } catch {}
        let preserved = try Data(contentsOf: file)
        precondition(preserved == original)
        print("PASS: custom images, offline reload, match removal, restored name, invalid image preservation, private query cleanup, corrupt metadata preservation")
    }
}
