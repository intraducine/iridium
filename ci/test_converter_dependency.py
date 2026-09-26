"""Exercise the hosted converter path without Apple credentials or an installer."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / 'testrepos/Madeira/build/madeira-d3d12/deps.sh'


class ConverterDependencyTests(unittest.TestCase):
    def test_verified_download_cache_and_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            madeira = root / 'testrepos/Madeira'
            script = madeira / 'build/madeira-d3d12/deps.sh'
            script.parent.mkdir(parents=True)
            (root / 'ci').mkdir()
            shutil.copy(ROOT / 'ci/fetch-runtime-inputs.py', root / 'ci')
            entry = next(e for e in json.loads((ROOT / 'ci/runtime-inputs.json').read_text())
                         if e['name'] == 'metal-shader-converter')
            payload = 'MetalShaderConverter.pkg/Payload/usr/local/'
            files = {payload + name: b'test fixture\n' for name in (
                'include/metal_irconverter/metal_irconverter.h',
                'include/metal_irconverter_runtime/metal_irconverter_runtime.h',
                'lib/libmetalirconverter.dylib', 'lib_iOS/libmetalirconverter.dylib')}
            manifest = ''.join(f'{hashlib.sha256(data).hexdigest()}  {name}\n'
                               for name, data in files.items()).encode()
            files['SHA256SUMS'] = manifest
            archive = root / 'fixture.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                for name, data in files.items():
                    member = tarfile.TarInfo('metal-shader-converter-4.0-beta2/' + name)
                    member.size = len(data)
                    tar.addfile(member, io.BytesIO(data))
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            text = DEPS.read_text().replace(entry['sha256'], digest).replace(
                '073f903be98e973ff38f4d79f2c48d61ef938754a77b1caedda79c9f05a068c2',
                hashlib.sha256(b'test fixture\n').hexdigest())
            script.write_text(text)
            entry['sha256'] = digest
            (root / 'ci/runtime-inputs.json').write_text(json.dumps([entry]))
            cache = root / '.build/runtime-downloads' / (digest + '.tar')
            cache.parent.mkdir(parents=True)
            shutil.copy(archive, cache)

            def run(extra=''):
                return subprocess.run(['bash', '-c', extra + 'source "$1"', 'bash', str(script)],
                                      capture_output=True, text=True)

            for _ in range(2):
                result = run()
                self.assertEqual(result.returncode, 0, result.stderr)
            extracted = madeira / ('.build/msc-' + digest) / 'metal-shader-converter-4.0-beta2'
            (extracted / (payload + 'lib_iOS/libmetalirconverter.dylib')).write_bytes(b'corrupt')
            # Changing the extracted checksum list must not bypass validation.
            (extracted / 'SHA256SUMS').write_text('')
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('extraction is damaged', result.stderr)
            result = run('export MADEIRA_MSC_PKG=/missing-explicit-installer; ')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requested installer is missing', result.stderr)
            cache.write_bytes(b'corrupt archive')
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('digest mismatch', result.stderr.lower())


if __name__ == '__main__':
    unittest.main()
