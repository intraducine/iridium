"""Execute shared setup navigation/persistence, route encoding and artwork sizing."""
from pathlib import Path
import shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
class ProductionUXTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_setup_navigation_resume_and_conditional_capabilities(self):
        source=(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumOnboarding.swift').read_text()
        core=source[source.index('enum OnboardingRules'):source.index('struct OnboardingView:')].replace('UserDefaults.standard','fixtureDefaults')
        fixture='''import SwiftUI\nimport Combine\nlet fixtureDefaults=UserDefaults(suiteName: UUID().uuidString)!\nenum MadeiraConfig { static func flag(_ key:String)->Bool {true} }\nenum SteamSignIn { static let isEnabled=true }\nenum MadeiraDock { static let enabled=true }\nenum WineMonoModel { static var available=false }\n@MainActor final class LibraryModel { static let shared=LibraryModel();var current:String?;var launching=false }\n@MainActor final class IridiumConsoleSession { static let shared=IridiumConsoleSession();var isActive=false }\nfunc wine_process_is_running()->Int32 {0}\nvar serverRunning:Int32=0\nfunc wineserver_is_running()->Int32 {serverRunning}\n'''
        checks='''
@main struct Checks {
 @MainActor static func main() {
  for windows in [false,true] {for steam in [false,true] {for psp in [false,true] {for console in [false,true] {
   let steps=OnboardingRules.steps(windows:windows,steam:steam,pspJIT:psp,consoleJIT:console,signIn:true,dock:true,mono:true)
   precondition(steps.first == .library && !steps.contains(.welcome))
   precondition(steps.contains(.jit)==(windows || steam || psp || console))
   precondition(steps.contains(.signIn)==steam && steps.contains(.dockClient)==steam && steps.contains(.wineMono)==windows)
   for (i,step) in steps.enumerated() {
    precondition(OnboardingRules.previous(before:step,in:steps)==(i>0 ? steps[i-1]:nil))
    precondition(OnboardingRules.next(after:step,in:steps)==(i+1<steps.count ? steps[i+1]:nil))
   }
  }}}}
  let model=OnboardingModel();model.presentIfNeeded();precondition(model.presented && model.step == .library)
  model.next();precondition(model.step == .controls);model.skip();precondition(!model.presented)
  let resumed=OnboardingModel();resumed.rerun();precondition(resumed.step == .controls)
  precondition(resumed.binding(for:.settings).wrappedValue && !resumed.binding(for:.library).wrappedValue)
  resumed.next();precondition(resumed.step == .options);resumed.windows=true;resumed.next();precondition(resumed.step == .jit)
  resumed.back();precondition(resumed.step == .options);resumed.finish()
  precondition(fixtureDefaults.string(forKey:"iridium.setup.step")==nil)
  let completed=OnboardingModel();completed.presentIfNeeded();precondition(!completed.presented)
  let context=OnboardingModel();context.go(.library);context.chooseSteam()
  precondition(context.step == .signIn && context.steam && context.steps.contains(.dockClient) && context.steps.contains(.jit))
  let gameID="11111111-2222-3333-4444-555555555555"
  context.recordGame(id:gameID,title:"Homebrew PSP",platform:"psp",requiredJIT:false,optionalJIT:true)
  precondition(!context.steps.contains(.jit) && !context.steam && context.optionalJIT)
  context.pspJIT=true;precondition(context.steps.contains(.jit));context.pspJIT=false
  context.recordGame(id:gameID,title:"PS2 game",platform:"playStation2",requiredJIT:true,optionalJIT:false)
  precondition(context.steps.contains(.jit) && context.consoleJIT && !context.pspJIT)
  context.go(.options);context.skip()
  let persisted=OnboardingModel();persisted.rerun()
  precondition(persisted.step == .options && persisted.firstGameID==gameID && persisted.firstGameTitle=="PS2 game" && persisted.requiresJIT)
  persisted.finishOpeningLibrary();precondition(persisted.takeLibraryAction() == .game(gameID) && persisted.takeLibraryAction()==nil)
  persisted.finishOpeningLibrary(gameAvailable:false);precondition(persisted.takeLibraryAction() == .files)
  persisted.chooseFiles();persisted.recordGame(id:gameID,title:"Game Boy game",platform:"gameBoy",requiredJIT:false,optionalJIT:false)
  precondition(!persisted.steps.contains(.jit))
  let source=OnboardingModel();source.go(.library);source.chooseSteam();source.finishOpeningLibrary()
  precondition(source.takeLibraryAction() == .steam && source.takeLibraryAction()==nil)
  source.chooseFiles();source.finishOpeningLibrary();precondition(source.takeLibraryAction() == .files)
  fixtureDefaults.set(true,forKey:"iridium.setup.windows");fixtureDefaults.set(false,forKey:"iridium.setup.needsMono")
  fixtureDefaults.set("wineMono",forKey:"iridium.setup.step")
  let legacy=OnboardingModel();legacy.rerun();precondition(legacy.step == .wineMono && legacy.needsMono)
  WineMonoModel.available=true
  let installed=OnboardingModel();installed.rerun();precondition(installed.step == .wineMono)
  WineMonoModel.available=false
  fixtureDefaults.set("welcome",forKey:"iridium.setup.step")
  let oldIntro=OnboardingModel();oldIntro.rerun();precondition(oldIntro.step == .library)
  oldIntro.next();precondition(oldIntro.step == .controls)
  oldIntro.skip();let skippedControls=OnboardingModel();skippedControls.rerun();precondition(skippedControls.step == .controls)
  LibraryModel.shared.launching=true;completed.rerun();precondition(!completed.presented)
  LibraryModel.shared.launching=false;serverRunning=1;completed.rerun();precondition(!completed.presented)
  serverRunning=0;IridiumConsoleSession.shared.isActive=true;completed.rerun();precondition(!completed.presented)
  print("PASS setup: every option combination, Back/Next boundaries, Skip/resume, one presentation owner and session admission")
 }
}
'''
        self.compile_run(fixture+core+checks,library=True)
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
