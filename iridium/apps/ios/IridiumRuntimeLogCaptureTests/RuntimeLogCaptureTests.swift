import Foundation
import Testing
@testable import IridiumRuntimeLogCapture

struct RuntimeLogCaptureTests {
    @Test
    func logFilesLiveAtSharedDocumentsRoot() {
        let documentsURL = URL(filePath: "/tmp/IridiumDocuments", directoryHint: .isDirectory)

        let destinations = RuntimeLogCapture.destinations(in: documentsURL)

        #expect(destinations.logFileURL == documentsURL.appending(path: "iridium-runtime.log"))
        #expect(destinations.previousLogFileURL == documentsURL.appending(path: "iridium-runtime.previous.log"))
        #expect(destinations.directoryURL == documentsURL)
    }
}

extension RuntimeLogCaptureTests {
    @Test
    func playerLogReadsExistingAndNewCompleteLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("madeira-log.txt")
        try Data("Wine started\nfile=/Users/person/private/game.exe\npartial".utf8).write(to: file)
        let first = RuntimeLogCapture.startupSummaries(offsets: [:], directory: directory)
        #expect(first.events == ["Wine started", "file=[redacted]"])
        let second = RuntimeLogCapture.startupSummaries(offsets: first.offsets, directory: directory)
        #expect(second.events.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" line\n".utf8))
        try handle.close()
        let third = RuntimeLogCapture.startupSummaries(offsets: second.offsets, directory: directory)
        #expect(third.events == ["partial line"])
        try Data("Restarted\n".utf8).write(to: file)
        #expect(RuntimeLogCapture.startupSummaries(offsets: third.offsets, directory: directory).events == ["Restarted"])
        #expect(RuntimeLogCapture.redactedPlayerLogLine("token=private") == "[Private log entry redacted]")
        #expect(!RuntimeLogCapture.redactedPlayerLogLine("user@example.com https://host/private 0x123abc").contains("example.com"))
    }
}

extension RuntimeLogCaptureTests {
    @Test
    func launchLogKeepsContextAndDropsRuntimeNoise() {
        #expect(RuntimeLogCapture.launchSummary("[Launch] Game files are ready.") == "Game files are ready.")
        #expect(RuntimeLogCapture.launchSummary("[IridiumMadeira] first-present") == "First game frame received.")
        #expect(RuntimeLogCapture.launchSummary("[IridiumMadeira] Wine launch failed.") != nil)
        #expect(RuntimeLogCapture.launchSummary("err: [mem-census] buffers=40") == nil)
    }
}
