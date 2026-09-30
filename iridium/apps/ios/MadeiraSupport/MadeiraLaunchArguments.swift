import Foundation

/// A JSON array is transported, never a shell command or a space-split string.
enum MadeiraLaunchArguments {
    static let maximumCount = 256
    static let maximumBytes = 65_536
    // Windows argv quoting for CreateProcessW. This is not shell escaping.
    static func windowsCommandLine(executable: String, arguments: [String]) throws -> String {
        _ = try encode(arguments)
        let command = ([executable] + arguments).map(quoteWindowsArgument).joined(separator: " ")
        guard !executable.contains("\0"), command.utf16.count < 32_767 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return command
    }

    static func quoteWindowsArgument(_ argument: String) -> String {
        var result = "\"", slashes = 0
        for character in argument {
            if character == "\\" { slashes += 1; continue }
            result += String(repeating: "\\", count: character == "\"" ? slashes * 2 + 1 : slashes)
            result.append(character)
            slashes = 0
        }
        return result + String(repeating: "\\", count: slashes * 2) + "\""
    }

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
