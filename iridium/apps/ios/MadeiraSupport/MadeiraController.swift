import Foundation
import GameController
import UIKit

@MainActor
enum MadeiraController {
    private static var timer: Timer?
    private static var observers: [NSObjectProtocol] = []
    private static var statePath: URL?
    static var acceptingInput = true {
        didSet {
            guard acceptingInput != oldValue else { return }
            publishSnapshot(forceLog: true, reason: acceptingInput ? "input-resumed" : "input-paused")
        }
    }

    private struct TouchState {
        var active = false
        var buttons: UInt16 = 0
        var leftTrigger: Float = 0
        var rightTrigger: Float = 0
        var leftX: Float = 0
        var leftY: Float = 0
        var rightX: Float = 0
        var rightY: Float = 0
        var leftStickActive = false
        var rightStickActive = false

        mutating func releaseInputs() {
            buttons = 0
            leftTrigger = 0
            rightTrigger = 0
            leftX = 0
            leftY = 0
            rightX = 0
            rightY = 0
            leftStickActive = false
            rightStickActive = false
        }
    }

    private static var touch = TouchState()
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

    static func setTouchControlsActive(_ active: Bool) {
        guard touch.active != active else { return }
        touch.active = active
        if !active { touch.releaseInputs() }
        publishSnapshot(forceLog: true, reason: active ? "touch-connected" : "touch-disconnected")
    }

    static func setTouchButton(mask: UInt16, pressed: Bool) {
        guard touch.active else { return }
        if pressed {
            touch.buttons |= mask
        } else {
            touch.buttons &= ~mask
        }
        publishSnapshot()
    }

    static func setTouchTrigger(left: Bool, value: Float) {
        guard touch.active else { return }
        let clamped = max(0, min(1, value))
        if left { touch.leftTrigger = clamped }
        else { touch.rightTrigger = clamped }
        publishSnapshot()
    }

    static func setTouchStick(left: Bool, x: Float, y: Float, active: Bool) {
        guard touch.active else { return }
        let clampedX = max(-1, min(1, x))
        let clampedY = max(-1, min(1, y))
        if left {
            touch.leftX = active ? clampedX : 0
            touch.leftY = active ? clampedY : 0
            touch.leftStickActive = active
        } else {
            touch.rightX = active ? clampedX : 0
            touch.rightY = active ? clampedY : 0
            touch.rightStickActive = active
        }
        publishSnapshot()
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        touch.active = false
        touch.releaseInputs()
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
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
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
        func axis(_ value: Float) -> Int16 {
            let v = max(-1, min(1, value))
            return Int16(v * (v < 0 ? 32768 : 32767))
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

        let inputActive = acceptingInput && hostIsForegroundInteractive
        for index in 0..<4 {
            let connectedPad = slots[index]?.extendedGamepad
            let pad = inputActive ? connectedPad : nil
            let touchConnected = index == 0 && touch.active
            let touchInput = touchConnected && inputActive
            put(UInt32(connectedPad != nil || touchConnected ? 1 : 0))

            var buttons: UInt16 = touchInput ? touch.buttons : 0
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

            let physicalLT = max(0, min(1, pad?.leftTrigger.value ?? 0))
            let physicalRT = max(0, min(1, pad?.rightTrigger.value ?? 0))
            let mergedLT = max(physicalLT, touchInput ? touch.leftTrigger : 0)
            let mergedRT = max(physicalRT, touchInput ? touch.rightTrigger : 0)
            put(UInt8(mergedLT * 255))
            put(UInt8(mergedRT * 255))

            let leftX = touchInput && touch.leftStickActive ? touch.leftX : (pad?.leftThumbstick.xAxis.value ?? 0)
            let leftY = touchInput && touch.leftStickActive ? touch.leftY : (pad?.leftThumbstick.yAxis.value ?? 0)
            let rightX = touchInput && touch.rightStickActive ? touch.rightX : (pad?.rightThumbstick.xAxis.value ?? 0)
            let rightY = touchInput && touch.rightStickActive ? touch.rightY : (pad?.rightThumbstick.yAxis.value ?? 0)
            for value in [leftX, leftY, rightX, rightY] { put(axis(value)) }
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
                "[Launch] Controller bridge \(reason): detected=\(controllers.count), extended=\(extended), touch=\(touch.active), sceneActive=\(hostIsForegroundInteractive), accepting=\(acceptingInput)."
            )
        }
    }
}
