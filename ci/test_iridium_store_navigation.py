"""Exercise shipping store routes and account identity without network or credentials."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'

@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class StoreNavigationTests(unittest.TestCase):
    def check(self, program):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'Check.swift'; source.write_text(program)
            binary = source.with_suffix('')
            result = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                '-module-cache-path', module_cache('macosx'), str(source), '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_workshop_explains_empty_and_unsupported_libraries(self):
        source = (IOS / 'App/Steam/SteamWorkshop.swift').read_text().split('struct SteamWorkshopHub: View {', 1)[1]
        filters = source[source.index('        let installed ='):source.index('        NavigationStack {')]
        condition = source.split('} else if ', 1)[1].split(' {', 1)[0]
        self.check('''import Foundation
struct Game: Equatable { let id: Int; var installed = true; var name = "Fixture" }
struct Games { var games: [Game] }
struct Owned { var workshop: Bool? }
struct Steam { var support: [Int: Bool]; func game(_ id: Int) -> Owned? { support[id].map { Owned(workshop:$0) } } }
struct Record { var installed: [Int] = [] }
struct Model { var items: Set<UInt32> = []; func record(_ id: UInt32) -> Record { Record(installed:items.contains(id) ? [1] : []) } }
func state(_ games: Games, _ steam: Steam, _ model: Model = Model()) -> String {
''' + filters + '''
 if installed.isEmpty { return "empty" }
 if ''' + condition + ''' { return "unsupported" }
 return "games"
}
@main struct Check { static func main() {
 precondition(state(Games(games:[]), Steam(support:[:])) == "empty")
 precondition(state(Games(games:[Game(id:1)]), Steam(support:[1:false])) == "unsupported")
 precondition(state(Games(games:[Game(id:1)]), Steam(support:[:])) == "games")
 precondition(state(Games(games:[Game(id:1)]), Steam(support:[1:true])) == "games")
 precondition(state(Games(games:[Game(id:1)]), Steam(support:[1:false]), Model(items:[1])) == "games")
 precondition(state(Games(games:[Game(id:1,installed:false)]), Steam(support:[1:true])) == "empty")
}}
''')

    def test_game_options_offer_the_owning_store_controls(self):
        source = (IOS / 'App/Library/IridiumWindowsScreens.swift').read_text()
        start = source.index('    enum Page: Hashable {')
        page = source[start:source.index('    @State private var path:', start)]
        start = source.index('    private var pageGroups: [[Page]]')
        routes = source[start:source.index('    /// Steam Workshop is offered', start)].replace('private var', 'var')
        self.check('''import Foundation
struct Entry {
 var usesLaunchOptions=false, desktop: Bool? = false
 var steamAppID: Int?, itchGameID: Int?, epicAppName: String?, eaOfferID: String?, gogProductID: String?
}
enum SteamOwnedLibrary { static let cloudEnabled=true, workshopEnabled=true }
struct Host {
 let entry: Entry
 static func showsWorkshop(_ id: Int?) -> Bool { id != nil }
''' + page + routes + '''
}
@main struct Check { static func main() {
 let cases: [(Entry, Host.Page?)] = [(.init(), nil), (.init(steamAppID:220), .steam),
  (.init(gogProductID:"fixture"), .gog), (.init(itchGameID:1), .itch), (.init(epicAppName:"fixture"), .epic), (.init(eaOfferID:"fixture"), .ea)]
 for (entry, store) in cases {
  let groups=Host(entry:entry).pageGroups
  precondition(groups.flatMap { $0 }.contains(.library))
  for page in [Host.Page.steam, .gog, .itch, .epic, .ea] { precondition(groups.flatMap { $0 }.contains(page) == (page == store)) }
 }
 precondition(!Host(entry:Entry(desktop:true)).pageGroups.flatMap { $0 }.contains(.library))
}}
''')

    def test_accounts_keep_all_five_providers_separate(self):
        source = (IOS / 'App/Stores/IridiumStoreBrowser.swift').read_text()
        enum_source = source[source.index('enum IridiumStorefront:'):source.index('struct IridiumStoreBrowser:')]
        self.check('''import Foundation
@MainActor final class SteamOwnedLibrary { static let shared=SteamOwnedLibrary(); var signedIn=false }
@MainActor final class GOGLibrary { static let shared=GOGLibrary(); var signedIn=false }
@MainActor final class EpicLibrary { static let shared=EpicLibrary(); var signedIn=false }
@MainActor final class EALibrary { static let shared=EALibrary(); var signedIn=false }
@MainActor final class ItchLibrary { static let shared=ItchLibrary(); var signedIn=false }
''' + enum_source + '''
@main struct Check { @MainActor static func main() {
 precondition(IridiumStorefront.allCases.map(\\.rawValue) == ["Steam","GOG","Epic Games","EA","itch.io"])
 precondition(IridiumStorefront.allCases.allSatisfy { !$0.signedIn })
 SteamOwnedLibrary.shared.signedIn=true
 precondition(IridiumStorefront.steam.signedIn && !IridiumStorefront.epic.signedIn)
 GOGLibrary.shared.signedIn=true; EpicLibrary.shared.signedIn=true; EALibrary.shared.signedIn=true; ItchLibrary.shared.signedIn=true
 precondition(IridiumStorefront.allCases.allSatisfy(\\.signedIn))
 SteamOwnedLibrary.shared.signedIn=false
 precondition(!IridiumStorefront.steam.signedIn && IridiumStorefront.epic.signedIn && IridiumStorefront.ea.signedIn && IridiumStorefront.itch.signedIn)
}}
''')
