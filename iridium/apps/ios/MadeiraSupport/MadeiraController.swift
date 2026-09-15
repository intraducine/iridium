import Foundation
import GameController
import UIKit

@MainActor
enum MadeiraController {
    private static var timer: Timer?
    private static var observers: [NSObjectProtocol] = []
    private static var statePath: URL?
    static var acceptingInput = true

    private static var previous = Data()
    private static var packet: UInt32 = 0
    private static var slots: [GCController?] = Array(repeating: nil, count: 4)

    private static var hostIsForegroundInteractive: Bool {
        let scenes = UIApplication.shared.connectedScenes
        if !scenes.isEmpty {
            return scenes.contains { $0.activationState == .foregroundActive }
        }
        return UIApplication.shared.applicationState == .active
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let path = statePath {
            // Four disconnected controller records, with a new sequence number.
            packet &+= 1
            var value = packet.littleEndian
            var neutral = Data()
            withUnsafeBytes(of: &value) { neutral.append(contentsOf: $0) }
            neutral.append(Data(repeating: 0, count: 64))
            do { try neutral.write(to: path, options: .atomic) }
            catch { NSLog("[IridiumController] Could not write disconnected state: %@", error.localizedDescription) }
        }
        statePath = nil
        previous = Data()
        slots = Array(repeating: nil, count: 4)
    }

    static func start(prefix: URL) {
        stop()
        previous = Data()
        let path = prefix.appendingPathComponent("drive_c/iridium-controller.bin")
        statePath = path

        for name: Notification.Name in [.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    publishSnapshot(forceLog: true, reason: name == .GCControllerDidConnect ? "connected" : "disconnected")
                }
            })
        }

        let pollTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { publishSnapshot() }
        }
        timer = pollTimer
        RunLoop.main.add(pollTimer, forMode: .common)
        publishSnapshot(forceLog: true, reason: "started")
    }

    private static func publishSnapshot(forceLog: Bool = false, reason: String = "poll") {
        guard let path = statePath else { return }

        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        let controllers = GCController.controllers()
        for i in slots.indices {
            if let controller = slots[i], !controllers.contains(where: { $0 === controller }) {
                slots[i] = nil
            }
        }
        for controller in controllers where !slots.contains(where: { $0 === controller }) {
            if let i = slots.firstIndex(where: { $0 == nil }) { slots[i] = controller }
        }

        for index in 0..<4 {
            let connectedPad = slots[index]?.extendedGamepad
            // LiveContainer can leave UIApplication.applicationState inactive even while
            // the Iridium scene is foreground-active. Gate input on scene activity so
            // hot-plugged controllers are not detected and then zeroed indefinitely.
            let pad = acceptingInput && hostIsForegroundInteractive ? connectedPad : nil
            put(UInt32(connectedPad == nil ? 0 : 1))
            var buttons: UInt16 = 0
            if let p = pad {
                let pairs: [(GCControllerButtonInput, UInt16)] = [
                    (p.dpad.up, 1), (p.dpad.down, 2), (p.dpad.left, 4), (p.dpad.right, 8),
                    (p.buttonMenu, 0x10), (p.leftShoulder, 0x100), (p.rightShoulder, 0x200),
                    (p.buttonA, 0x1000), (p.buttonB, 0x2000), (p.buttonX, 0x4000), (p.buttonY, 0x8000)]
                for (button, mask) in pairs where button.isPressed { buttons |= mask }
                if p.buttonOptions?.isPressed == true { buttons |= 0x20 }
                if p.leftThumbstickButton?.isPressed == true { buttons |= 0x40 }
                if p.rightThumbstickButton?.isPressed == true { buttons |= 0x80 }
            }
            put(buttons)
            put(UInt8(max(0, min(1, pad?.leftTrigger.value ?? 0)) * 255))
            put(UInt8(max(0, min(1, pad?.rightTrigger.value ?? 0)) * 255))
            for value in [pad?.leftThumbstick.xAxis.value, pad?.leftThumbstick.yAxis.value,
                          pad?.rightThumbstick.xAxis.value, pad?.rightThumbstick.yAxis.value] {
                let v = max(-1, min(1, value ?? 0))
                put(Int16(v * (v < 0 ? 32768 : 32767)))
            }
        }

        if data != previous {
            packet &+= 1
            var output = Data()
            var sequence = packet.littleEndian
            withUnsafeBytes(of: &sequence) { output.append(contentsOf: $0) }
            output.append(data)
            do {
                try output.write(to: path, options: .atomic)
                previous = data
            } catch {
                NSLog("[IridiumController] State write failed: %@", error.localizedDescription)
            }
        }

        if forceLog {
            let extended = controllers.filter { $0.extendedGamepad != nil }.count
            RuntimeLogCapture.writeLine(
                "[Launch] Controller bridge \(reason): detected=\(controllers.count), extended=\(extended), sceneActive=\(hostIsForegroundInteractive), accepting=\(acceptingInput)."
            )
        }
    }
}
