"""Execute the shipping Setup controller routing policy with real mocked actions."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SetupControllerTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler required")
    def test_active_controls_actions_values_removal_modal_ownership_and_reveal(self):
        source = (ROOT / "iridium/apps/ios/MadeiraFrontend/IridiumSetupController.swift").read_text()
        policy = source.split("// MARK: - SwiftUI registration", 1)[0]
        checks = r'''
var imported=0, downloaded=0, advanced=0, wentBack=0, skipped=0, reveals:[String]=[]
func target(_ id:String,_ order:Int,page:String="library",enabled:Bool=true,
            role:SetupControllerTarget.Role = .control,
            adjust:((Int)->Void)?=nil,action:@escaping ()->Void)->SetupControllerTarget {
 SetupControllerTarget(id:id,page:page,order:order,frame:CGRect(x:0,y:CGFloat(2000-order),width:200,height:50),
   enabled:enabled,role:role,action:action,adjust:adjust,reveal:{reveals.append(id)})
}
let files=target("files",10,action:{imported += 1})
let next=target("next",9001,role:.next,action:{advanced += 1})
let back=target("back",9000,role:.back,action:{wentBack += 1})
let skip=target("skip",10000,role:.skip,action:{skipped += 1})
let hidden=target("download",1,page:"downloads",action:{downloaded += 1})
var policy=SetupControllerPolicy()
policy.update([next,skip,hidden,files],page:"library")
precondition(policy.available.map(\.id)==["files","next","skip"])
precondition(policy.selected==nil && !policy.visible)
policy.receive("down",suspended:false,back:{wentBack += 1})
precondition(policy.selected=="files" && reveals.last=="files" && policy.visible)
policy.receive("accept",suspended:false,back:{wentBack += 1})
precondition(imported==1 && advanced==0 && downloaded==0)
for command in ["up","down","left","right","accept","back"] {
 policy.receive(command,suspended:true,back:{wentBack += 1})
}
precondition(imported==1 && advanced==0 && wentBack==0 && policy.selected=="files")
policy.receive("right",suspended:false,back:{})
precondition(policy.selected=="next" && reveals.last=="next" && advanced==0)
policy.receive("accept",suspended:false,back:{})
precondition(advanced==1)
policy.update([back,next,files],page:"library")
policy.receive("left",suspended:false,back:{})
precondition(policy.selected=="back")
policy.receive("accept",suspended:false,back:{})
precondition(wentBack==1)
policy.receive("back",suspended:false,back:{wentBack += 10})
precondition(wentBack==11)

// Removed/disabled controls are cleared. The next A only reveals a replacement.
policy.update([files,next],page:"library")
policy.receive("up",suspended:false,back:{})
precondition(policy.selected=="next")
policy.receive("up",suspended:false,back:{})
precondition(policy.selected=="files")
let disabledFiles=target("files",10,enabled:false,action:{fatalError("disabled action")})
policy.update([disabledFiles,next],page:"library")
precondition(policy.selected==nil)
policy.receive("accept",suspended:false,back:{})
precondition(policy.selected=="next" && advanced==1)
policy.receive("accept",suspended:false,back:{})
precondition(advanced==2)
policy.update([],page:"library")
policy.receive("accept",suspended:false,back:{})
precondition(policy.selected==nil && advanced==2)

// A page change cannot activate a preloaded TabView page or reuse old focus.
policy.update([files,next,hidden],page:"downloads")
precondition(policy.selected==nil && policy.available.map(\.id)==["download"])
policy.receive("accept",suspended:false,back:{})
precondition(downloaded==0 && policy.selected=="download")
policy.receive("accept",suspended:false,back:{})
precondition(downloaded==1 && imported==1)

// The actual picker cycling implementation wraps both directions, including A.
var value="LC"
let choices=["LC","LC2","LC3"]
let adjust:(Int)->Void={value=SetupControllerPolicy.cycled(value,in:choices,direction:$0)}
let picker=target("container",10,page:"jit",adjust:adjust,action:{adjust(1)})
policy.update([picker],page:"jit")
policy.receive("down",suspended:false,back:{})
policy.receive("left",suspended:false,back:{})
precondition(value=="LC3" && policy.selected=="container")
policy.receive("right",suspended:false,back:{})
precondition(value=="LC")
policy.receive("accept",suspended:false,back:{})
precondition(value=="LC2")
precondition(SetupControllerPolicy.cycled("unknown",in:choices,direction:1)=="LC2")
precondition(SetupControllerPolicy.cycled("same",in:[String](),direction:1)=="same")

var enabled=false
let toggle=target("shortcut",20,page:"jit",adjust:{enabled=$0>0},action:{enabled.toggle()})
policy.update([picker,toggle],page:"jit")
policy.receive("down",suspended:false,back:{})
precondition(policy.selected=="shortcut" && reveals.last=="shortcut")
policy.receive("right",suspended:false,back:{})
precondition(enabled)
policy.receive("left",suspended:false,back:{})
precondition(!enabled)
policy.receive("accept",suspended:false,back:{})
precondition(enabled)

// Updated registration uses the latest action, not a stale captured closure.
var fresh=0
policy.update([target("shortcut",20,page:"jit",action:{fresh += 1})],page:"jit")
policy.receive("accept",suspended:false,back:{})
precondition(fresh==1)

// A preference may remain equal after a touch changes AppStorage. Its retained target
// must invoke the callback from the latest committed view, without policy.update.
let callbacks=SetupControllerCallbacks()
var observed="LC2"
var actionResult=""
func commitSnapshot(_ snapshot:String,enabled:Bool=true) {
 callbacks.update(enabled:enabled,action:{actionResult=snapshot},adjust:{direction in
  observed=SetupControllerPolicy.cycled(snapshot,in:choices,direction:direction)
 })
}
commitSnapshot(observed)
let retained=target("rebound-container",10,page:"jit",adjust:callbacks.adjust,action:callbacks.activate)
var retainedPolicy=SetupControllerPolicy()
retainedPolicy.update([retained],page:"jit")
retainedPolicy.receive("down",suspended:false,back:{})
observed="LC" // Native touch changed the selection after initial registration.
commitSnapshot(observed)
let rendered=target("rebound-container",10,page:"jit",adjust:callbacks.adjust,action:callbacks.activate)
precondition(retained==rendered && actionResult.isEmpty && observed=="LC")
retainedPolicy.receive("right",suspended:false,back:{})
precondition(observed=="LC2") // The stale snapshot would have produced LC3.
commitSnapshot(observed)
retainedPolicy.receive("accept",suspended:false,back:{})
precondition(actionResult=="LC2")
observed="LC3";commitSnapshot(observed)
retainedPolicy.receive("left",suspended:false,back:{})
precondition(observed=="LC2")
callbacks.update(enabled:false,action:{fatalError("stale enabled action")},adjust:{_ in fatalError("stale enabled adjustment")})
retainedPolicy.receive("accept",suspended:false,back:{})
retainedPolicy.receive("right",suspended:false,back:{})
precondition(observed=="LC2" && actionResult=="LC2")
callbacks.update(enabled:true,action:{actionResult="replacement"},adjust:nil)
retainedPolicy.receive("accept",suspended:false,back:{})
precondition(actionResult=="replacement")

var shared=false
let share=target("share",30,page:"jit",action:{shared=true})
policy.update([share],page:"jit")
policy.receive("down",suspended:false,back:{})
policy.receive("accept",suspended:false,back:{})
precondition(shared)
policy.receive("accept",suspended:shared,back:{fatalError("modal back")})
policy.receive("back",suspended:shared,back:{fatalError("modal back")})
shared=false
policy.receive("back",suspended:shared,back:{wentBack += 1})
precondition(wentBack==12)
policy.hide();precondition(!policy.visible)
print("PASS Setup controller: active page, ordered reveal, exact actions, disabled/removal, picker/toggle adjustment, footer, Back, modal ownership and equal-preference callback rebinding")
'''
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            swift = root / "main.swift"
            binary = root / "setup-controller-check"
            swift.write_text(policy + checks)
            subprocess.run(["swiftc", "-module-cache-path", str(root / "cache"), str(swift), "-o", str(binary)], check=True, timeout=90)
            subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == "__main__":
    unittest.main()
