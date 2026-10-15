"""Execute shipping touch-cursor policy and live guest-to-host projection."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import madeira_player_presentation as presentation

ROOT=Path(__file__).resolve().parents[1]


def block(source, anchor):
    start=source.index(anchor);position=source.index('{',start)+1;depth=1
    while depth:
        depth+=(source[position]=='{')-(source[position]=='}');position+=1
    return source[start:position].replace('private ', '')


class TrackpadCursorTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_production_policy_and_live_resolution_projection(self):
        source=presentation.hardware_cursor((ROOT/'vendor/Madeira/app/Madeira/HardwareInput.swift').read_text())
        actual='\n'.join(block(source,a) for a in ('    private var iridiumTrackpadActive:',
            '    private var iridiumStickCursorActive:', '    private func updateTracking()',
            '    private func renderCursor()', '    private func updateFocusTimer()',
            '    private func setMouseInUse(', '    func stickMoved()', '    private func evaluateFocus(', '    private func moved('))
        callback=block(source, '        m.mouseMovedHandler =')
        policy='\n'.join(block(source,a) for a in ['enum PointerRoute:', 'enum PointerPolicy {'])
        code=r'''import Foundation
import CoreGraphics
enum IridiumTouchMouseMode {case off,trackpad,direct;static var mode=Self.trackpad;static func current()->Self{mode}}
enum TouchMouseGate {enum Mode{case off,on};static var mode=Mode.on}
final class LibraryModel {static let shared=LibraryModel();var current:Int?=1;var blocksGameplayTouch=false}
final class TouchControlsModel {static let shared=TouchControlsModel();var editing=false}
final class IridiumConsoleSession {static let shared=IridiumConsoleSession();var isActive=false}
final class PadStickMouse {static let shared=PadStickMouse();var controllerConnected=false}
var tracking:Int32 = -1
func winios_direct_cursor_track(_ value:Int32){tracking=value}
final class DirectCursorOverlay {
 static let shared=DirectCursorOverlay();var visible=false,fallback=false;var point=(x:Int32(0),y:Int32(0))
 func render(visible:Bool,x:Int32,y:Int32,fallback:Bool){self.visible=visible;self.fallback=fallback;point=(x,y)}
}
PROJECTION
POINTER_POLICY
func CACurrentMediaTime()->Double {ProcessInfo.processInfo.systemUptime}
final class GCMouseInputProbe {
 var mouseMovedHandler: ((GCMouseInputProbe,Float,Float)->Void)?
}
final class Probe {
 static let enabled=true
 static let focusEnabled=true
 typealias Route=PointerRoute
 var appActive=true,directCursorLive=true,mouseInUse=false,baseFocused=true,mouseFocused=false
 var iridiumStickCursorOwned=false,mouseInUseMirror=false
 var gcDeltaLive=false,lastGCDeltaAt=0.0,absoluteAllowed=true
 var route=Route.relative,firstGCDeltas=0,relativeMoves=0
 let mouseQueue=DispatchQueue(label:"cursor-test.mouse")
 func logRaw(_ path:String,_ dx:Double,_ dy:Double){};func noteDelivery(_ now:Double){}
 func postMotion(_ dx:Double,_ dy:Double){relativeMoves+=1}
 func firstGCDelta(){firstGCDeltas+=1}
 func installGCMovement(_ m:GCMouseInputProbe) { GC_MOVEMENT_CALLBACK }
 // The exact pin initializes iPad hover this way, before any pointer enters.
 var hoverSeen=true,pointerOver=false,pointerLocked=false,keyboardFocused=false,diagnostics=false
 var clickFocus=(onGame:true,unused:false)
 var gameButtons=Set<Int>(),pendingButtons=[Int:Int]()
 struct Resettable {func reset(){};func focusLost(){}}
 var keys=Resettable(),carry=Resettable(),wheel=Resettable();let motionLock=NSLock()
 var keyboardConnected=false,mouseConnected=false;var focusTimer:Timer?
 var currentRoute=Route.relative;var cursorState=(shown:Int32(1),x:Int32(712),y:Int32(328))
 var lastAbsolute:(x:Int32,y:Int32)?=(999,998)
 func refreshFocus(_ why:String){}
 func installTouchObserver(){};func typingElsewhere()->Bool{false}
 func computeBaseFocus()->Bool {appActive && LibraryModel.shared.current != nil && !LibraryModel.shared.blocksGameplayTouch && !TouchControlsModel.shared.editing && !IridiumConsoleSession.shared.isActive}
 func syncKeys(){};func syncButtons(){};func log(_ text:String){}
 func updateRoute(){
  currentRoute=PointerPolicy.route(focused:mouseFocused,hover:hoverSeen,locked:pointerLocked,
    cursorShown:cursorState.shown != 0,absoluteAllowed:absoluteAllowed)
  motionLock.lock();route=currentRoute;motionLock.unlock()
 }
 func updateAutoLock(){}
 ACTUAL
}
let p=Probe(),overlay=DirectCursorOverlay.shared
func check(_ visible:Bool,_ tracked:Int32,_ why:String){p.updateTracking();p.renderCursor();precondition(overlay.visible==visible,why);precondition(tracking==tracked,why)}
check(true,1,"trackpad works without hardware mouse focus")
precondition(overlay.point.x==712 && overlay.point.y==328)
p.updateFocusTimer();precondition(p.focusTimer != nil,"trackpad keeps focus fresh without hardware")
p.cursorState.shown=0;check(true,1,"explicit trackpad retains a visible pointer when the program hides its cursor");precondition(overlay.fallback)
p.mouseInUse=true;p.mouseFocused=true;check(false,1,"active hardware retains program visibility with the default trackpad preference");precondition(!overlay.fallback)
p.cursorState.shown=1;check(true,1,"active hardware keeps its absolute position");precondition(overlay.point.x==999)
p.mouseInUse=false;p.mouseFocused=false;p.cursorState.shown=0;check(true,1,"accepted touch returns ownership to trackpad");precondition(overlay.fallback && overlay.point.x==712)
p.cursorState.shown=1;p.baseFocused=false;check(false,0,"focus lost");p.baseFocused=true
p.appActive=false;check(false,0,"background");p.updateFocusTimer();precondition(p.focusTimer==nil);p.appActive=true
LibraryModel.shared.blocksGameplayTouch=true;check(false,0,"menu");LibraryModel.shared.blocksGameplayTouch=false
TouchControlsModel.shared.editing=true;check(false,0,"editor");TouchControlsModel.shared.editing=false
IridiumConsoleSession.shared.isActive=true;check(false,0,"console");IridiumConsoleSession.shared.isActive=false
LibraryModel.shared.current=nil;check(false,0,"no game");LibraryModel.shared.current=1
TouchMouseGate.mode = .off;check(false,0,"environment off");TouchMouseGate.mode = .on
IridiumTouchMouseMode.mode = .direct;check(false,0,"direct mode")
IridiumTouchMouseMode.mode = .off;check(false,0,"off mode")
p.mouseInUse=true;p.mouseFocused=true;check(true,1,"hardware coexists");precondition(overlay.point.x==999)
p.cursorState.shown=0;check(false,1,"hardware still respects program visibility")
// Execute the actual pinned focus decision and stickMoved/setMouseInUse
// transition, including ownership changes while mouseInUse is already true.
IridiumTouchMouseMode.mode = .trackpad;p.setMouseInUse(false)
p.lastAbsolute=(999,998);p.cursorState.shown=1;p.evaluateFocus("iPad initial focus")
precondition(p.baseFocused && !p.mouseFocused,"iPad hoverSeen=true/pointerOver=false must leave physical mouse unfocused")
p.stickMoved();precondition(overlay.visible && !overlay.fallback && tracking==1)
precondition(p.iridiumStickCursorOwned && p.lastAbsolute==nil && overlay.point.x==712)
p.evaluateFocus("controller after focus poll");precondition(overlay.visible && !p.mouseFocused)
p.cursorState.shown=0;p.evaluateFocus("controller program hidden");precondition(!overlay.visible && !overlay.fallback)
p.cursorState.shown=1;LibraryModel.shared.blocksGameplayTouch=true;p.evaluateFocus("controller menu")
precondition(!p.baseFocused && !overlay.visible);LibraryModel.shared.blocksGameplayTouch=false
p.evaluateFocus("controller resume");precondition(overlay.visible && !p.mouseFocused)
p.setMouseInUse(true);precondition(!p.iridiumStickCursorOwned && !overlay.visible,"hardware takes ownership even when the activity Boolean stays true")
p.pointerOver=true;p.evaluateFocus("hardware hover");precondition(p.mouseFocused && overlay.visible)
p.cursorState.shown=0;p.evaluateFocus("hardware program hidden");precondition(!overlay.visible && !overlay.fallback)
p.cursorState.shown=1;p.pointerOver=false;p.evaluateFocus("hardware left")
for mode in [IridiumTouchMouseMode.off,.direct] {
 IridiumTouchMouseMode.mode=mode;p.stickMoved();p.evaluateFocus("controller independent of touch mode")
 precondition(overlay.visible && !overlay.fallback && !p.mouseFocused)
}
IridiumTouchMouseMode.mode = .trackpad;p.cursorState.shown=0;p.setMouseInUse(false)
precondition(!p.iridiumStickCursorOwned && overlay.visible && overlay.fallback,"accepted touch clears controller ownership")
// Install the exact GCMouse mouseMovedHandler closure and execute the actual
// moved() path on its mouse queue, including its first/wake main-thread hop.
let gc=GCMouseInputProbe();p.installGCMovement(gc)
func waitForMain(_ condition:()->Bool) {
 let deadline=Date(timeIntervalSinceNow:2)
 while !condition() && Date()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))}
 precondition(condition(),"GC callback must transfer ownership through the main-thread hop")
}
func gcMotion(_ dx:Float,_ dy:Float) {p.mouseQueue.sync{gc.mouseMovedHandler?(gc,dx,dy)}}
p.absoluteAllowed=false;p.pointerOver=true;p.cursorState.shown=1;p.evaluateFocus("relative GC pointer")
precondition(p.currentRoute == .relative,"MADEIRA_POINTER_ABSOLUTE=0 uses the real relative-route policy")
gcMotion(3,4);waitForMain{p.mouseInUse};precondition(p.firstGCDeltas==1 && p.mouseInUseMirror && !p.iridiumStickCursorOwned)
p.stickMoved();precondition(p.iridiumStickCursorOwned)
gcMotion(0,0);precondition(p.iridiumStickCursorOwned,"zero motion does not take ownership")
let movesBefore=p.relativeMoves
gcMotion(5,6);waitForMain{!p.iridiumStickCursorOwned}
precondition(p.firstGCDeltas==1 && p.mouseInUseMirror && p.relativeMoves==movesBefore+1,"an already-live GC mouse wakes after stick activity")
p.pointerOver=false;p.evaluateFocus("relative GC pointer leaves")
precondition(!p.mouseFocused && !overlay.visible,"physical hover exit cannot retain controller ownership")
p.pointerOver=true;p.cursorState.shown=0;p.evaluateFocus("relative GC program hidden");precondition(!overlay.visible && !overlay.fallback)
p.absoluteAllowed=true
let guest=CGSize(width:1424,height:656),icon=CGSize(width:32,height:32)
for host in [CGRect(x:0,y:0,width:712,height:328),CGRect(x:0,y:0,width:328,height:151.1011235955)] {
 let f=IridiumPointerProjection.frame(point:CGPoint(x:712,y:328),guest:guest,host:host,image:icon,hotspot:.zero)
 precondition(abs(f.minX-host.midX)<0.001 && abs(f.minY-host.midY)<0.001,"live guest center survives orientation")
 precondition(f.width>=32 && f.height>=32,"cursor remains readable on a small display")
}
let f=IridiumPointerProjection.frame(point:CGPoint(x:712,y:328),guest:guest,host:CGRect(x:0,y:0,width:712,height:328),image:icon,hotspot:CGPoint(x:4,y:7))
precondition(f.origin==CGPoint(x:352,y:157),"program hotspot follows icon scale")
print("PASS shipping cursor gates, iPad pinned focus/stick transitions, real GC mouse callback after stick activity, physical hidden-cursor policy, touch fallback and live projection")
'''.replace('ACTUAL',actual).replace('GC_MOVEMENT_CALLBACK',callback).replace('POINTER_POLICY',policy).replace('PROJECTION',block((ROOT/'iridium/apps/ios/RuntimeSupport/IridiumPlayerLayout.swift').read_text(),'enum IridiumPointerProjection'))
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);main=root/'main.swift';main.write_text(code);binary=root/'check'
            subprocess.run(['swiftc','-swift-version','5','-module-cache-path',str(root/'cache'),
                str(main),'-o',str(binary)],check=True,timeout=90)
            subprocess.run([str(binary)],check=True,timeout=15)


if __name__=='__main__':unittest.main()
