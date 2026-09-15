import Foundation

enum MadeiraExternalJITRouting {
    static let liveContainer3Scheme = "livecontainer3"
    static let automaticRouteNames = ["livecontainer2", "stikdebug", "livecontainer"]
    static let automaticAttachGraceNanoseconds: UInt64 = 5_000_000_000

    static func shouldAdvanceAutomaticRoute(opened: Bool, returnedToApp: Bool, debugged: Bool) -> Bool {
        opened && returnedToApp && !debugged
    }

    static func liveContainerURL(for guestURL: URL, scheme: String) -> URL? {
        guard ["livecontainer", "livecontainer2", liveContainer3Scheme].contains(scheme) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open-url"
        components.queryItems = [
            URLQueryItem(
                name: "url",
                value: Data(guestURL.absoluteString.utf8).base64EncodedString()
            )
        ]
        return components.url
    }
}
