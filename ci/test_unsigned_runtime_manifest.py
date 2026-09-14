import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load_packager():
    path = ROOT / "ci" / "package-unsigned-ipa.py"
    spec = importlib.util.spec_from_file_location("unsigned_packager_manifest_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


packager = load_packager()


class UnsignedRuntimeManifestTests(unittest.TestCase):
    def test_refreshes_runtime_host_hash_after_signature_stripping(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "Iridium.app"
            bundle = app / "BundledRuntime" / "iridium-runtime-base"
            runtime_host = bundle / "Runtime" / "runtime-host.bin"
            runtime_host.parent.mkdir(parents=True)

            before = bytes.fromhex("cffaedfe") + b"signed-runtime-host"
            after = bytes.fromhex("cffaedfe") + b"unsigned-runtime-host"
            runtime_host.write_bytes(before)

            invariant = "a" * 64
            manifest_path = bundle / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "artifacts": [
                            {
                                "identifier": "runtime-host-binary",
                                "relativePath": "Runtime/runtime-host.bin",
                                "sizeBytes": len(before),
                                "checksum": hashlib.sha256(before).hexdigest(),
                                "kind": "runtimeBinary",
                            },
                            {
                                "identifier": "wine-userland",
                                "relativePath": "Userland/wine-userland.tar.zst",
                                "sizeBytes": 123,
                                "checksum": "b" * 64,
                                "kind": "userlandPayload",
                            },
                        ],
                        "supportMetadata": {
                            "runtimeHostCodeSignatureInvariantSHA256": invariant,
                            "userlandDelivery": "app-staged-extracted",
                        },
                    }
                ),
                encoding="utf-8",
            )

            runtime_host.write_bytes(after)
            packager.refresh_runtime_manifest_artifacts(app)

            refreshed = json.loads(manifest_path.read_text(encoding="utf-8"))
            runtime_artifact = refreshed["artifacts"][0]
            self.assertEqual(runtime_artifact["checksum"], hashlib.sha256(after).hexdigest())
            self.assertEqual(runtime_artifact["sizeBytes"], len(after))
            self.assertEqual(
                refreshed["supportMetadata"]["runtimeHostCodeSignatureInvariantSHA256"],
                invariant,
            )
            # Missing app-staged Wine archive keeps its canonical identity.
            self.assertEqual(refreshed["artifacts"][1]["checksum"], "b" * 64)
            self.assertEqual(refreshed["artifacts"][1]["sizeBytes"], 123)


if __name__ == "__main__":
    unittest.main()
