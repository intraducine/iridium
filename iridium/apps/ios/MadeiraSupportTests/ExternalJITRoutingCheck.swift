import Foundation

@main
struct ExternalJITRoutingCheck {
    static func main() {
        let guest = URL(string: "stikjit://enable-jit?script-data=a%2Bb%2Fc%3D")!
        for scheme in ["livecontainer", "livecontainer2", "livecontainer3"] {
            let wrapped = MadeiraExternalJITRouting.liveContainerURL(for: guest, scheme: scheme)!
            let components = URLComponents(url: wrapped, resolvingAgainstBaseURL: false)!
            let value = components.queryItems!.first { $0.name == "url" }!.value!
            let decoded = String(data: Data(base64Encoded: value)!, encoding: .utf8)!
            assert(wrapped.scheme == scheme)
            assert(wrapped.host == "open-url")
            assert(decoded == guest.absoluteString)
        }
        assert(MadeiraExternalJITRouting.liveContainer3Scheme == "livecontainer3")
        assert(MadeiraExternalJITRouting.liveContainerURL(for: guest, scheme: "https") == nil)
        print("External JIT LiveContainer routing passed")
    }
}
