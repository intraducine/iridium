"""Execute shared setup navigation/persistence, route encoding and artwork sizing."""
from pathlib import Path
import shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
class ProductionUXTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_setup_navigation_resume_and_library_completion(self):
        source=(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumOnboarding.swift').read_text()
        core=source[source.index('enum OnboardingRules'):source.index('struct OnboardingView:')].replace('UserDefaults.standard','fixtureDefaults')
        fixture='''import SwiftUI\nimport Combine\nlet fixtureDefaults=UserDefaults(suiteName: UUID().uuidString)!\nenum MadeiraConfig { static var enabled=true;static func flag(_ key:String)->Bool {enabled} }\n@MainActor final class LibraryModel { static let shared=LibraryModel();var current:String?;var launching=false }\n@MainActor final class IridiumConsoleSession { static let shared=IridiumConsoleSession();var isActive=false }\nvar wineRunning:Int32=0\nfunc wine_process_is_running()->Int32 {wineRunning}\nvar serverRunning:Int32=0\nfunc wineserver_is_running()->Int32 {serverRunning}\n'''
        checks='''
@main struct Checks {
 @MainActor static func main() {
  let steps=OnboardingRules.steps
  precondition(steps == [.library,.downloads,.jit] && OnboardingRules.Step.allCases == steps)
  for (i,step) in steps.enumerated() {
   precondition(OnboardingRules.previous(before:step,in:steps)==(i>0 ? steps[i-1]:nil))
   precondition(OnboardingRules.next(after:step,in:steps)==(i+1<steps.count ? steps[i+1]:nil))
  }
  let model=OnboardingModel();model.presentIfNeeded();precondition(model.presented && model.step == .library)
  model.back();precondition(model.step == .library)
  model.next();precondition(model.step == .downloads);model.skip();precondition(!model.presented && model.takeLibraryAction()==nil)
  let resumed=OnboardingModel();resumed.rerun();precondition(resumed.step == .downloads)
  precondition(resumed.binding(for:.settings).wrappedValue && !resumed.binding(for:.library).wrappedValue)
  resumed.binding(for:.library).wrappedValue=false;precondition(resumed.presented)
  resumed.back();precondition(resumed.step == .library);resumed.next();precondition(resumed.step == .downloads)
  resumed.next();precondition(resumed.presented && resumed.step == .jit && resumed.takeLibraryAction()==nil)
  resumed.back();precondition(resumed.step == .downloads);resumed.next()
  resumed.next();precondition(!resumed.presented && resumed.takeLibraryAction() == .library && resumed.takeLibraryAction()==nil)
  precondition(resumed.dismissalGeneration == 0);resumed.presentationDidDismiss();precondition(resumed.dismissalGeneration == 1)
  precondition(fixtureDefaults.string(forKey:"iridium.setup.step")==nil)
  let completed=OnboardingModel();completed.presentIfNeeded();precondition(!completed.presented)
  precondition(fixtureDefaults.integer(forKey:OnboardingRules.revisionKey)==2)
  for step in steps {
   let skipped=OnboardingModel();skipped.rerun();skipped.go(step);skipped.skip()
   precondition(!skipped.presented && skipped.takeLibraryAction()==nil)
   let restored=OnboardingModel();restored.rerun();precondition(restored.step==step)
  }
  let context=OnboardingModel();context.go(.library);context.chooseSteam()
  precondition(context.step == .library && context.steam && context.steps == steps)
  let gameID="11111111-2222-3333-4444-555555555555"
  context.recordGame(id:gameID,title:"Homebrew PSP",platform:"psp",requiredJIT:false,optionalJIT:true)
  precondition(context.step == .library && !context.steam && context.optionalJIT)
  context.chooseSteam();precondition(context.firstGameID == gameID && context.optionalJIT && context.step == .library)
  context.chooseFiles();precondition(context.firstGameID == gameID && context.optionalJIT && context.step == .library)
  context.setPSPMode(true);precondition(context.pspJIT && context.step == .library && context.steps == steps)
  context.setPSPMode(false)
  context.recordGame(id:gameID,title:"PS2 game",platform:"playStation2",requiredJIT:true,optionalJIT:false)
  precondition(context.step == .library && context.consoleJIT && !context.pspJIT)
  context.go(.jit);context.skip()
  let persisted=OnboardingModel();persisted.rerun()
  precondition(persisted.step == .jit && persisted.firstGameID==gameID && persisted.firstGameTitle=="PS2 game" && persisted.requiresJIT)
  persisted.finishOpeningLibrary();precondition(persisted.takeLibraryAction() == .library && persisted.takeLibraryAction()==nil)
  for windows in [false,true] {for steam in [false,true] {for psp in [false,true] {for console in [false,true] {for mono in [false,true] {
   let capabilities=OnboardingModel()
   capabilities.windows=windows;capabilities.steam=steam;capabilities.pspJIT=psp;capabilities.consoleJIT=console;capabilities.needsMono=mono
   precondition(capabilities.steps == steps && capabilities.requiresJIT == (windows || steam || console))
   capabilities.finishOpeningLibrary();precondition(capabilities.takeLibraryAction() == .library)
  }}}}}
  for saved in ["welcome","library","signIn","unknown"] {
   fixtureDefaults.set(saved,forKey:"iridium.setup.step")
   let legacy=OnboardingModel();legacy.rerun();precondition(legacy.step == .library)
  }
  for saved in ["controls","options","jit","done"] {
   fixtureDefaults.set(saved,forKey:"iridium.setup.step")
   let legacy=OnboardingModel();legacy.rerun();precondition(legacy.step == .jit)
   legacy.skip();let resumed=OnboardingModel();resumed.rerun();precondition(resumed.step == .jit)
  }
  for saved in ["downloads","wineMono","dockClient","steamComponents"] {
   fixtureDefaults.set(saved,forKey:"iridium.setup.step")
   let legacy=OnboardingModel();legacy.rerun();precondition(legacy.step == .downloads)
   legacy.skip();let resumed=OnboardingModel();resumed.rerun();precondition(resumed.step == .downloads)
  }
  fixtureDefaults.set(true,forKey:"iridium.setup.windows");fixtureDefaults.set(false,forKey:"iridium.setup.needsMono")
  fixtureDefaults.set("wineMono",forKey:"iridium.setup.step")
  let legacy=OnboardingModel();legacy.rerun();precondition(legacy.step == .downloads && legacy.needsMono)
  legacy.binding(for:.settings).wrappedValue=false;precondition(!legacy.presented && legacy.takeLibraryAction()==nil)
  LibraryModel.shared.current="active";completed.rerun();precondition(!completed.presented)
  LibraryModel.shared.current=nil
  LibraryModel.shared.launching=true;completed.rerun();precondition(!completed.presented)
  LibraryModel.shared.launching=false;serverRunning=1;completed.rerun();precondition(!completed.presented)
  serverRunning=0;wineRunning=1;completed.rerun();precondition(!completed.presented)
  wineRunning=0
  serverRunning=0;IridiumConsoleSession.shared.isActive=true;completed.rerun();precondition(!completed.presented)
  IridiumConsoleSession.shared.isActive=false;MadeiraConfig.enabled=false;completed.rerun();precondition(!completed.presented)
  MadeiraConfig.enabled=true;completed.rerun();precondition(completed.presented)
  print("PASS setup: fixed pages across 32 capability combinations, legacy migration, same-page imports/Steam, Back/Next, Skip/resume, main Library completion, modal ownership and session admission")
 }
}
'''
        self.compile_run(fixture+core+checks,library=True)
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_setup_completion_enters_main_library_after_dismissal(self):
        source=(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumLibraryView.swift').read_text()
        handler=source[source.index('    private func completeOnboardingAction()'):source.index('    private func restoreKeyboardFocus()')]
        fixture='''import Foundation
@MainActor final class Setup {
 enum Action { case library }
 var presented=true
 var firstGameID=""
 var action:Action? = .library
 func takeLibraryAction()->Action? {defer {action=nil};return action}
}
struct Game {let id:UUID}
@MainActor final class CompletionFixture {
 let onboarding=Setup()
 var favorites=true,searching=true,searchFocus=true
 var search="old filter",focus="search"
 var games:[Game]=[]
 var reconciled=0
 var selected:UUID?
 func keepSelection() {reconciled += 1}
 func select(_ id:UUID) {selected=id}
 func complete() {completeOnboardingAction()}
'''
        checks='''
}
@main struct Checks {
 @MainActor static func main() {
  let id=UUID()
  for gameAvailable in [false,true] {
   let fixture=CompletionFixture();fixture.onboarding.firstGameID=id.uuidString
   if gameAvailable {fixture.games=[Game(id:id)]}
   fixture.complete()
   precondition(fixture.onboarding.action != nil && fixture.reconciled == 0 && fixture.favorites && fixture.searching)
   fixture.onboarding.presented=false;fixture.complete()
   precondition(!fixture.favorites && fixture.search.isEmpty && !fixture.searching && !fixture.searchFocus && fixture.focus == "games")
   precondition(fixture.onboarding.action == nil && fixture.reconciled == 1 && fixture.selected == (gameAvailable ? id:nil))
   fixture.complete();precondition(fixture.reconciled == 1)
  }
  let empty=CompletionFixture();empty.onboarding.presented=false;empty.complete()
  precondition(empty.reconciled == 1 && empty.selected == nil)
  print("PASS setup completion: waits for dismissal, clears Library filters, selects only existing games and consumes once")
 }
}
'''
        self.compile_run(fixture+handler+checks,library=True)
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_container_routes_and_cover_fit(self):
        route=(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumStikDebugRoute.swift').read_text()
        policy=(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumArtworkPresentationPolicy.swift').read_text().split('enum IridiumArtworkImagePolicy {',1)[1]
        checks='''
let request=URL(string:"stikdebug://enable-jit?pid=42&bundle-id=software.iridium&script-data=a%2Bb%2Fc%3D")!
for route in IridiumStikDebugRoute.allCases {
 let destination=route.destination(for:request)!
 if route == .standalone {precondition(destination==request)} else {
  precondition(destination.scheme==route.rawValue && destination.host=="open-url")
  let item=URLComponents(url:destination,resolvingAgainstBaseURL:false)!.queryItems!.first!
  precondition(item.name=="url")
  precondition(String(data:Data(base64Encoded:item.value!)!,encoding:.utf8)==request.absoluteString)
 }
 precondition(route.destination(for:URL(string:"https://example.com/enable-jit")!)==nil)
}
precondition(IridiumArtworkImagePolicy.fitsCover(featured:false,windows:true,width:600,height:900))
precondition(IridiumArtworkImagePolicy.fitsCover(featured:true,windows:false,width:600,height:900))
precondition(IridiumArtworkImagePolicy.fitsCover(featured:true,windows:true,width:600,height:600))
precondition(!IridiumArtworkImagePolicy.fitsCover(featured:true,windows:true,width:600,height:900))
print("PASS routes: all four destinations, exact script/PID request preserved, foreign URL rejected; portrait/console/square covers fit")
'''
        self.compile_run(route+'\nenum IridiumArtworkImagePolicy {'+policy+checks)
    def compile_run(self,code,library=False):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);source=root/'main.swift';binary=root/'check';source.write_text(code)
            subprocess.run(['swiftc',*(['-parse-as-library'] if library else []),'-module-cache-path',str(root/'cache'),str(source),'-o',str(binary)],check=True,timeout=90)
            subprocess.run([str(binary)],check=True,timeout=20)


class DisplayPresentationOwnershipTests(unittest.TestCase):
    def test_settings_root_owns_its_per_game_display_sheet(self):
        import importlib.util, sys
        sys.path.insert(0, str(ROOT / "ci"))
        spec = importlib.util.spec_from_file_location("display_frontend", ROOT / "ci/madeira-frontend.py")
        frontend = importlib.util.module_from_spec(spec); spec.loader.exec_module(frontend)
        generated = frontend.overlay("Library.swift", (ROOT / "ci/fixtures/madeira-build43/app/Madeira/Library.swift").read_text())
        settings = generated[generated.index("struct LibraryView: View"):generated.index("private func iridiumNavigate", generated.index("struct LibraryView: View"))]
        self.assertIn(".sheet(item: $iridiumDetailSelection)", settings)
        self.assertIn("LibraryDetail(iridiumInitialPage: route.page", settings)
        self.assertEqual(generated.count(".sheet(item: $iridiumDetailSelection)"), 1)
        self.assertIn('iridiumDetailSelection = .init(entry: entry, page: "Display")', generated)
        self.assertIn("if !iridiumInitialPageOpened", generated)

if __name__ == '__main__':
    unittest.main()
