"""Execute local identity readers and confidence rules without private game data."""
from host_tests import module_cache
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class ArtworkIdentificationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_pe_global_payload_budgets_across_repeated_and_nested_leaves(self):
        def pe(topology, payload_size):
            resource_size=0x8000;resources=bytearray(resource_size);cursor=0
            def directory(children,root=False):
                nonlocal cursor
                at=cursor;cursor=(cursor+16+8*len(children)+3)&~3
                struct.pack_into('<H',resources,at+14,len(children))
                for index,child in enumerate(children):
                    target=(0x80000000|directory(child)) if isinstance(child,list) else 0x7000
                    struct.pack_into('<II',resources,at+16+index*8,16 if root else index+1,target)
                return at
            assert directory(topology,True)==0 and cursor<0x7000
            struct.pack_into('<II',resources,0x7000,0x2000+resource_size,payload_size)
            data=bytearray(0x400+resource_size+payload_size);data[:2]=b'MZ'
            struct.pack_into('<I',data,60,0x80);data[0x80:0x84]=b'PE\0\0'
            struct.pack_into('<H',data,0x86,1);struct.pack_into('<H',data,0x94,224)
            struct.pack_into('<H',data,0x98,0x10b);struct.pack_into('<I',data,0x98+92,16)
            struct.pack_into('<II',data,0x98+112,0x2000,resource_size)
            struct.pack_into('<III',data,0x98+224+12,0x2000,resource_size+payload_size,0x400)
            data[0x400:0x400+resource_size]=resources
            return data
        # Instrument only actual FileHandle I/O. The reader and its budget
        # branches remain unchanged; a regression traps before a large read.
        original=(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumGameIdentity.swift').read_text()
        needle='file.read(upToCount: count)';self.assertEqual(original.count(needle),1)
        traced=original.replace(needle,'measuredPERead(file, offset: offset, count: count)')
        check=r'''import Foundation
enum IOProbe {
    nonisolated(unsafe) static var reads=0
    nonisolated(unsafe) static var bytes=0
}
func measuredPERead(_ file:FileHandle,offset:Int,count:Int) throws -> Data? {
    if offset>=0x8400 {
        precondition(IOProbe.reads<16 && count<=(4<<20)-IOProbe.bytes,"global payload budget exceeded before I/O")
        IOProbe.reads+=1;IOProbe.bytes+=count
        print("PAYLOAD \(count)")
    }
    return try file.read(upToCount:count)
}
@main struct Checks {
 static func main() {
    let value=IridiumGameIdentity.inspect(title:"Budget",relativePath:CommandLine.arguments[2],drive:URL(fileURLWithPath:CommandLine.arguments[1]))
    precondition(value.productName==nil,"exhausted payload budget must fail closed")
 }
}
'''
        cases=[('repeated',[None]*256,1<<20,4),
               ('fanout',[[None]*4 for _ in range(8)],64,16),
               ('nested',[[[None]*8 for _ in range(8)] for _ in range(4)],768<<10,5)]
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder);source=path/'TracedIdentity.swift';source.write_text(traced)
            main=path/'Check.swift';main.write_text(check);binary=path/'check'
            subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-module-cache-path',module_cache('macosx'),
                str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumRuntime.swift'),
                str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumGameStorage.swift'),
                str(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumArtworkState.swift'),
                str(ROOT/'iridium/apps/ios/App/Steam/SteamKeyValues.swift'),str(source),str(main),'-o',str(binary)],check=True,timeout=120)
            for name,tree,size,reads in cases:
                with self.subTest(topology=name):
                    (path/(name+'.exe')).write_bytes(pe(tree,size))
                    result=subprocess.run([str(binary),str(path),name+'.exe'],text=True,capture_output=True,timeout=10)
                    self.assertEqual(result.returncode,0,result.stderr)
                    sizes=[int(line.split()[1]) for line in result.stdout.splitlines() if line.startswith('PAYLOAD ')]
                    self.assertEqual(len(sizes),reads);self.assertLessEqual(sum(sizes),4<<20)
                    print(f'PASS {name}: {len(sizes)} payload reads, {sum(sizes)} bytes')

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_local_pe_and_storefront_evidence_with_confidence(self):
        # Synthetic PE resources: no commercial executable or identifying hash.
        def block(key, value=b'', children=(), kind=1):
            data=bytearray(struct.pack('<HHH',0,len(value)//2 if kind==1 else len(value),kind)+key.encode('utf-16le')+b'\0\0')
            data+=b'\0'*(-len(data)%4);data+=value;data+=b'\0'*(-len(data)%4)
            for child in children:
                data+=child;data+=b'\0'*(-len(data)%4)
            struct.pack_into('<H',data,0,len(data));return bytes(data)
        def pe(name, plus=False):
            version=block('VS_VERSION_INFO',children=[block('StringFileInfo',children=[block('040904b0',children=[block('ProductName',(name+'\0').encode('utf-16le'))])])],kind=0)
            optional=240 if plus else 224;directories=112 if plus else 96
            data=bytearray(0x1400);data[:2]=b'MZ';struct.pack_into('<I',data,60,0x80);data[0x80:0x84]=b'PE\0\0'
            struct.pack_into('<H',data,0x86,1);struct.pack_into('<H',data,0x94,optional)
            struct.pack_into('<H',data,0x98,0x20b if plus else 0x10b)
            struct.pack_into('<I',data,0x98+directories-4,16)
            struct.pack_into('<II',data,0x98+directories+16,0x2000,0x1000)
            struct.pack_into('<III',data,0x98+optional+12,0x2000,0x1000,0x400)
            for at,ident,target in [(0,16,0x80000020),(0x20,1,0x80000040),(0x40,1033,0x60)]:
                struct.pack_into('<H',data,0x400+at+14,1);struct.pack_into('<II',data,0x400+at+16,ident,target)
            struct.pack_into('<II',data,0x460,0x2100,len(version));data[0x500:0x500+len(version)]=version
            return data
        code=r'''import Foundation
@main struct Checks {
static func main() throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1])
    func inspect(_ path:String,_ title:String="JSB")->IridiumGameIdentity { .inspect(title:title,relativePath:path,drive:root) }
    let candidate=IridiumArtworkCandidate(id:"531510",title:"Just Shapes & Beats",platform:.windows,source:"steam",coverURL:nil,backgroundURL:nil)
    for folder in ["Just Shapes & Beats","PE64"] {
        let identity=inspect(folder+"/JSB.exe")
        precondition(identity.productName==candidate.title)
        precondition(identity.queries.first==candidate.title)
        precondition(identity.mayAutomaticallyMatch(candidate)==(folder==candidate.title))
    }
    let hints=inspect("Hints/Just Shapes & Beats/JSB.exe")
    precondition(hints.queries.first==candidate.title && !hints.mayAutomaticallyMatch(candidate))
    let steam=inspect("steamapps/common/Selected/JSB.exe")
    precondition(steam.manifestSteamID==531510 && steam.mayAutomaticallyMatch(candidate))
    let conflict=inspect("Conflicting/steamapps/common/Selected/JSB.exe")
    precondition(conflict.conflict && !conflict.mayAutomaticallyMatch(candidate))
    let gog=inspect("GOG/JSB.exe")
    precondition(gog.productName==candidate.title && gog.metadataNames==[candidate.title] && gog.mayAutomaticallyMatch(candidate))
    let appid=inspect("AppID/Just Shapes & Beats/JSB.exe")
    precondition(appid.steamHints==[531510] && appid.mayAutomaticallyMatch(candidate))
    let wrong=IridiumArtworkCandidate(id:"1",title:candidate.title,platform:.windows,source:"steam",coverURL:nil,backgroundURL:nil)
    precondition(!appid.mayAutomaticallyMatch(wrong))
    precondition(inspect("../escape.exe").productName==nil)
    precondition(inspect("Escaped/JSB.exe").productName==nil)
    precondition(inspect("Generic/JSB.exe").productName==nil)
    for index in 0..<8 { precondition(inspect("Malformed/\(index).exe").productName==nil) }
    precondition(inspect("Just Shapes & Beats/JSB.exe","My title").hints==["My title"])
    print("PASS bounded PE32/PE32+, storefront manifests, nearby metadata, confidence, conflicts, malformed input and path containment")
}}
'''
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder);drive=path/'drive';drive.mkdir()
            def write(name,data):
                target=drive/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
            write('Just Shapes & Beats/JSB.exe',pe('Just Shapes & Beats'))
            write('PE64/JSB.exe',pe('Just Shapes & Beats',True))
            write('Hints/Just Shapes & Beats/JSB.exe',b'MZ')
            write('GOG/JSB.exe',pe('Just Shapes & Beats'));write('GOG/goggame-1.info',b'{"name":"Just Shapes & Beats"}')
            write('AppID/Just Shapes & Beats/JSB.exe',b'MZ');write('AppID/Just Shapes & Beats/steam_appid.txt',b'531510\n')
            manifest=b'"AppState" { "appid" "531510" "name" "Just Shapes & Beats" "installdir" "Selected" }'
            write('steamapps/common/Selected/JSB.exe',b'MZ');write('steamapps/appmanifest_531510.acf',manifest)
            write('Conflicting/steamapps/common/Selected/JSB.exe',b'MZ');write('Conflicting/steamapps/appmanifest_531510.acf',manifest)
            write('Conflicting/steamapps/appmanifest_2.acf',manifest.replace(b'531510',b'2'))
            write('Generic/JSB.exe',pe('Unity'))
            (path/'outside').mkdir();(path/'outside/JSB.exe').write_bytes(pe('Just Shapes & Beats'))
            (drive/'Escaped').symlink_to(path/'outside',target_is_directory=True)
            malformed=[b'',b'MZ',b'not an executable',pe('Bad')[:100]]
            for offset in [60,0x98+96+16,0x404+16,0x500]:
                data=pe('Bad');data[offset:offset+4]=b'\xff'*4;malformed.append(data)
            for index,data in enumerate(malformed):write(f'Malformed/{index}.exe',data)
            main=path/'Check.swift';main.write_text(code);binary=path/'check'
            subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-module-cache-path',module_cache('macosx'),
                str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumRuntime.swift'),
                str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumGameStorage.swift'),
                str(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumArtworkState.swift'),
                str(ROOT/'iridium/apps/ios/App/Steam/SteamKeyValues.swift'),
                str(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumGameIdentity.swift'),str(main),'-o',str(binary)],check=True,timeout=120)
            subprocess.run([str(binary),str(drive)],check=True,timeout=10)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_actual_import_metadata_and_preserved_manual_names(self):
        code=r'''import Foundation
@main struct Checks {
static func main() {
    func queries(_ title:String,_ path:String?) -> [String] {
        IridiumArtworkMatcher.identificationQueries(title:title,executableRelativePath:path)
    }
    precondition(queries("JSB","Just Shapes & Beats/JSB.exe")==["Just Shapes & Beats","JSB"])
    precondition(queries("JSB",#"Just Shapes & Beats\Binaries\Win64\JSB.exe"#)==["Just Shapes & Beats","JSB"])
    precondition(queries("JSB","Just.Shapes.&.Beats/JSB.exe")==["Just Shapes & Beats","JSB"])
    precondition(queries("My renamed game","Just Shapes & Beats/JSB.exe")==["My renamed game"])
    precondition(queries("JSB","Games/JSB.exe")==["JSB"])
    precondition(queries("Celeste","Celeste/Celeste.exe")==["Celeste"])
    precondition(queries("Ghost of Sparta (USA)",nil)==["Ghost of Sparta (USA)"])
    precondition(queries("JSB","../../JSB.exe")==["JSB"])
    let candidate=IridiumArtworkCandidate(id:"catalog-game",title:"Just Shapes & Beats",platform:.windows,source:"steam",coverURL:nil,backgroundURL:nil)
    precondition(IridiumArtworkMatcher.exactMatch(queries("JSB","Just Shapes & Beats/JSB.exe")[0],platform:.windows,candidates:[candidate])==candidate)
    precondition(IridiumArtworkMatcher.exactMatch("JSB",platform:.windows,candidates:[candidate])==nil)
    precondition(IridiumArtworkMatcher.exactMatch("Just Shapes & Beats",platform:.windows,candidates:[candidate,candidate])==nil)
    print("PASS imported metadata, executable abbreviations, manual titles and ambiguity")
}}
'''
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder);main=path/'Check.swift';main.write_text(code);binary=path/'check'
            subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-module-cache-path',module_cache('macosx'),
                str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumRuntime.swift'),
                str(ROOT/'iridium/apps/ios/RuntimeSupport/IridiumGameStorage.swift'),
                str(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumArtworkState.swift'),str(main),'-o',str(binary)],check=True,timeout=120)
            subprocess.run([str(binary)],check=True,timeout=10)


if __name__=='__main__':unittest.main()
