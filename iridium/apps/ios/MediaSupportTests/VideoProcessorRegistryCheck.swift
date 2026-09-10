import Foundation

@main struct VideoProcessorRegistryCheck {
    static func main() throws {
        let entries = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let original = "WINE REGISTRY Version 2\n\n[Unrelated] 123\n@=\"preserved\"\n"
        let installed = MadeiraMediaInstall.addingMissingSections(entries, to: original)
        precondition(installed.hasPrefix(original))
        precondition(installed.contains("msvproc.dll"))
        precondition(installed.contains("\"InputTypes\"=hex:"))
        precondition(installed.contains("\"OutputTypes\"=hex:"))
        precondition(MadeiraMediaInstall.addingMissingSections(entries, to: installed) == installed)
        let rewritten = installed.replacingOccurrences(of: "]\n", with: "] 123\n")
        precondition(MadeiraMediaInstall.addingMissingSections(entries, to: rewritten) == rewritten)
        print("Processor registry: preserves existing keys; repeated installs are stable")
    }
}
