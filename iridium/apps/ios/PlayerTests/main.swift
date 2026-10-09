// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

func close(_ a: CGFloat, _ b: CGFloat, _ message: String) { precondition(abs(a - b) < 0.001, message) }
let bounds = [
    CGRect(x: 0, y: 0, width: 667, height: 375),
    CGRect(x: 44, y: 0, width: 724, height: 354), // 812×375, landscape notch + home inset
    CGRect(x: 59, y: 0, width: 734, height: 372),
    CGRect(x: 0, y: 24, width: 1024, height: 722),
    CGRect(x: 0, y: 0, width: 320, height: 548),
    CGRect(x: 0, y: 59, width: 393, height: 759)
]
for profile in [IridiumPlayerProfile.psp, .gameBoy] {
    for available in bounds {
        let touch = IridiumPlayerLayout(profile: profile, bounds: available, touchVisible: true)
        let hardware = IridiumPlayerLayout(profile: profile, bounds: available, touchVisible: false)
        close(touch.viewport.width / touch.viewport.height, profile.aspectRatio, "Preserve native aspect")
        precondition(available.contains(touch.viewport), "Viewport must stay in safe bounds")
        precondition(available.contains(touch.dpad), "D-pad must stay in safe bounds")
        if let stick = touch.stick { precondition(available.contains(stick), "Stick must stay in safe bounds") }
        for button in touch.buttons {
            precondition(available.contains(button.frame), "\(button.id) must stay in safe bounds")
            precondition(button.frame.width >= 44 && button.frame.height >= 44, "Accessible hit target")
        }
        if available.width > available.height {
            precondition(touch.viewport == hardware.viewport, "Landscape touch controls must not shrink the viewport")
            precondition(abs(touch.viewport.width - available.width) < 0.001 || abs(touch.viewport.height - available.height) < 0.001,
                         "Landscape viewport must fill one available dimension")
        } else {
            precondition(hardware.viewport.height >= touch.viewport.height, "Hardware controller reclaims portrait control space")
        }
    }
}
let psp = IridiumPlayerLayout(profile: .psp, bounds: bounds[0], touchVisible: true)
let mapping = Dictionary(uniqueKeysWithValues: psp.buttons.map { ($0.id, $0.bit) })
precondition(mapping == ["Cross": 1, "Circle": 1 << 8, "Square": 1 << 1, "Triangle": 1 << 9,
                        "L": 1 << 10, "R": 1 << 11, "Start": 1 << 3, "Select": 1 << 2])
let gb = IridiumPlayerLayout(profile: .gameBoy, bounds: bounds[0], touchVisible: true)
precondition(gb.stick == nil && gb.buttons.count == 4, "No unsupported GB controls")
precondition(IridiumPlayerLayout.aspectFit(0, in: bounds[0]) == .zero)
precondition(IridiumPlayerLayout.aspectFit(.infinity, in: bounds[0]) == .zero)
precondition(IridiumPlayerLayout.aspectFit(1, in: .zero) == .zero)
precondition(IridiumControlGeometry.directionVector(-1) == .zero)
close(IridiumControlGeometry.directionVector(0).y, 1, "Keyboard stick up")
close(IridiumControlGeometry.directionVector(2).x, 1, "Keyboard stick right")
let size = CGSize(width: 132, height: 132)
precondition(IridiumControlGeometry.directions(location: CGPoint(x: 66, y: 66), size: size) == 0)
precondition(IridiumControlGeometry.directions(location: CGPoint(x: 5, y: 5), size: size) == (1 << 4 | 1 << 6))
precondition(IridiumControlGeometry.directions(location: CGPoint(x: 130, y: 66), size: size) == 1 << 7)
precondition(IridiumControlGeometry.directions(location: CGPoint(x: -1, y: 66), size: size) == 0)
let center = IridiumControlGeometry.stick(location: CGPoint(x: 44, y: 44), size: CGSize(width: 88, height: 88))
precondition(center == .zero)
let diagonal = IridiumControlGeometry.stick(location: CGPoint(x: 1000, y: -1000), size: CGSize(width: 88, height: 88))
close(hypot(diagonal.x, diagonal.y), 1, "Stick clamp stays unit-length")
precondition(diagonal.x > 0 && diagonal.y > 0, "Runtime stick Y is up-positive")
var press = IridiumControlPressState()
let resting = press.fillOpacity
precondition(press.set(true) && press.isDown && press.fillOpacity > resting && press.scale < 1, "Press feedback is immediate")
precondition(!press.set(true), "Repeated move must not add another edge")
precondition(press.set(false) && !press.isDown && press.fillOpacity == resting && press.scale == 1, "Cancel releases immediately")
precondition(!press.set(false), "Repeated cancellation is harmless")
let order = ["Resume", "Controls", "Help", "Close Game"]
precondition(IridiumPlayerMenuNavigation.next("Resume", order: order, command: "up") == "Resume")
precondition(IridiumPlayerMenuNavigation.next("Resume", order: order, command: "down") == "Controls")
precondition(IridiumPlayerMenuNavigation.next("Close Game", order: order, command: "down") == "Close Game")
precondition(IridiumPlayerMenuNavigation.next("Resume", order: [], command: "down") == "Resume")
print("Shared player geometry, control math, visual state, and menu navigation passed")

var confirmation = IridiumCloseConfirmation()
precondition(confirmation.selection == "Cancel", "Safe confirmation default")
precondition(confirmation.receive("accept") == .cancel, "Repeated accept cannot immediately close")
precondition(confirmation.receive("down") == .pending && confirmation.selection == "Close Game")
precondition(confirmation.receive("back") == .cancel, "Controller B always cancels")
precondition(confirmation.receive("menu") == .cancel, "Menu closes only the confirmation")
precondition(confirmation.receive("accept") == .close, "Explicit selection then accept confirms")
confirmation = IridiumCloseConfirmation()
precondition(confirmation.receive("up") == .pending && confirmation.selection == "Cancel")
let touchItems = IridiumPlayerMenuNavigation.touchControlItems(enabled: true, controller: true, overrideEnabled: false, includeSettings: true)
precondition(touchItems == ["Hide Touch Controls", "Use Touch Controls", "Control Settings"])
let overrideItem = IridiumPlayerMenuNavigation.next(touchItems[0], order: touchItems, command: "down")
precondition(overrideItem == "Use Touch Controls", "Controller can reach temporary override")
precondition(IridiumPlayerMenuNavigation.touchControlItems(enabled: true, controller: true, overrideEnabled: true)[1] == "Use Controller")
precondition(IridiumPlayerMenuNavigation.touchControlItems(enabled: false, controller: false, overrideEnabled: false) == ["Show Touch Controls"])
precondition(IridiumPlayerMenuNavigation.ownsCommands(page: "Controls", nativeEditor: false))
precondition(!IridiumPlayerMenuNavigation.ownsCommands(page: "Controls", nativeEditor: true), "Do not hijack controller binds/editor")
precondition(!IridiumPlayerMenuNavigation.ownsCommands(page: "Control Settings", nativeEditor: false), "Native settings retain text/key handling")
print("Confirmation and touch-input routing passed")

var directions = IridiumDirectionControlState()
var sentMasks: [UInt16] = []
for mask in [UInt16(1 << 7), UInt16(1 << 6), UInt16(1 << 6), 0] {
    if let update = directions.update(mask) { sentMasks.append(update) }
}
precondition(sentMasks == [1 << 7, 1 << 6, 0], "Right-to-left emits whole masks without a phantom opposite chord")
precondition(directions.bits == 0 && directions.update(0) == nil, "Cancellation is immediate and idempotent")
print("Atomic D-pad visual and input transitions passed")
