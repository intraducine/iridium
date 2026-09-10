import GameController
import UIKit
import MadeiraNative

@MainActor enum MadeiraHardwareInput {
    static var pointerCaptured = false {
        didSet {
            if !pointerCaptured {
                for flag in heldMouse { winios_pointer(0, 0, flag << 1, 0) }
                heldMouse.removeAll()
            }
        }
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
        keyboard?.keyChangedHandler = { _, _, code, pressed in
            Task { @MainActor in
                guard let key = MadeiraKeys.virtualKey(hid: Int(code.rawValue)) else { return }
                if pressed { held.insert(key) } else { held.remove(key) }
                winios_post_key(key, pressed ? 1 : 0)
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
                    guard pointerCaptured else { return }
                    winios_pointer(Int32(x.rounded()), Int32(-y.rounded()), 0x0001, 0)
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
                        guard pointerCaptured else { return }
                        if pressed { heldMouse.insert(flag) } else { heldMouse.remove(flag) }
                        winios_pointer(0, 0, pressed ? flag : flag << 1, 0)
                    }
                }
            }
            input.scroll.valueChangedHandler = { _, _, y in
                Task { @MainActor in
                    guard pointerCaptured else { return }
                    winios_pointer(0, 0, 0x0800, UInt32(bitPattern: Int32((y * 120).rounded())))
                }
            }
        }
        if !mice.isEmpty {
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
            let handlers = profiles.filter { $0.mouseMovedHandler != nil && $0.leftButton.pressedChangedHandler != nil }.count
            RuntimeLogCapture.writeLine("[Launch] Mouse probe: devices=\(mice.count), profiles=\(profiles.count), handlers=\(handlers), moveCallbacks=\(mouseMoves), buttonCallbacks=\(mouseButtons), polledChanges=\(polledChanges), heldButtons=\(buttons.filter { $0 }.count), active=\(UIApplication.shared.applicationState == .active).")
        }
        probeTicks += 1
    }

}
