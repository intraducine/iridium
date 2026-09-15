import Foundation

/// A JSON array is transported, never a shell command or a space-split string.
enum MadeiraLaunchArguments {
    static let maximumCount = 256
    static let maximumBytes = 65_536
    static func encode(_ arguments: [String]) throws -> String {
        guard arguments.count <= maximumCount,
              arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try JSONEncoder().encode(arguments)
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }
}
