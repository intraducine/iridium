"""Execute the shipping catalog decoder with large and ambiguous public metadata."""
from host_tests import module_cache
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'

STUBS = r'''
import Foundation
enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
struct SteamGame { let id: Int; let name: String }
@MainActor enum SteamCatalog {
    static func search(_ query: String) async throws -> [SteamGame] { [] }
    static func hero(_ id: Int) -> URL? { nil }
}
@MainActor final class SteamOwnedLibrary {
    static let shared = SteamOwnedLibrary()
    func game(_ id: Int) -> SteamGame? { nil }
}
@MainActor enum SteamGamesRules {
    static func artwork(appID: Int, owned: (Int) -> SteamGame?) -> [URL] { [] }
}
final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/libretro-thumbnails/fixture/") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, name = url.lastPathComponent
        let body: Data
        if name == "link.png" { body = Data("target.png".utf8) }
        else if name == "cycle.png" { body = Data("cycle.png".utf8) }
        else if name.hasPrefix("hop"), let hop = Int(name.dropFirst(3).dropLast(4)) {
            body = Data("hop\(hop + 1).png".utf8)
        } else { body = Data("image fixture".utf8) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Cache-Control": "no-store", "Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
'''

CHECKS = r'''
@main struct Checks {
    static func main() async throws {
        func tree(_ paths: [String], truncated: Bool = false, padding: String = "") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["truncated": truncated, "padding": padding,
                "tree": paths.map { ["path": $0, "type": "blob"] }])
        }
        func decode(_ data: Data) throws -> [IridiumArtworkCandidate] {
            try IridiumArtworkCatalog.decodeIndex(data, platform: .dreamcast, repository: "Sega_-_Dreamcast")
        }
        func reject(_ data: Data) {
            do { _ = try decode(data); fatalError("invalid catalog accepted") } catch { }
        }
        // The live PS2 catalog exceeds both old caps: 8 MiB and 30,000 paths.
        let large = try tree((0..<31_273).map { "Sample\($0).txt" }
            + ["Sample (USA).png"], padding: String(repeating: "x", count: 9 * 1024 * 1024))
        precondition(large.count > 8 * 1024 * 1024)
        let largeCandidates = try decode(large)
        precondition(largeCandidates.count == 1)
        reject(Data(repeating: 0, count: IridiumArtworkCatalog.maximumIndexBytes + 1))
        reject(try tree(["Sample.png"], truncated: true))
        reject(try tree(Array(repeating: "Sample.png", count: 100_001)))
        let sonic = "Sonic Adventure (Europe) (En,Ja,Fr,De,Es)"
        let candidates = try decode(tree([
            sonic + ".png",
            "Sonic Adventure (Europe)(En,Ja,Fr,De,Es).png",
            "Sonic Adventure (USA).png",
            "../escape.png", "back\\slash.png", "nested/escape.png"
        ]))
        precondition(candidates.count == 2)
        let result = IridiumArtworkMatcher.exactMatch("Sonic Adventure (Europe) (EnJaFrDeEs)",
            platform: .dreamcast, candidates: candidates)
        precondition(result?.title == sonic && result?.backgroundURL != nil)
        precondition(result?.coverURL?.host == "raw.githubusercontent.com")
        precondition(IridiumArtworkMatcher.exactMatch("Sonic Adventure", platform: .dreamcast, candidates: candidates) == nil)
        let directory = try JSONSerialization.data(withJSONObject: ["truncated":false,
            "tree":[["path":"Named_Boxarts","type":"tree","sha":String(repeating:"a",count:40)]]])
        let revision = try IridiumArtworkCatalog.boxartRevision(directory)
        precondition(revision == String(repeating:"a",count:40))
        for (sha, truncated) in [("../escape",false),(String(repeating:"a",count:40),true)] {
            let invalid = try JSONSerialization.data(withJSONObject: ["truncated":truncated,
                "tree":[["path":"Named_Boxarts","type":"tree","sha":sha]]])
            do { _ = try IridiumArtworkCatalog.boxartRevision(invalid); fatalError("unsafe or truncated directory accepted") } catch { }
        }
        let source = URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/fixture/master/Named_Boxarts/link.png")!
        precondition(IridiumArtworkCatalog.linkedImage(Data("target.png".utf8), source: source)?.lastPathComponent == "target.png")
        for unsafe in ["../escape.png", "/absolute.png", "https://example.invalid/private.png", "a\\b.png", "line\nbreak.png"] {
            precondition(IridiumArtworkCatalog.linkedImage(Data(unsafe.utf8), source: source) == nil)
        }
        precondition(IridiumArtworkCatalog.linkedImage(Data("target.png".utf8),
            source: URL(string: "https://api.github.com/fixture.png")!) == nil)
        precondition(URLProtocol.registerClass(ArtworkProtocol.self))
        let image = try await IridiumArtworkCatalog.data(source, limit: 100)
        precondition(image == Data("image fixture".utf8))
        for name in ["cycle.png", "hop0.png"] {
            do {
                _ = try await IridiumArtworkCatalog.data(source.deletingLastPathComponent().appendingPathComponent(name), limit: 100)
                fatalError("unbounded artwork link was accepted")
            } catch { }
        }
        do {
            _ = try await IridiumArtworkCatalog.data(source, limit: 3)
            fatalError("download limit was bypassed by an image link")
        } catch { }
        print("Large catalogs, duplicate names, safe image links, cycles and download limits passed")
    }
}
'''


class ArtworkCatalogTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_production_catalog_decoder(self):
        source = (IOS / 'MadeiraFrontend/IridiumArtwork.swift').read_text()
        catalog = source[source.index('@MainActor enum IridiumArtworkCatalog'):source.index('\nstruct IridiumArtworkImage')]
        with tempfile.TemporaryDirectory(prefix='iridium-artwork-catalog-') as folder:
            path = Path(folder)
            fixture = path / 'Checks.swift'
            fixture.write_text(STUBS + catalog + CHECKS)
            binary = path / 'check'
            subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                '-module-cache-path', module_cache('macosx'),
                str(IOS / 'RuntimeSupport/IridiumRuntime.swift'),
                str(IOS / 'MadeiraFrontend/IridiumArtworkState.swift'), str(fixture), '-o', str(binary)],
                check=True, timeout=120)
            subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
