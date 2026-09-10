import Foundation
import Darwin

enum RuntimeLogCapture {
    struct Destinations {
        let directoryURL: URL
        let logFileURL: URL
        let previousLogFileURL: URL
    }

    private static let maxLogSizeBytes: UInt64 = 4 * 1024 * 1024
    private static let directWriteLock = NSLock()
    nonisolated(unsafe) private static var activeLogFileURL: URL?
    nonisolated(unsafe) private static var installedTees: [StreamTee] = []

    static func install() -> URL? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let destinations = destinations(in: documentsURL)

        do {
            try FileManager.default.createDirectory(at: destinations.directoryURL, withIntermediateDirectories: true)
            try rotateLogIfNeeded(at: destinations.logFileURL, previousURL: destinations.previousLogFileURL)
            activeLogFileURL = destinations.logFileURL
        } catch {
            return nil
        }

        fflush(stdout)
        fflush(stderr)

        let logFileDescriptor = open(destinations.logFileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard logFileDescriptor >= 0 else {
            return destinations.logFileURL
        }

        var tees: [StreamTee] = []
        do {
            tees.append(try StreamTee.install(source: STDOUT_FILENO, logFileDescriptor: logFileDescriptor))
            tees.append(try StreamTee.install(source: STDERR_FILENO, logFileDescriptor: logFileDescriptor))
            installedTees = tees
        } catch {
            if tees.isEmpty {
                close(logFileDescriptor)
            } else {
                installedTees = tees
            }
            return destinations.logFileURL
        }

        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        return destinations.logFileURL
    }

    static func destinations(in documentsURL: URL) -> Destinations {
        Destinations(
            directoryURL: documentsURL,
            logFileURL: documentsURL.appending(path: "iridium-runtime.log"),
            previousLogFileURL: documentsURL.appending(path: "iridium-runtime.previous.log")
        )
    }

    static func writeLine(_ line: String) {
        guard let activeLogFileURL else {
            print(line)
            return
        }

        directWriteLock.lock()
        defer { directWriteLock.unlock() }

        let payload = line.hasSuffix("\n") ? line : "\(line)\n"
        guard let data = payload.data(using: .utf8) else {
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: activeLogFileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            print(line)
        }
    }

    // Read a bounded tail on first open, then append complete lines without replaying them.
    static func startupSummaries(offsets: [String: UInt64], directory: URL? = nil) -> (events: [String], offsets: [String: UInt64]) {
        guard let documents = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return ([], offsets) }
        var nextOffsets = offsets
        var result: [String] = []
        for name in ["iridium-runtime.log", "madeira-log.txt"] {
            guard let handle = try? FileHandle(forReadingFrom: documents.appendingPathComponent(name)) else { continue }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { continue }
            let previous = offsets[name] ?? (end > 65_536 ? end - 65_536 : 0)
            let start = previous <= end ? previous : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: 65_536) else { continue }
            // Leave an incomplete final line for the next read.
            let complete = data.lastIndex(of: 10).map { data.prefix(through: $0) } ?? Data()
            nextOffsets[name] = start + UInt64(complete.count)
            if complete.isEmpty && data.count == 65_536 { nextOffsets[name] = start + UInt64(data.count) }
            var lines = String(decoding: complete, as: UTF8.self).split(separator: "\n")
            if offsets[name] == nil && start > 0 && !lines.isEmpty { lines.removeFirst() }
            for line in lines {
                let clean = redactedPlayerLogLine(String(line))
                if !clean.isEmpty { result.append(clean) }
            }
        }
        return (result, nextOffsets)
    }

    static func launchSummary(_ line: String) -> String? {
        if let range = line.range(of: "[Launch] ") { return String(line[range.upperBound...]) }
        if line.contains("first-present") || line.contains("firstFrameObserved") {
            return "First game frame received."
        }
        if line.contains("[IridiumMadeira]"), line.contains("failed") || line.contains("Cannot") {
            return line
        }
        if line.contains("firstFrameTimeout") { return "No frame received yet. The game may still be loading." }
        return nil
    }

    static func redactedPlayerLogLine(_ line: String) -> String {
        // Fail closed for credential-bearing lines, including unfamiliar assignment formats.
        if line.range(of: #"(?i)token|password|passwd|secret|authorization|cookie|credential|api[_-]?key"#, options: .regularExpression) != nil {
            return "[Private log entry redacted]"
        }
        var clean = line
        for pattern in [
            #"(?i)https?://[^\s]+"#,
            #"(?i)[a-z]:[\\/][^\r\n]*"#,
            #"/[^\s]+"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
            #"(?i)\b(?:0x[0-9a-f]+|[0-9a-f]{12,})\b"#,
            #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]+)?\b"#
        ] {
            clean = clean.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        clean = clean.replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: "", options: .regularExpression)
        return String(clean.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rotateLogIfNeeded(at url: URL, previousURL: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= maxLogSizeBytes else {
            return
        }

        if FileManager.default.fileExists(atPath: previousURL.path) {
            try FileManager.default.removeItem(at: previousURL)
        }
        try FileManager.default.moveItem(at: url, to: previousURL)
    }
}

private final class StreamTee {
    private let originalDescriptor: Int32
    private let logFileDescriptor: Int32
    private let readDescriptor: Int32

    private init(originalDescriptor: Int32, logFileDescriptor: Int32, readDescriptor: Int32) {
        self.originalDescriptor = originalDescriptor
        self.logFileDescriptor = logFileDescriptor
        self.readDescriptor = readDescriptor
    }

    static func install(source: Int32, logFileDescriptor: Int32) throws -> StreamTee {
        let originalDescriptor = dup(source)
        guard originalDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        var pipeDescriptors: [Int32] = [0, 0]
        guard pipe(&pipeDescriptors) == 0 else {
            close(originalDescriptor)
            throw CocoaError(.fileWriteUnknown)
        }

        guard dup2(pipeDescriptors[1], source) >= 0 else {
            close(originalDescriptor)
            close(pipeDescriptors[0])
            close(pipeDescriptors[1])
            throw CocoaError(.fileWriteUnknown)
        }

        close(pipeDescriptors[1])

        let tee = StreamTee(
            originalDescriptor: originalDescriptor,
            logFileDescriptor: logFileDescriptor,
            readDescriptor: pipeDescriptors[0]
        )
        tee.start()
        return tee
    }

    private func start() {
        Thread.detachNewThread { [originalDescriptor, logFileDescriptor, readDescriptor] in
            var buffer = [UInt8](repeating: 0, count: 4096)

            while true {
                let bytesRead = read(readDescriptor, &buffer, buffer.count)
                guard bytesRead > 0 else {
                    break
                }

                buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return
                    }

                    writeAll(to: originalDescriptor, from: baseAddress, byteCount: bytesRead)
                    writeAll(to: logFileDescriptor, from: baseAddress, byteCount: bytesRead)
                }
            }

            close(readDescriptor)
            close(originalDescriptor)
        }
    }
}

private func writeAll(to descriptor: Int32, from baseAddress: UnsafeRawPointer, byteCount: Int) {
    var bytesWritten = 0

    while bytesWritten < byteCount {
        let result = write(
            descriptor,
            baseAddress.advanced(by: bytesWritten),
            byteCount - bytesWritten
        )

        guard result > 0 else {
            return
        }

        bytesWritten += result
    }
}
