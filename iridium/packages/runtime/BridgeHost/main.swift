import Foundation
import IridiumRuntime

let arguments = Array(CommandLine.arguments.dropFirst())
let service = NativeBridgeService()

if arguments.contains("--watch") {
    let interval = watchInterval(from: arguments) ?? 2.0
    while true {
        do {
            let report = try await service.processAll()
            print("runtime=\(report.runtimeRequestsHandled) steam=\(report.steamRequestsHandled) at=\(report.generatedAt.ISO8601Format())")
        } catch {
            fputs("IridiumBridgeHost error: \(error)\n", stderr)
        }
        try? await Task.sleep(for: .seconds(interval))
    }
} else {
    do {
        let report = try await service.processAll()
        print("runtime=\(report.runtimeRequestsHandled) steam=\(report.steamRequestsHandled) at=\(report.generatedAt.ISO8601Format())")
    } catch {
        fputs("IridiumBridgeHost error: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

private func watchInterval(from arguments: [String]) -> Double? {
    guard let index = arguments.firstIndex(of: "--interval"),
          arguments.indices.contains(arguments.index(after: index)) else {
        return nil
    }
    return Double(arguments[arguments.index(after: index)])
}
