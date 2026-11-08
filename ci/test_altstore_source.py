import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("altstore", ROOT / "ci/update-altstore-source.py")
ALTSTORE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ALTSTORE)


class AltStoreSourceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        shutil.copytree(ROOT / "altstore", self.root / "altstore")
        stable = self.source("stable")
        stable["apps"][0]["versions"] = [{"version": "0.2.0", "downloadURL": "https://example.com/stable.ipa"}]
        (self.root / "altstore/stable.json").write_text(json.dumps(stable))
        nightly = self.source("nightly")
        nightly["apps"] = []
        (self.root / "altstore/nightly.json").write_text(json.dumps(nightly))
        self.enterContext(patch.object(ALTSTORE, "ROOT", self.root))
        self.ipa = self.root / ALTSTORE.IPA
        self.revision = "a" * 40
        self.responses = {}
        self.enterContext(patch.object(ALTSTORE, "api", side_effect=self.responses.__getitem__))

    def source(self, channel):
        return json.loads((self.root / f"altstore/{channel}.json").read_text())

    def make_release(self, tag, nightly):
        info = {
            "CFBundleIdentifier": "software.iridium", "CFBundleShortVersionString": "0.3.0",
            "CFBundleVersion": "199.2", "MinimumOSVersion": "18.0",
            "IridiumRootRevision": self.revision, "IridiumSourceState": "Committed source",
            "NSMicrophoneUsageDescription": "Game microphone access.",
        }
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(ALTSTORE.APP + "Info.plist", plistlib.dumps(info))
            archive.writestr(ALTSTORE.APP + "PlugIns/Helper.appex/Info.plist", plistlib.dumps({
                "NSCameraUsageDescription": "Game camera access.",
            }))
        assets = [{"name": name, "state": "uploaded"} for name in (
            ALTSTORE.IPA, "Iridium-corresponding-source.tar.gz", "Iridium-source-guide.zip", "SHA256SUMS",
        )]
        digest = hashlib.sha256(self.ipa.read_bytes()).hexdigest()
        assets[0].update(size=self.ipa.stat().st_size, digest=f"sha256:{digest}")
        release = {
            "draft": False, "prerelease": nightly, "published_at": "2026-11-08T12:00:00Z",
            "assets": assets,
        }
        self.responses[f"releases/tags/{tag}"] = release
        return release

    def test_stable_keeps_latest_and_reindexing_is_idempotent(self):
        tag = "v0.3.0"
        release = self.make_release(tag, False)
        ALTSTORE.index(tag, self.ipa)
        expected = self.source("stable")
        ALTSTORE.index(tag, self.ipa)
        self.assertEqual(self.source("stable"), expected)
        app = expected["apps"][0]
        self.assertEqual([v["version"] for v in app["versions"]], ["0.3.0"])
        self.assertEqual(app["versions"][0]["sha256"], release["assets"][0]["digest"].split(":")[1])
        self.assertNotIn("NSLocalNetworkUsageDescription", app["appPermissions"]["privacy"])
        self.assertEqual(self.source("nightly")["apps"], [])

    def test_stable_rejects_changed_ipa_and_drafts(self):
        tag = "v0.3.0"
        release = self.make_release(tag, False)
        with patch.dict(release, draft=True):
            with self.assertRaisesRegex(ValueError, "published release"):
                ALTSTORE.index(tag, self.ipa)
        with self.ipa.open("ab") as stream:
            stream.write(b"changed")
        with self.assertRaisesRegex(ValueError, "size or SHA-256"):
            ALTSTORE.index(tag, self.ipa)

    def test_stable_rejects_an_older_release(self):
        tag = "v0.3.0"
        self.make_release(tag, False)
        source = self.source("stable")
        source["apps"][0]["versions"][0]["version"] = "0.4.0"
        (self.root / "altstore/stable.json").write_text(json.dumps(source))
        with self.assertRaisesRegex(ValueError, "older version"):
            ALTSTORE.index(tag, self.ipa)
        self.assertEqual(self.source("stable"), source)
