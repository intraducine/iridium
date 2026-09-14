import Foundation

enum MadeiraExternalJITRouting {
    static let liveContainer3Scheme = "livecontainer3"

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
