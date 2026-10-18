#!/usr/bin/env python3
"""Build MoltenVK 1.2.9 from the already reviewed, digest-locked source closure."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import zipfile
import tarfile

ROOT=Path(__file__).resolve().parents[1]
INPUTS=ROOT/'ci/moltenvk-source-inputs.json'


def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def verify_tree(archive, target):
    """Reject source edits hidden behind a valid cached download digest."""
    records = {}
    with tarfile.open(archive) as tar:
        for item in tar:
            relative = Path(item.name)
            if relative.is_absolute() or '..' in relative.parts: raise ValueError('Unsafe MoltenVK source path')
            if len(relative.parts) <= 1 or not item.isfile(): continue
            name = Path(*relative.parts[1:])
            file = target / name
            if file.is_symlink() or not file.is_file(): raise ValueError('Missing or redirected MoltenVK source: ' + str(name))
            expected = hashlib.file_digest(tar.extractfile(item), 'sha256').hexdigest()
            if digest(file) != expected: raise ValueError('Modified MoltenVK source: ' + str(name))
            records[name.as_posix()] = expected
    return hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()


def build(sdk, jobs=4):
    entries=json.loads(INPUTS.read_text())
    root=ROOT/'.build/ppsspp/moltenvk-source'
    spec=importlib.util.spec_from_file_location('mvk_inputs',ROOT/'ci/fetch-runtime-inputs.py')
    fetch=importlib.util.module_from_spec(spec);spec.loader.exec_module(fetch)
    trees = {}
    for item in entries:
        target=root/item['name']
        archive=ROOT/'.build/runtime-downloads'/(item['sha256']+'.tar')
        if not target.exists():
            entry=dict(item,destination=target.relative_to(ROOT).as_posix(),
                       archive_root=item['repository'].split('/')[1]+'-'+item['revision'])
            fetch.fetch(ROOT,entry)
        if not archive.is_file() or digest(archive)!=item['sha256']:
            raise ValueError('MoltenVK source archive missing or changed: '+item['name'])
        trees[item['name']] = verify_tree(archive, target)
    mvk=root/'MoltenVK';external=mvk/'External';external.mkdir(exist_ok=True)
    for name in ('cereal','Vulkan-Headers','SPIRV-Cross','glslang','Vulkan-Tools','Volk'):
        link=external/name
        if not link.exists():link.symlink_to(root/name,target_is_directory=True)
        if link.resolve()!=root/name:raise ValueError('Unexpected MoltenVK dependency link')
    glslang=root/'glslang';(glslang/'External').mkdir(exist_ok=True)
    for name,link in (('SPIRV-Tools',glslang/'External/spirv-tools'),('SPIRV-Headers',root/'SPIRV-Tools/external/spirv-headers')):
        link.parent.mkdir(exist_ok=True)
        if not link.exists():link.symlink_to(root/name,target_is_directory=True)
        if link.resolve()!=root/name:raise ValueError('Unexpected SPIR-V dependency link')
    subprocess.run(['python3','build_info.py','.', '-i','build_info.h.tmpl','-o','build/include/glslang/build_info.h'],cwd=glslang,check=True)
    with zipfile.ZipFile(mvk/'Templates/spirv-tools/build.zip') as z:
        for item in z.infolist():
            if item.filename.startswith('__MACOSX/'):continue
            if Path(item.filename).is_absolute() or '..' in Path(item.filename).parts:
                raise ValueError('Unsafe generated SPIR-V header path')
            target = root/'SPIRV-Tools'/item.filename
            if item.is_dir(): target.mkdir(parents=True, exist_ok=True); continue
            data = z.read(item)
            if target.is_symlink(): raise ValueError('Redirected generated SPIR-V header')
            if not target.is_file() or target.read_bytes() != data:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
    suffix='iphoneos' if sdk=='iphoneos' else 'iphonesimulator'
    destination='generic/platform=iOS' + (' Simulator' if sdk=='iphonesimulator' else '')
    toolchain=subprocess.check_output(['xcodebuild','-version'],text=True).strip()
    def compile(project,scheme,derived):
        command=['xcodebuild','-project',project,'-scheme',scheme,'-configuration','Release',
                 '-destination',destination,'-derivedDataPath',str(derived),'-jobs',str(jobs),
                 'ARCHS=arm64','ONLY_ACTIVE_ARCH=NO','IPHONEOS_DEPLOYMENT_TARGET=18.0',
                 'MACOSX_DEPLOYMENT_TARGET=12.0','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','DEVELOPMENT_TEAM=']
        subprocess.run(command,cwd=mvk,check=True)
        return command
    dependencies=ROOT/'.build/ppsspp/moltenvk-derived'/suffix
    packaged=ROOT/'.build/ppsspp/moltenvk-derived'/('package-'+suffix)
    commands=[compile('ExternalDependencies.xcodeproj','ExternalDependencies-iOS',dependencies),
              compile('MoltenVKPackaging.xcodeproj','MoltenVK Package (iOS only)',packaged)]
    archive=packaged/'Build/Products'/('Release-'+suffix)/'libMoltenVK.a'
    if subprocess.check_output(['xcrun','lipo','-archs',str(archive)],text=True).strip()!='arm64':
        raise ValueError('Unexpected MoltenVK architecture')
    receipt={'version':'1.2.9','sourceInputs':entries,'sourceArchiveSHA256':digest(INPUTS),
             'sourceTreeSHA256':trees,'sdk':sdk,'sdkVersion':subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-version'],text=True).strip(),
             'toolchain':toolchain,'archiveSHA256':digest(archive),
             'commands':[[arg.replace(str(ROOT),'$IRIDIUM_SOURCE') for arg in cmd] for cmd in commands],
             'sourceChanges':'none; exact release source with external links and upstream generated headers',
             'license':'Apache-2.0 and dependency-specific grants; original notices retained'}
    (packaged/'component.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return archive, receipt


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk',choices=('iphoneos','iphonesimulator'),required=True)
    args=parser.parse_args();archive,receipt=build(args.sdk)
    print('Built source-pinned MoltenVK:',archive)
