import Foundation
import MadeiraNative

// All mutable sampling state is confined to the timer's serial queue.
final class MadeiraCombatProfile: @unchecked Sendable {
    private let player: URL
    private let output: FileHandle
    private var reader: FileHandle?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var timer: DispatchSourceTimer?

    init(prefix: URL) throws {
        player = prefix.appendingPathComponent("drive_c/IridiumGame/Team Cherry/Hollow Knight/Player.log")
        let log = prefix.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iridium-combat-\(Int(Date().timeIntervalSince1970)).tsv")
        guard FileManager.default.createFile(atPath: log.path, contents: Data("uptime_s\tkind\tvalue\n".utf8)) else { throw CocoaError(.fileWriteUnknown) }
        output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        let queue = DispatchQueue(label: "iridium.combat-profile", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [self] in sample() }
        self.timer = timer
        iridium_profile_enable(1)
        timer.resume()
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = iridium_profile_take_gap()
        var lines = gap > 0 ? "\(now)\tframe_gap_ms\t\(Double(gap) / 1_000_000)\n" : ""
        do {
            if reader == nil {
                reader = try FileHandle(forReadingFrom: player)
                offset = try reader?.seekToEnd() ?? 0
            }
            guard let reader else { return }
            let size = try reader.seekToEnd()
            if size < offset { offset = 0; pending.removeAll(keepingCapacity: true) }
            try reader.seek(toOffset: offset)
            // Read small chunks; never block gameplay on a large startup log.
            let bytes = try reader.read(upToCount: 65536) ?? Data()
            offset += UInt64(bytes.count)
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let text = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                if text.contains("Object Pool attached") || text.hasPrefix("Total:") || text.contains("GC Warning:") {
                    lines += "\(now)\tgame_log_observed\t\(text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: ""))\n"
                }
            }
            if pending.count > 65536 { pending.removeAll(keepingCapacity: true) }
        } catch {
            // Player.log does not exist until Unity starts. Retry on the next tick.
        }
        if !lines.isEmpty { try? output.write(contentsOf: Data(lines.utf8)) }
    }
}
