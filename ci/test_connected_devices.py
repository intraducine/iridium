"""Exercise the shared observer's real notification subscriptions and snapshots."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]

class ConnectedDeviceTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_connect_disconnect_updates_without_taking_input_handlers(self):
        source = (ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumPlayerControls.swift').read_text()
        code = source[source.index('struct IridiumConnectedDevice:'):source.index('enum IridiumControlShape')]
        fixture = r'''
import Foundation
import Combine
extension Notification.Name {
    static let GCControllerDidConnect = Self("controller-connect")
    static let GCControllerDidDisconnect = Self("controller-disconnect")
    static let GCKeyboardDidConnect = Self("keyboard-connect")
    static let GCKeyboardDidDisconnect = Self("keyboard-disconnect")
    static let GCMouseDidConnect = Self("mouse-connect")
    static let GCMouseDidDisconnect = Self("mouse-disconnect")
}
enum UIApplication { static let didBecomeActiveNotification = Notification.Name("active") }
final class GCController {
    static var values: [GCController] = []
    static func controllers() -> [GCController] { values }
    let vendorName: String?; let extendedGamepad: Bool?
    init(_ name: String?, gamepad: Bool) {vendorName=name;extendedGamepad=gamepad ? true : nil}
}
final class GCKeyboard { static var coalesced: GCKeyboard?; let vendorName: String? = nil }
final class GCMouse {
    static var values: [GCMouse] = []
    static func mice() -> [GCMouse] { values }
    let vendorName: String?
    init(_ name: String?) {vendorName=name}
}
func notify(_ name: Notification.Name) {
    NotificationCenter.default.post(name: name, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
'''
        cases = r'''
let observer = IridiumPhysicalController.shared
precondition(observer.connectedDevices.isEmpty && !observer.isActive)
GCController.values = [GCController("Test Controller",gamepad:true)]
notify(.GCControllerDidConnect)
precondition(observer.connectedDevices.map(\.name)==["Test Controller"] && observer.isActive)
let controllerID=observer.connectedDevices[0].id
observer.forceTouchVisible=true
GCKeyboard.coalesced=GCKeyboard();notify(.GCKeyboardDidConnect)
precondition(observer.connectedDevices.map(\.name)==["Test Controller","Keyboard"])
precondition(observer.forceTouchVisible && observer.connectedDevices[0].id==controllerID)
GCMouse.values=[GCMouse("USB Pointer"),GCMouse(nil)];notify(.GCMouseDidConnect)
precondition(observer.connectedDevices.map(\.name)==["Test Controller","Keyboard","USB Pointer","Mouse / Pointer"])
GCKeyboard.coalesced=nil;notify(.GCKeyboardDidDisconnect)
precondition(!observer.connectedDevices.contains{$0.symbol=="keyboard"} && observer.isActive)
GCMouse.values=[];notify(.GCMouseDidDisconnect)
precondition(observer.connectedDevices.count==1)
GCController.values=[];notify(.GCControllerDidDisconnect)
precondition(observer.connectedDevices.isEmpty && !observer.isActive && !observer.forceTouchVisible)
GCKeyboard.coalesced=GCKeyboard();notify(UIApplication.didBecomeActiveNotification)
precondition(observer.connectedDevices.count==1 && !observer.isActive)
print("PASS shared observer: controller/keyboard/pointer connect, disconnect, foreground refresh, stable identity and unchanged gamepad ownership")
'''
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder);main=folder/'main.swift';binary=folder/'check'
            main.write_text(fixture+code+cases)
            subprocess.run(['swiftc','-module-cache-path',str(folder/'cache'),str(main),'-o',str(binary)],check=True,timeout=60)
            subprocess.run([str(binary)],check=True,timeout=15)

if __name__=='__main__': unittest.main()
