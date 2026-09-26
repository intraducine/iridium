import GameController
import UIKit
import MadeiraNative

@MainActor enum MadeiraHardwareInput {
    static var acceptingInput = false {
        didSet {
            if !acceptingInput {
                cancelSoftwareTaps()
                for key in held { winios_post_key(key, 0) }
                held.removeAll()
                pointerCaptured = false
            }
        }
    }

    private static var keyboardEvents = 0
    private static var keyboardDelivered = 0
    static func key(hid: Int, pressed: Bool) {
        keyboardEvents += 1
        guard acceptingInput, !softwareKeyboardActive, UIApplication.shared.applicationState == .active,
              let key = MadeiraKeys.virtualKey(hid: hid) else { return }
        let changed = pressed ? held.insert(key).inserted : held.remove(key) != nil
        if changed {
            if key == 0x14 && pressed { capsLockEnabled.toggle() }
            keyboardDelivered += 1
            winios_post_key(key, pressed ? 1 : 0)
        }
    }

    static var softwareKeyboardActive = false {
        didSet {
            if !softwareKeyboardActive { cancelSoftwareTaps() }
            guard softwareKeyboardActive, !oldValue else { return }
            for key in held { winios_post_key(key, 0) }
            held.removeAll()
            pointerCaptured = false
        }
    }
    private static var capsLockEnabled = false

    @discardableResult
    static func insertText(_ text: String) -> Bool {
        guard acceptingInput, UIApplication.shared.applicationState == .active else { return true }
        let mappings = text.map { MadeiraKeys.virtualKey(character: $0) }
        // Reject the entire insertion rather than silently dropping or substituting letters.
        guard mappings.allSatisfy({ $0 != nil }) else { return false }
        for mapping in mappings.compactMap({ $0 }) { tap(key: mapping.key, shift: mapping.shift) }
        return true
    }

    static func deleteBackward() {
        guard acceptingInput, UIApplication.shared.applicationState == .active else { return }
        tap(key: 0x08, shift: false)
    }

    private static var pendingTaps: [(key: Int32, shift: Bool)] = []
    private static var activeTap: (key: Int32, shift: Bool, restore: [Int32])?
    private static var tapRelease: DispatchWorkItem?

    private static func tap(key: Int32, shift: Bool) {
        keyboardEvents += 1
        pendingTaps.append((key, shift))
        sendNextTap()
    }

    private static func sendNextTap() {
        guard activeTap == nil, !pendingTaps.isEmpty else { return }
        let (key, shift) = pendingTaps.removeFirst()
        let modifiers: Set<Int32> = [0x10, 0x11, 0x12, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0x5b, 0x5c]
        let temporarilyReleased = held.intersection(modifiers.union([key])).sorted()
        for heldKey in temporarilyReleased { winios_post_key(heldKey, 0) }
        let effectiveShift = (0x41...0x5a).contains(key) ? (shift != capsLockEnabled) : shift
        if effectiveShift { winios_post_key(0x10, 1) }
        winios_post_key(key, 1)
        keyboardDelivered += 1
        activeTap = (key, effectiveShift, temporarilyReleased)
        let release = DispatchWorkItem {
            finishTap(restore: true)
            sendNextTap()
        }
        tapRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60), execute: release)
    }

    private static func finishTap(restore: Bool) {
        guard let activeTap else { return }
        tapRelease?.cancel()
        tapRelease = nil
        winios_post_key(activeTap.key, 0)
        if activeTap.shift { winios_post_key(0x10, 0) }
        if restore {
            for heldKey in activeTap.restore where held.contains(heldKey) { winios_post_key(heldKey, 1) }
        }
        self.activeTap = nil
    }

    private static func cancelSoftwareTaps() {
        pendingTaps.removeAll()
        finishTap(restore: false)
    }

    // Relative deltas and absolute UIKit locations must never drive the cursor together.
    static var usesRawMouse: Bool {
        acceptingInput && pointerCaptured && UIApplication.shared.applicationState == .active
            && !UIAccessibility.isAssistiveTouchRunning
    }

    static var pointerCaptured = false {
        didSet {
            if !pointerCaptured {
                mouseRemainderX = 0
                mouseRemainderY = 0
                scrollRemainder = 0
                for flag in heldMouse { winios_pointer(0, 0, flag << 1, 0) }
                heldMouse.removeAll()
            }
        }
    }
    static func mouseButton(flag: UInt32, pressed: Bool) {
        guard acceptingInput, UIApplication.shared.applicationState == .active else { return }
        let changed = pressed ? heldMouse.insert(flag).inserted : heldMouse.remove(flag) != nil
        if changed { winios_pointer(0, 0, pressed ? flag : flag << 1, 0) }
    }

    private static var mouseRemainderX = 0.0
    private static var mouseRemainderY = 0.0
    static func scaledMouseDelta(x: Float, y: Float) -> (Int32, Int32) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        let stored = UserDefaults.standard.object(forKey: "IridiumMouseSensitivity") as? Double ?? 1
        let sensitivity = stored.isFinite ? min(4, max(0.25, stored)) : 1
        let dx = min(Double(Int32.max), max(Double(Int32.min), Double(x) * sensitivity + mouseRemainderX))
        let dy = min(Double(Int32.max), max(Double(Int32.min), -Double(y) * sensitivity + mouseRemainderY))
        let outputX = Int32(dx.rounded(.towardZero))
        let outputY = Int32(dy.rounded(.towardZero))
        mouseRemainderX = dx - Double(outputX)
        mouseRemainderY = dy - Double(outputY)
        return (outputX, outputY)
    }

    private static var scrollRemainder = 0.0
    static func scaledScrollDelta(_ value: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        let stored = UserDefaults.standard.object(forKey: "IridiumScrollSensitivity") as? Double ?? 1
        let sensitivity = stored.isFinite ? min(4, max(0.25, stored)) : 1
        let delta = min(Double(Int32.max), max(Double(Int32.min), Double(value) * 120 * sensitivity + scrollRemainder))
        let output = Int32(delta.rounded(.towardZero))
        scrollRemainder = delta - Double(output)
        return output
    }

    private static var observers: [NSObjectProtocol] = []
    private static var keyboard: GCKeyboardInput?
    private static var mice: [GCMouse] = []
    private static var held = Set<Int32>()
    private static var heldMouse = Set<UInt32>()
    private static var loggedMouseMovement = false
    private static var loggedMouseButton = false
    private static var mouseProbe: Timer?
    private static var probeTicks = 0
    private static var mouseMoves = 0
    private static var mouseButtons = 0
    private static var polledChanges = 0
    private static var lastButtons: [Bool] = []

    static func start() {
        stop()
        for name: Notification.Name in [.GCKeyboardDidConnect, .GCKeyboardDidDisconnect,
                     .GCMouseDidConnect, .GCMouseDidDisconnect,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { bind() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { unbind() }
        })
        bind()
    }

    static func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        unbind()
    }

    private static func unbind() {
        cancelSoftwareTaps()
        if keyboardEvents > 0 {
            RuntimeLogCapture.writeLine("[Launch] Keyboard input: received=\(keyboardEvents), forwarded=\(keyboardDelivered), held=\(held.count).")
        }
        keyboardEvents = 0
        keyboardDelivered = 0
        mouseProbe?.invalidate()
        mouseProbe = nil
        keyboard?.keyChangedHandler = nil
        keyboard = nil
        for mouse in mice {
            mouse.mouseInput?.mouseMovedHandler = nil
            mouse.mouseInput?.leftButton.pressedChangedHandler = nil
            mouse.mouseInput?.rightButton?.pressedChangedHandler = nil
            mouse.mouseInput?.middleButton?.pressedChangedHandler = nil
            mouse.mouseInput?.scroll.valueChangedHandler = nil
        }
        mice = []
        for key in held { winios_post_key(key, 0) }
        held.removeAll()
        for flag in heldMouse { winios_pointer(0, 0, flag << 1, 0) }
        heldMouse.removeAll()
    }

    private static func bind() {
        unbind()
        guard UIApplication.shared.applicationState == .active else { return }
        keyboard = GCKeyboard.coalesced?.keyboardInput
        keyboard?.keyChangedHandler = { input, _, code, pressed in
            Task { @MainActor in
                guard keyboard === input else { return }
                key(hid: Int(code.rawValue), pressed: pressed)
            }
        }
        loggedMouseMovement = false
        loggedMouseButton = false
        probeTicks = 0
        mouseMoves = 0
        mouseButtons = 0
        polledChanges = 0
        lastButtons = []
        mice = GCMouse.mice()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = { _, x, y in
                Task { @MainActor in
                    mouseMoves += 1
                    if !loggedMouseMovement {
                        loggedMouseMovement = true
                        RuntimeLogCapture.writeLine("[Launch] Mouse movement callback received.")
                    }
                    guard usesRawMouse, mice.contains(where: { $0 === mouse }) else { return }
                    let (dx, dy) = scaledMouseDelta(x: x, y: y)
                    if dx != 0 || dy != 0 { winios_pointer(dx, dy, 0x0001, 0) }
                }
            }
            for (button, flag): (GCControllerButtonInput?, UInt32) in [(input.leftButton, 0x0002), (input.rightButton, 0x0008), (input.middleButton, 0x0020)] {
                button?.pressedChangedHandler = { _, _, pressed in
                    Task { @MainActor in
                        mouseButtons += 1
                        if !loggedMouseButton {
                            loggedMouseButton = true
                            RuntimeLogCapture.writeLine("[Launch] Mouse button callback received.")
                        }
                        guard usesRawMouse, mice.contains(where: { $0 === mouse }) else { return }
                        mouseButton(flag: flag, pressed: pressed)
                    }
                }
            }
            input.scroll.valueChangedHandler = { _, _, y in
                Task { @MainActor in
                    guard usesRawMouse, mice.contains(where: { $0 === mouse }) else { return }
                    let delta = scaledScrollDelta(y)
                    if delta != 0 { winios_pointer(0, 0, 0x0800, UInt32(bitPattern: delta)) }
                }
            }
        }
        if !mice.isEmpty || keyboard != nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated { pollMouse() }
            }
            mouseProbe = timer
            RunLoop.main.add(timer, forMode: .common)
            pollMouse()
        }
        RuntimeLogCapture.writeLine("[Launch] Hardware input ready: keyboard \(keyboard == nil ? "absent" : "connected"), mice \(mice.count).")
    }
    // Diagnostic only: never inject duplicate events. Hold buttons during testing;
    // clicks shorter than the 100 ms sample interval can be missed.
    private static func pollMouse() {
        let profiles = mice.compactMap { $0.mouseInput }
        let buttons = profiles.flatMap { input in
            [input.leftButton.isPressed, input.rightButton?.isPressed ?? false,
             input.middleButton?.isPressed ?? false]
        }
        if probeTicks > 0 && buttons != lastButtons { polledChanges += 1 }
        lastButtons = buttons
        if probeTicks % 50 == 0 {
            RuntimeLogCapture.writeLine("[Launch] Keyboard input: received=\(keyboardEvents), forwarded=\(keyboardDelivered), held=\(held.count).")
            let handlers = profiles.filter { $0.mouseMovedHandler != nil && $0.leftButton.pressedChangedHandler != nil }.count
            RuntimeLogCapture.writeLine("[Launch] Mouse probe: devices=\(mice.count), profiles=\(profiles.count), handlers=\(handlers), moveCallbacks=\(mouseMoves), buttonCallbacks=\(mouseButtons), polledChanges=\(polledChanges), heldButtons=\(buttons.filter { $0 }.count), active=\(UIApplication.shared.applicationState == .active).")
        }
        probeTicks += 1
    }

}
