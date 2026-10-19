"""Real UIKit host/menu and generated launch ordering in a dedicated simulator.

Set IRIDIUM_CHROME_SIMULATOR to a booted simulator. Native runtime execution is
replaced at the worker boundary; this does not reproduce an HL2/phone session.
"""
from pathlib import Path
import importlib.util
import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = 'db860fd0555488b497ca84a6bb3a1e629d960d22'


class WindowsChromeSourceTests(unittest.TestCase):
    def test_controller_producers_and_launch_admission_match_pinned_upstream(self):
        spec = importlib.util.spec_from_file_location('chrome_input_frontend', ROOT/'ci/madeira-frontend.py')
        frontend = importlib.util.module_from_spec(spec); spec.loader.exec_module(frontend)
        for name, relative in [('GamepadInput.swift', 'GamepadInput.swift'),
                               ('TouchGamepad.swift', 'TouchGamepad.swift'),
                               ('WiniosGamepad.c', 'Winios/WiniosGamepad.c')]:
            original = (frontend.UPSTREAM/'app/Madeira'/relative).read_text()
            self.assertEqual(frontend.overlay(name, original), original)
        original = (frontend.UPSTREAM/'app/Madeira/ContentView.swift').read_text()
        actual = frontend.overlay('ContentView.swift', original)
        start = '    private func runWineFullSequence('
        end = "            // A library entry's launch profile"
        guard = '        guard !IridiumConsoleSession.shared.isActive else { library.error = "Stop the console runtime first."; return }\n'
        settings_guard = '        guard TouchControlsModel.shared.iridiumSettingsContext == nil else {\n            LibraryModel.shared.error = "Finish editing controls before starting a game."\n            return\n        }\n'
        self.assertIn(settings_guard, actual[actual.index(start):actual.index(end)])
        self.assertEqual(actual[actual.index(start):actual.index(end)].replace(guard, '').replace(settings_guard, ''),
                         original[original.index(start):original.index(end)])

    def test_host_attachment_and_game_view_dismissal_match_pinned_upstream(self):
        spec = importlib.util.spec_from_file_location('chrome_source_frontend', ROOT/'ci/madeira-frontend.py')
        frontend = importlib.util.module_from_spec(spec); spec.loader.exec_module(frontend)
        for name, start, end in [('ContentView.swift', 'enum TouchControlsHost {', 'struct TouchControlsOverlay: View {'),
                                 ('Library.swift', '    func showGameView(reason:', '    /// The hotkey')]:
            before = (frontend.UPSTREAM/'app/Madeira'/name).read_text()
            after = frontend.overlay(name, before)
            # The next Library comment is pin-specific; compare the method alone.
            if name == 'Library.swift':
                a = before.index(start); b = before.index('\n    }', a)+6
                original = before[a:b]
                a = after.index(start); actual = after[a:after.index('\n    }', a)+6]
            else:
                original = before[before.index(start):before.index(end)]
                actual = after[after.index(start):after.index(end)]
            self.assertEqual(actual, original)


@unittest.skipUnless(platform.system() == 'Darwin' and os.environ.get('IRIDIUM_CHROME_SIMULATOR'), 'Dedicated UIKit simulator required')
class WindowsChromeLifecycleTests(unittest.TestCase):
    def test_generated_launch_order_and_real_host_menu_on_handoff(self):
        device = os.environ['IRIDIUM_CHROME_SIMULATOR']
        spec = importlib.util.spec_from_file_location('chrome_frontend', ROOT/'ci/madeira-frontend.py')
        frontend = importlib.util.module_from_spec(spec); spec.loader.exec_module(frontend)
        upstream = (frontend.UPSTREAM/'app/Madeira/ContentView.swift').read_text()
        current = frontend.overlay('ContentView.swift', upstream)
        menu = (frontend.FRONTEND/'IridiumPlayerMenu.swift').read_text()
        menu = menu[menu.index('struct IridiumPlayerMenuButton:'):menu.index('struct IridiumPlayerMenuHeader:')]
        wine = (frontend.UPSTREAM/'app/Madeira/Winios/Winios.m').read_text()
        start = wine.index('        UIWindow *win = nil;', wine.index('static void winios_ensure_compositor(void)'))
        pick = wine[start:wine.index('        if (!g_layers)', start)].replace('if (!win) return;', 'if (!win) return nil;')
        native = '#import <UIKit/UIKit.h>\nUIWindow *fixtureNativeSurface(void) {\n'+pick+'''
        UIView *surface=[[UIView alloc] initWithFrame:win.bounds];
        surface.backgroundColor=UIColor.blueColor;surface.userInteractionEnabled=NO;
        [win addSubview:surface];return win;
}
'''
        fixture = r'''
final class TouchControlsModel {
    static let shared=TouchControlsModel();var editing=false;var controls=Array(0..<18)
    var offersControllerInput:Bool {true}
    func hitsInteractive(_ p:CGPoint,in bounds:CGRect,topBar:Bool=true)->Bool {p.y>bounds.midY}
}
@MainActor final class IridiumConsoleSession {static let shared=IridiumConsoleSession();var isActive=false}
enum ControlPresetsModel {static let enabled=false}
final class LogStore {
    static let shared=LogStore();var uiPaused=false
    enum Level {case error}
    func log(_ line:String,level:Level?=nil) {}
}
enum MadeiraConfig {
    static let present=false
    static func all()->[String:String] {[:]}
    static func get(_ key:String)->String? {nil}
    static func migrateLegacy(_ log:(String)->Void) {}
    static func deleteLegacyFiles(_ log:(String)->Void) {}
}
struct LibraryEntry {}
final class SteamOwnedLibrary {static let shared=SteamOwnedLibrary();func sessionChanged(active:Bool) {}}
@MainActor enum DeviceDiagnostics {static var called=false;static func logLaunch() {called=true}}
func jit_check_debugged()->Bool {true}
var ws_log_quiet:Int32=0
@MainActor final class LibraryModel:ObservableObject {
    static let shared=LibraryModel();var current:UUID?=UUID()
    @Published var menu=false
    @Published var launching=true
    var error:String?,failed=false
    var performance=false,menuButtonRect=CGRect.zero,performanceRect=CGRect.zero
    func launchFailed(_ reason:String?=nil) {failed=true;error=reason}
}
final class GamepadInput:@unchecked Sendable {
    static let shared=GamepadInput();static let enabled=true,touchEnabled=true
    static func optIn(_ name:String)->Bool {false}
    let queue=DispatchQueue(label:"fixture.publisher")
    struct State {var reserved=false};var touchState=State()
    func sample() {}
    func beginPadSession() {}
    // The method below is extracted from the selected generated implementation.
    RESERVATION
}
@MainActor struct FixtureLaunch {
    let logStore=LogStore.shared
    let library=LibraryModel.shared
    // Everything through UI setup and worker admission is shipping source.
    LAUNCH
    func begin() {runWineFullSequence(profile:LibraryEntry())}
}
@MainActor enum FixtureState {static var pressed=0,workerEntered=false}
struct TouchControlsOverlay:View {
    @ObservedObject var library=LibraryModel.shared
    var body:some View {
        VStack {
            IridiumPlayerMenuButton {FixtureState.pressed+=1;library.menu=true}.frame(width:48,height:48)
            Spacer()
            if !library.launching && !library.menu {
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:6),spacing:12) {
                    ForEach(0..<18) {i in Text("\(i)").foregroundStyle(.white).frame(width:32,height:32).background(.gray,in:Circle())}
                }
            }
        }.padding(40).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.clear)
    }
}
extension TouchControlsHost {static var fixtureWindow:ControlsWindow {window!}}
@main final class FixtureApp:UIResponder,UIApplicationDelegate {
    func application(_ app:UIApplication,configurationForConnecting session:UISceneSession,options:UIScene.ConnectionOptions)->UISceneConfiguration {
        let c=UISceneConfiguration(name:"Fixture",sessionRole:session.role);c.delegateClass=FixtureScene.self;return c
    }
}
final class FixtureScene:UIResponder,UIWindowSceneDelegate {
    var window:UIWindow?;let launch=FixtureLaunch()
    var orderingRestored=false
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        let scene=scene as! UIWindowScene,w=UIWindow(windowScene:scene),root=UIViewController()
        root.view.backgroundColor = .gray;w.rootViewController=root;w.makeKeyAndVisible();window=w
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {self.check(w)}
    }
    private func descendants(_ view:UIView)->[UIView] {[view]+view.subviews.flatMap{descendants($0)}}
    private func check(_ main:UIWindow) {
        TouchControlsHost.attach();let controls=TouchControlsHost.fixtureWindow
        // Hold the serial publisher long enough to observe the caller's turn.
        GamepadInput.shared.queue.async {Thread.sleep(forTimeInterval:0.2)}
        let button=UIButton(type:.system)
        button.addAction(UIAction {_ in self.launch.begin()},for:.touchUpInside)
        button.sendActions(for:.touchUpInside)
        orderingRestored=DeviceDiagnostics.called && LogStore.shared.uiPaused && ws_log_quiet==1
        let baseline=ProcessInfo.processInfo.arguments.contains("baseline31")
        precondition(orderingRestored != baseline)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {
            precondition(FixtureState.workerEntered && GamepadInput.shared.touchState.reserved == baseline)
            precondition(DeviceDiagnostics.called && LogStore.shared.uiPaused)
            let selected=fixtureNativeSurface()!
            // Never force key ownership: upstream and build31 share that policy.
            precondition(selected===main && !controls.isKeyWindow && controls.windowLevel>main.windowLevel)
            LibraryModel.shared.launching=false
            self.checkMenu(main,controls,baseline:baseline)
        }
    }
    private func checkMenu(_ main:UIWindow,_ controls:ControlsWindow,baseline:Bool) {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            let identity=ObjectIdentifier(controls)
            TouchControlsHost.attach()
            precondition(ObjectIdentifier(TouchControlsHost.fixtureWindow)==identity)
            let root=controls.rootViewController!.view!
            precondition(!controls.isHidden && controls.alpha==1 && controls.windowScene===main.windowScene)
            precondition(controls.frame==main.windowScene!.coordinateSpace.bounds)
            let button=self.descendants(root).compactMap{$0 as? UIButton}.first{$0.accessibilityLabel=="Game menu"}!
            precondition(!button.isHidden && button.alpha>0 && button.window===controls)
            let point=button.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),to:controls)
            LibraryModel.shared.menuButtonRect=CGRect(x:point.x-24,y:point.y-24,width:48,height:48)
            let hit=controls.hitTest(point,with:nil)!
            precondition(hit===button || hit.isDescendant(of:button))
            button.sendActions(for:.touchUpInside);precondition(FixtureState.pressed==1 && LibraryModel.shared.menu)
            LibraryModel.shared.menu=false
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
            let image=UIGraphicsImageRenderer(bounds:controls.bounds).image {_ in controls.drawHierarchy(in:controls.bounds,afterScreenUpdates:true)}
            let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            try! image.pngData()!.write(to:folder.appendingPathComponent("overlay.png"))
            let result:[String:Any]=["variant":baseline ? "baseline31" : "fixed","synchronousUISetup":self.orderingRestored,
                "reservationObserved":GamepadInput.shared.touchState.reserved,"nativeRendererInMainWindow":true,"visibleHostAboveRenderer":true,
                "sameHostOnReattach":true,"menuHitTestAndAction":true,"controls":18,"gameOrPhoneExecution":false,
                "phoneDisappearanceReproduced":false]
            try! JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:folder.appendingPathComponent("RESULT.json"),options:.atomic)
            }
        }
    }
}
'''
        sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
        modules={}
        for name in ['startup','player']:
            path='ci/madeira_controller_startup.py' if name=='startup' else 'ci/madeira_player_presentation.py'
            module=types.ModuleType('baseline_'+name)
            exec(subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT,text=True),module.__dict__)
            modules[name]=module
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'native.m').write_text(native)
            (root/'Bridge.h').write_text('#import <UIKit/UIKit.h>\nUIWindow * _Nullable fixtureNativeSurface(void);\n')
            result=subprocess.run(['xcrun','clang','-target','arm64-apple-ios18.0-simulator','-isysroot',sdk,'-fobjc-arc','-c',str(root/'native.m'),'-o',str(root/'native.o')],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            for variant, baseline in [('baseline31',True),('fixed',False)]:
                bundle=root/(variant+'.app');bundle.mkdir()
                content=modules['startup'].apply('ContentView.swift',upstream) if baseline else current
                host_source=modules['player'].controls(upstream) if baseline else current
                a=host_source.index('final class ControlsWindow: UIWindow {')
                host=host_source[a:host_source.index('struct TouchControlsOverlay: View {',a)]
                pad_before=(frontend.UPSTREAM/'app/Madeira/GamepadInput.swift').read_text()
                if baseline:pad=modules['startup'].apply('GamepadInput.swift',pad_before)
                else:pad=frontend.overlay('GamepadInput.swift',pad_before)
                a=pad.index('    @MainActor func reserveSessionSlot(')
                reservation=pad[a:pad.index('\n    /// ml2100:',a)]
                a=content.index('    private func runWineFullSequence(')
                worker=content.index('        DispatchQueue.global(qos: .userInitiated).async {',a)
                boundary=content.index("            // A library entry's launch profile",worker)
                launch=content[a:boundary]+'''            DispatchQueue.main.async { FixtureState.workerEntered=true; heartbeat.invalidate() }
        }
    }
'''
                source=root/(variant+'.swift')
                source.write_text('import UIKit\nimport SwiftUI\nimport GameController\nimport os\n'+host+menu+fixture.replace('    RESERVATION',reservation).replace('    LAUNCH',launch))
                info={'CFBundleIdentifier':'dev.iridium.chrome-fixture.'+variant,'CFBundleExecutable':'Fixture','CFBundleName':'Fixture','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'18.0','UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{}}}
                (bundle/'Info.plist').write_bytes(plistlib.dumps(info))
                result=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target','arm64-apple-ios18.0-simulator','-sdk',sdk,'-module-cache-path',str(root/'cache'),'-import-objc-header',str(root/'Bridge.h'),str(source),str(root/'native.o'),'-framework','UIKit','-framework','SwiftUI','-o',str(bundle/'Fixture')],capture_output=True,text=True,timeout=90)
                self.assertEqual(result.returncode,0,result.stderr)
                try:
                    subprocess.run(['xcrun','simctl','install',device,str(bundle)],check=True,capture_output=True)
                    subprocess.run(['xcrun','simctl','launch',device,info['CFBundleIdentifier'],variant],check=True,capture_output=True)
                    container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,info['CFBundleIdentifier'],'data'],text=True).strip())
                    saved=container/'Documents/RESULT.json';deadline=time.monotonic()+15
                    while not saved.exists() and time.monotonic()<deadline:time.sleep(0.2)
                    self.assertTrue(saved.exists(),variant+' UIKit fixture did not finish')
                    result=json.loads(saved.read_text())
                    self.assertEqual(result['synchronousUISetup'],not baseline)
                    self.assertEqual(result['reservationObserved'],baseline)
                    for key in ['nativeRendererInMainWindow','visibleHostAboveRenderer','sameHostOnReattach','menuHitTestAndAction']:self.assertTrue(result[key],result)
                    if os.environ.get('IRIDIUM_CHROME_EVIDENCE'):
                        destination=Path(os.environ['IRIDIUM_CHROME_EVIDENCE'])/variant;destination.mkdir(parents=True,exist_ok=True)
                        for name in ['RESULT.json','overlay.png']:
                            if (container/'Documents'/name).exists():shutil.copy2(container/'Documents'/name,destination/name)
                        shutil.copy2(source,destination/'Fixture.swift')
                    print('UIKit '+variant+': '+json.dumps(result,sort_keys=True))
                finally:
                    subprocess.run(['xcrun','simctl','terminate',device,info['CFBundleIdentifier']],capture_output=True)
                    subprocess.run(['xcrun','simctl','uninstall',device,info['CFBundleIdentifier']],capture_output=True)


if __name__=='__main__':unittest.main()
