// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum IridiumStikDebugRoute: String, CaseIterable, Identifiable {
    case standalone, livecontainer, livecontainer2, livecontainer3
    static let settingsKey = "iridium.jit.stikDebugRoute"
    static var current: Self { UserDefaults.standard.string(forKey: settingsKey).flatMap(Self.init(rawValue:)) ?? .standalone }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standalone: "Standalone"
        case .livecontainer: "LiveContainer"
        case .livecontainer2: "LiveContainer 2"
        case .livecontainer3: "LiveContainer 3"
        }
    }
    var unavailableMessage: String {
        self == .standalone ? "StikDebug was not detected. Install it or choose another JIT method." : "\(title) was not detected. Choose another route or install that container."
    }
    var probeURL: URL { URL(string: self == .standalone ? "stikdebug://enable-jit" : rawValue + "://open-url")! }
    func destination(for request: URL) -> URL? {
        guard ["stikdebug", "stikjit"].contains(request.scheme), request.host == "enable-jit" else { return nil }
        guard self != .standalone else { return request }
        var url = URLComponents(); url.scheme = rawValue; url.host = "open-url"
        url.queryItems = [URLQueryItem(name: "url", value: Data(request.absoluteString.utf8).base64EncodedString())]
        return url.url
    }
}
