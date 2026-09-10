import Foundation
import IridiumRuntime
import IridiumCore

@main
struct IridiumAcceptanceHarnessMain {
    static func main() async {
        do {
            let configuration = try parse(arguments: Array(CommandLine.arguments.dropFirst()))
            let report = try await AcceptanceHarnessService().run(configuration)

            if configuration.outputPath == nil {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else if let outputPath = configuration.outputPath {
                print("Wrote acceptance report to \(outputPath)")
            }
        } catch {
            fputs("IridiumAcceptanceHarness error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func parse(arguments: [String]) throws -> AcceptanceHarnessConfiguration {
        var title: String?
        var source: GameSource = .manualImport
        var installPath: String?
        var steamAppID: String?
        var executableOverridePath: String?
        var outputPath: String?

        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--title":
                title = iterator.next()
            case "--source":
                if let value = iterator.next(), let parsed = GameSource(rawValue: value) {
                    source = parsed
                } else {
                    throw AcceptanceHarnessArgumentError.invalidSource
                }
            case "--install-path":
                installPath = iterator.next()
            case "--app-id":
                steamAppID = iterator.next()
            case "--executable":
                executableOverridePath = iterator.next()
            case "--output":
                outputPath = iterator.next()
            case "--help":
                throw AcceptanceHarnessArgumentError.help
            default:
                throw AcceptanceHarnessArgumentError.unknownArgument(argument)
            }
        }

        guard let title, let installPath else {
            throw AcceptanceHarnessArgumentError.missingRequiredArguments
        }

        return AcceptanceHarnessConfiguration(
            title: title,
            source: source,
            installPath: installPath,
            steamAppID: steamAppID,
            executableOverridePath: executableOverridePath,
            outputPath: outputPath
        )
    }
}

enum AcceptanceHarnessArgumentError: Error, CustomStringConvertible {
    case missingRequiredArguments
    case invalidSource
    case unknownArgument(String)
    case help

    var description: String {
        switch self {
        case .missingRequiredArguments:
            return """
            Missing required arguments.
            Usage:
              swift run IridiumAcceptanceHarness --title <title> --install-path <path> [--source manualImport|steam] [--app-id <steam-app-id>] [--executable <path>] [--output <path>]
            """
        case .invalidSource:
            return "Invalid source. Use `manualImport` or `steam`."
        case let .unknownArgument(argument):
            return "Unknown argument: \(argument)"
        case .help:
            return """
            Usage:
              swift run IridiumAcceptanceHarness --title <title> --install-path <path> [--source manualImport|steam] [--app-id <steam-app-id>] [--executable <path>] [--output <path>]
            """
        }
    }
}
