import Foundation

private actor StartupGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func block() async {
        entered = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func open() { release?.resume(); release = nil }
}

@main struct SyncEngineCheck {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let native = CommandLine.arguments[1]
        let bridge = CommandLine.arguments[3]
        func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
            precondition(condition, file: file, line: line)
        }
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func put(_ text: String, _ name: String, _ docs: URL) throws {
            try Data(text.utf8).write(to: docs.appendingPathComponent(name))
        }
        func bytes(_ name: String, _ docs: URL) throws -> Data {
            try Data(contentsOf: docs.appendingPathComponent(name))
        }
        func run(_ binary: String, _ arguments: [String], status: Int32 = 0) throws -> Data {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            check(process.terminationStatus == status)
            return data
        }
        func probe(_ docs: URL, _ key: String? = nil) throws -> String {
            String(decoding: try run(native, [docs.path] + (key.map { [$0] } ?? [])), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
        }
        func bridgeValue(_ docs: URL, _ expected: String) throws {
            if !bridge.isEmpty { check(try run(bridge, [docs.path]) == Data(expected.utf8)) }
        }
        func checkNative(_ store: MadeiraSyncConfiguration) throws {
            let snapshot = try store.load()
            let expected = snapshot.engine == .madsync ? "0" : snapshot.engine == .fastsync ? "1" : "2"
            check(try probe(store.documents!) == expected)
        }
        func expectFailure(_ failure: MadeiraSyncConfiguration.Failure, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected \(failure)") }
            catch let actual as MadeiraSyncConfiguration.Failure { check(actual == failure) }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }

        let empty = try directory("empty"), store = MadeiraSyncConfiguration(documents: empty)
        let initial = try store.load()
        check(initial.engine == .fastsync && initial.fastsyncMode == "auto")
        check(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
        try checkNative(store)
        for mode in MadeiraSyncEngine.allCases {
            let saved = try store.save(mode)
            let reread = try store.load()
            check(saved.engine == mode && reread == saved)
            try checkNative(store)
        }
        print("PASS defaults, read-only load and all three mode round trips against native configuration")

        let parser = try directory("parser"), parsed = MadeiraSyncConfiguration(documents: parser)
        let cases: [(String, MadeiraSyncEngine, String?)] = [
            ("inproc-sync=1\nenv.MADEIRA_FASTSYNC=auto\n", .madsync, nil),
            ("inproc-sync=yes\nenv.MADEIRA_FASTSYNC=cells\n", .madsync, nil),
            ("inproc-sync=true\nenv.MADEIRA_FASTSYNC=0\n", .madsync, nil),
            ("inproc-sync=on\n", .madsync, nil),
            ("inproc-sync=0\n", .wine, nil),
            ("inproc-sync=0\nenv.MADEIRA_FASTSYNC=auto\n", .fastsync, "auto"),
            ("env.MADEIRA_FASTSYNC=cells\n", .fastsync, "cells"),
            ("env.MADEIRA_FASTSYNC=1\n", .fastsync, "on"),
            ("env.MADEIRA_FASTSYNC=on\n", .fastsync, "on"),
            ("env.MADEIRA_FASTSYNC=yes\n", .fastsync, "on"),
            ("env.MADEIRA_FASTSYNC=true\n", .wine, nil),
            ("inproc-sync=unknown\n", .wine, nil),
            ("inproc-sync=0\ninproc-sync=1\nenv.MADEIRA_FASTSYNC=0\n", .madsync, nil),
            ("\u{feff} # comment\r\n inproc-sync = 0 \r\n env.MADEIRA_FASTSYNC = cells \r\n", .fastsync, "cells"),
        ]
        for (text, mode, fast) in cases {
            try put(text, "madeira.cfg", parser)
            let read = try parsed.load()
            check(read.engine == mode && read.fastsyncMode == fast)
            check(try bytes("madeira.cfg", parser) == Data(text.utf8))
            try checkNative(parsed)
        }
        print("PASS native precedence, supported values, duplicate keys, BOM and CRLF")

        let overrides: [(String?, String?, String?, MadeiraSyncEngine, String?, String, String)] = [
            ("0\n", "MADEIRA_FASTSYNC=auto\n", nil, .fastsync, "auto", "2", "auto"),
            ("0\n", "MADEIRA_FASTSYNC=cells\n", nil, .fastsync, "cells", "2", "cells"),
            ("0\n", "MADEIRA_FASTSYNC=0\n", nil, .wine, nil, "2", "0"),
            (nil, "MADEIRA_FASTSYNC=0\n", nil, .wine, nil, "1", "0"),
            ("1\n", "MADEIRA_FASTSYNC=cells\n", nil, .madsync, nil, "0", "cells"),
            ("0\n", "MADEIRA_FASTSYNC=auto\nMADEIRA_FASTSYNC=cells\n", nil, .fastsync, "cells", "2", "cells"),
            ("0\n", "MADEIRA_FASTSYNC= auto\n", nil, .wine, nil, "2", " auto"),
            ("0\n", "MADEIRA_FASTSYNC =auto\n", nil, .wine, nil, "2", "<unset>"),
            (nil, nil, "cells\n", .fastsync, "auto", "1", "auto"),
            ("0\n", nil, nil, .wine, nil, "2", "<unset>"),
        ]
        for (inproc, env, perKey, engine, mode, selector, export) in overrides {
            let docs = try directory(UUID().uuidString), config = MadeiraSyncConfiguration(documents: docs)
            if let inproc { try put(inproc, "madeira-inproc-sync.txt", docs) }
            if let env { try put(env, "madeira-env.txt", docs) }
            if let perKey { try put(perKey, "madeira-env.MADEIRA_FASTSYNC.txt", docs) }
            let read = try config.load()
            check(read.engine == engine && read.fastsyncMode == mode)
            check(try probe(docs) == selector)
            try bridgeValue(docs, export)
            check(!FileManager.default.fileExists(atPath: docs.appendingPathComponent("madeira.cfg").path))
        }
        for (text, engine, export) in [
            ("inproc-sync=\r1\n", MadeiraSyncEngine.wine, "<unset>"),
            ("\rinproc-sync=1\n", .fastsync, "auto"),
            ("env.MADEIRA_FASTSYNC=\rauto\n", .wine, ""),
            ("inproc-sync=0\nenv.MADEIRA_FASTSYNC=\(String(repeating: "x", count: 40))\n", .wine, String(repeating: "x", count: 40)),
        ] {
            try put(text, "madeira.cfg", parser)
            check(try parsed.load().engine == engine)
            try bridgeValue(parser, export)
        }
        print("PASS legacy late exports, full client values and native leading-CR semantics against production readers")

        let preserved = try directory("preserved"), preservation = MadeiraSyncConfiguration(documents: preserved)
        let original = "\u{feff}# Keep this comment\r\npool = 512\r\nfuture-switch = unknown=a=b\r\ninvalid line stays\r\nenv.MADEIRA_FASTSYNC=future-mode\r\ninproc-sync=odd\r\ninproc-sync=0\r\n"
        try put(original, "madeira.cfg", preserved)
        let unknown = try preservation.load()
        check(unknown.engine == .wine && unknown.hasUnknownValue)
        check(try bytes("madeira.cfg", preserved) == Data(original.utf8))
        try put(original + "env.FEX_CUSTOM=keep=this\r\n", "madeira.cfg", preserved)
        for mode in MadeiraSyncEngine.allCases {
            _ = try preservation.save(mode)
            let changed = String(decoding: try bytes("madeira.cfg", preserved), as: UTF8.self)
            check(changed.hasPrefix("\u{feff}# Keep this comment\r\npool = 512\r\nfuture-switch = unknown=a=b\r\ninvalid line stays\r\n"))
            check(changed.contains("env.FEX_CUSTOM=keep=this\r\n"))
            check(changed.components(separatedBy: "\n").filter { $0.hasPrefix("inproc-sync=") }.count == 1)
            check(changed.components(separatedBy: "\n").filter { $0.hasPrefix("env.MADEIRA_FASTSYNC=") }.count == 1)
            check(try probe(preserved, "pool") == "512")
            check(try probe(preserved, "future-switch") == "unknown=a=b")
            try checkNative(preservation)
        }
        print("PASS unknown-value preservation on load and one-setting edits with save-time re-read")

        let legacy = try directory("legacy"), migration = MadeiraSyncConfiguration(documents: legacy)
        let old: [String: String] = [
            "madeira-inproc-sync.txt": "1\n", "madeira-pool.txt": " 640 \r\nignored second line",
            "madeira-future-switch.txt": "mystery=a=b\n", "madeira-env.txt": "\u{feff}# Keep environment\nFEX_X87REDUCEDPRECISION=1\nCUSTOM_TOKEN=a=b\nMADEIRA_FASTSYNC=cells\n",
            "madeira-dxmt.txt": "\u{feff}# Keep both options\ndxgi.maxFrameLatency=2\nd3d11.samplerAnisotropy=8\n",
            "madeira-log.txt": String(repeating: "log", count: 30_000),
        ]
        for (name, text) in old { try put(text, name, legacy) }
        check(try migration.load().engine == .madsync)
        check(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("madeira.cfg").path))
        _ = try migration.save(.fastsync)
        for (name, text) in old { check(try bytes(name, legacy) == Data(text.utf8)) }
        check(try probe(legacy, "pool") == "640")
        check(try probe(legacy, "future-switch") == "mystery=a=b")
        check(try probe(legacy, "env.FEX_X87REDUCEDPRECISION") == "1")
        check(try probe(legacy, "env.CUSTOM_TOKEN") == "a=b")
        check(try probe(legacy, "dxmt") == "dxgi.maxFrameLatency=2;d3d11.samplerAnisotropy=8")
        check(!String(decoding: try bytes("madeira.cfg", legacy), as: UTF8.self).contains("loglog"))
        try checkNative(migration)
        // Once cfg exists, even corrupt legacy files must remain ignored.
        try Data([0xff]).write(to: legacy.appendingPathComponent("madeira-pool.txt"))
        _ = try migration.save(.wine)
        check(try bytes("madeira-pool.txt", legacy) == Data([0xff]))
        print("PASS explicit legacy migration, unknown keys, environment/DXMT settings, retained files and ignored logs")

        for text in [" \t\(String(repeating: "x", count: 140)) \r\nignored", "\r1\nignored", "\u{feff}value\nignored",
                     String(repeating: "é", count: 80) + "\nignored", "first=a=b\nsecond", " \t \r\nsecond"] {
            let docs = try directory(UUID().uuidString), config = MadeiraSyncConfiguration(documents: docs)
            try put(text, "madeira-future-switch.txt", docs)
            let caps = [1, 2, 31, 32, 63, 64, 128, 1024]
            let before = try caps.map { try run(native, [docs.path, "future-switch", String($0)]) }
            _ = try config.save(.madsync)
            let after = try caps.map { try run(native, [docs.path, "future-switch", String($0)]) }
            check(before == after)
            check(try bytes("madeira-future-switch.txt", docs) == Data(text.utf8))
        }
        for key in [" future", "future=key", "#future", "\rfuture", "\u{feff}future"] {
            let docs = try directory(UUID().uuidString), config = MadeiraSyncConfiguration(documents: docs)
            let name = "madeira-\(key).txt"
            try put("value\n", name, docs)
            expectFailure(.unsupportedLegacy) { _ = try config.save(.madsync) }
            check(try bytes(name, docs) == Data("value\n".utf8))
            check(!FileManager.default.fileExists(atPath: docs.appendingPathComponent("madeira.cfg").path))
        }
        let tooLong = MadeiraSyncConfiguration(documents: URL(fileURLWithPath: "/" + String(repeating: "x", count: 959)))
        expectFailure(.directoryUnavailable) { _ = try tooLong.load() }
        expectFailure(.directoryUnavailable) { _ = try tooLong.save(.madsync) }
        var longDirectory = root
        while longDirectory.path.utf8.count < 950 {
            let count = min(200, 950 - longDirectory.path.utf8.count - 1)
            longDirectory.appendPathComponent(String(repeating: "x", count: count), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: longDirectory, withIntermediateDirectories: true)
        let longKey = String(repeating: "k", count: 60), longName = "madeira-\(longKey).txt"
        try put("value\n", longName, longDirectory)
        check(try run(native, [longDirectory.path, longKey], status: 2).isEmpty)
        expectFailure(.unsupportedLegacy) { _ = try MadeiraSyncConfiguration(documents: longDirectory).save(.madsync) }
        check(try bytes(longName, longDirectory) == Data("value\n".utf8))
        check(!FileManager.default.fileExists(atPath: longDirectory.appendingPathComponent("madeira.cfg").path))
        let boundary = try directory("boundary"), boundaryStore = MadeiraSyncConfiguration(documents: boundary)
        let full = Data(("#" + String(repeating: "x", count: 65_534)).utf8)
        try full.write(to: boundary.appendingPathComponent("madeira.cfg"))
        check(try boundaryStore.load().engine == .fastsync)
        expectFailure(.tooLarge) { _ = try boundaryStore.save(.madsync) }
        check(try bytes("madeira.cfg", boundary) == full)
        print("PASS native byte-buffer and first-line parity, unrepresentable keys and strict path/file bounds")

        for bad in [Data([0xff, 0xfe]), Data("pool=512\0inproc-sync=1".utf8), Data(repeating: 65, count: 65_536)] {
            let docs = try directory(UUID().uuidString), config = MadeiraSyncConfiguration(documents: docs)
            try bad.write(to: docs.appendingPathComponent("madeira.cfg"))
            let failure: MadeiraSyncConfiguration.Failure = bad.count > 65_535 ? .tooLarge : .invalidText
            expectFailure(failure) { _ = try config.load() }
            expectFailure(failure) { _ = try config.save(.madsync) }
            check(try bytes("madeira.cfg", docs) == bad)
        }
        let badLegacy = try directory("bad-legacy"), badMigration = MadeiraSyncConfiguration(documents: badLegacy)
        let bad = Data([0xff])
        try bad.write(to: badLegacy.appendingPathComponent("madeira-future-switch.txt"))
        expectFailure(.invalidText) { _ = try badMigration.save(.madsync) }
        check(try bytes("madeira-future-switch.txt", badLegacy) == bad)
        check(!FileManager.default.fileExists(atPath: badLegacy.appendingPathComponent("madeira.cfg").path))
        for env in ["NAME =value\n", "NAME= value\n", "MADEIRA_CFG_EARLY_DOCS=0\n"] {
            let docs = try directory(UUID().uuidString), config = MadeiraSyncConfiguration(documents: docs)
            try put(env, "madeira-env.txt", docs)
            expectFailure(.unsupportedLegacy) { _ = try config.save(.madsync) }
            check(try bytes("madeira-env.txt", docs) == Data(env.utf8))
            check(!FileManager.default.fileExists(atPath: docs.appendingPathComponent("madeira.cfg").path))
        }
        print("PASS corrupt, oversized and unsafe legacy migration failures preserve original bytes")

        let perEnvironment = try directory("per-environment")
        try put("value\n", "madeira-env.UNRELATED.txt", perEnvironment)
        expectFailure(.unsupportedLegacy) { _ = try MadeiraSyncConfiguration(documents: perEnvironment).save(.madsync) }
        check(try bytes("madeira-env.UNRELATED.txt", perEnvironment) == Data("value\n".utf8))
        check(!FileManager.default.fileExists(atPath: perEnvironment.appendingPathComponent("madeira.cfg").path))
        print("PASS migration cannot introduce unrelated environment exports")

        let denied = try directory("denied"), deniedStore = MadeiraSyncConfiguration(documents: denied)
        try put("pool=512\n", "madeira.cfg", denied)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: denied.path)
        expectFailure(.writeFailed) { _ = try deniedStore.save(.madsync) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
        check(try bytes("madeira.cfg", denied) == Data("pool=512\n".utf8))
        print("PASS failed atomic write leaves the previous configuration intact")

        let delayed = try directory("delayed-startup"), delayedStore = MadeiraSyncConfiguration(documents: delayed)
        let gate = StartupGate(), destination = delayed.appendingPathComponent("madeira.cfg")
        let delayedSave = Task {
            await delayedStore.saveAfterStartup(.madsync, startup: {
                precondition(!FileManager.default.fileExists(atPath: destination.path), "Write preceded startup capture")
                await gate.block()
                return delayedStore.readResult()
            })
        }
        await gate.waitForEntry()
        check(!FileManager.default.fileExists(atPath: destination.path))
        await gate.open()
        let outcome = await delayedSave.value
        guard case let .success(originalRequest) = outcome.startup, case let .success(delayedSaved) = outcome.saved else {
            preconditionFailure("Delayed startup/save failed")
        }
        check(originalRequest.engine == .fastsync && delayedSaved.engine == .madsync)
        check(delayedSaved.requiresRestart(from: originalRequest))
        print("PASS deterministic delayed startup cannot observe a subsequent save or clear the required restart")

        let session = try directory("session")
        setenv("MADEIRA_DOCS_DIR", session.path, 1)
        let environment = ProcessInfo.processInfo.environment
        guard case let .success(startup) = await MadeiraSyncSession.startup.value else { preconditionFailure("Startup read failed") }
        check(startup.engine == .fastsync && !MadeiraSyncSession.requiresRestart)
        let work = MadeiraSyncSession.save(.madsync)!
        check(MadeiraSyncSession.isSaving && MadeiraSyncSession.save(.wine) == nil)
        guard case let .success(saved) = await work.value else { preconditionFailure("Save failed") }
        check(saved.engine == .madsync && saved.requiresRestart(from: startup))
        check(!MadeiraSyncSession.isSaving && MadeiraSyncSession.requiresRestart)
        _ = await MadeiraSyncSession.save(.fastsync)!.value
        check(!MadeiraSyncSession.requiresRestart)
        check(ProcessInfo.processInfo.environment == environment)
        let reopened = try MadeiraSyncConfiguration(documents: session).load()
        check(!reopened.requiresRestart(from: reopened))
        let cells = MadeiraSyncConfiguration.Snapshot(engine: .fastsync, fastsyncMode: "cells", hasUnknownValue: false)
        check(reopened.requiresRestart(from: cells))
        print("PASS in-flight guard, restart state, restored selection, cold reload and no environment mutation")
    }
}
